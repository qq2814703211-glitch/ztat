// SPDX-License-Identifier: GPL-3.0-or-later
// ZTAT-PATCH: Real Native Hardware Telemetry Engine for Vitals Popover & Task Manager.
// Directly leverages StatsKit SMC, CStatsHardware IOReport, Metal, IOKit, CoreWLAN,
// IOBluetooth, CoreAudio, and Darwin Mach/sysctl APIs — zero fabricated readings.

import AppKit
import AudioToolbox
import CoreAudio
import CoreWLAN
import CStatsHardware
import Darwin
import Foundation
import IOBluetooth
import IOKit
import IOKit.ps
import IOKit.pwr_mgt
import Metal
import StatsKit
import ZtatCore

// MARK: - Vitals Navigation Panes

public enum VitalsPane: String, CaseIterable, Identifiable, Sendable {
    case overview
    case cpu
    case gpu
    case ane
    case memory
    case disk
    case network
    case battery
    case fans
    case bluetooth
    case sound
    case agents
    case containers
    case ports

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .overview:   return ZtatL10n.tr("系统概览", "System Overview")
        case .cpu:        return ZtatL10n.tr("CPU 核心与负载", "CPU & Cores")
        case .gpu:        return ZtatL10n.tr("GPU 图形处理器", "GPU & Metal")
        case .ane:        return ZtatL10n.tr("神经网络引擎 (ANE)", "Neural Engine")
        case .memory:     return ZtatL10n.tr("内存与压力", "Memory & Pressure")
        case .disk:       return ZtatL10n.tr("磁盘与存储", "Disk & Volumes")
        case .network:    return ZtatL10n.tr("网络与 Wi-Fi", "Network & Wi-Fi")
        case .battery:    return ZtatL10n.tr("电池与功耗", "Battery & Power")
        case .fans:       return ZtatL10n.tr("温度与风扇", "Thermals & Fans")
        case .bluetooth:  return ZtatL10n.tr("蓝牙设备", "Bluetooth")
        case .sound:      return ZtatL10n.tr("音频与输出", "Sound & Audio")
        case .agents:     return ZtatL10n.tr("AI 编程智能体", "AI Agents")
        case .containers: return ZtatL10n.tr("容器服务", "Containers")
        case .ports:      return ZtatL10n.tr("监听端口", "Listening Ports")
        }
    }

    public var shortLabel: String {
        switch self {
        case .overview:   return ZtatL10n.tr("概览", "All")
        case .cpu:        return "CPU"
        case .gpu:        return "GPU"
        case .ane:        return "ANE"
        case .memory:     return ZtatL10n.tr("内存", "RAM")
        case .disk:       return ZtatL10n.tr("磁盘", "Disk")
        case .network:    return ZtatL10n.tr("网络", "Net")
        case .battery:    return ZtatL10n.tr("电池", "Bat")
        case .fans:       return ZtatL10n.tr("温控", "Fan")
        case .bluetooth:  return ZtatL10n.tr("蓝牙", "BT")
        case .sound:      return ZtatL10n.tr("音频", "Audio")
        case .agents:     return "AI"
        case .containers: return ZtatL10n.tr("容器", "Docker")
        case .ports:      return ZtatL10n.tr("端口", "Ports")
        }
    }

    public var symbol: String {
        switch self {
        case .overview:   return "square.grid.2x2.fill"
        case .cpu:        return "cpu"
        case .gpu:        return "rectangle.3.group"
        case .ane:        return "brain.head.profile"
        case .memory:     return "memorychip"
        case .disk:       return "internaldrive"
        case .network:    return "arrow.up.arrow.down"
        case .battery:    return "battery.100"
        case .fans:       return "fanblades"
        case .bluetooth:  return "dot.radiowaves.left.and.right"
        case .sound:      return "speaker.wave.2.fill"
        case .agents:     return "sparkles"
        case .containers: return "shippingbox.fill"
        case .ports:      return "network"
        }
    }

    public static func fromStatsModuleName(_ name: String) -> VitalsPane {
        let lower = name.lowercased()
        if lower.contains("cpu") { return .cpu }
        if lower.contains("gpu") { return .gpu }
        if lower.contains("ram") || lower.contains("memory") { return .memory }
        if lower.contains("disk") || lower.contains("storage") { return .disk }
        if lower.contains("net") { return .network }
        if lower.contains("battery") || lower.contains("power") { return .battery }
        if lower.contains("sensor") || lower.contains("fan") || lower.contains("temp") { return .fans }
        if lower.contains("bluetooth") || lower.contains("bt") { return .bluetooth }
        return .overview
    }
}

// MARK: - Telemetry Snapshot Data Types

public struct VitalsCoreSample: Identifiable, Sendable {
    public let id: Int
    public let isPerformance: Bool
    public let isSuper: Bool
    public let tierLabel: String
    public let load: Double

    public init(id: Int, isPerformance: Bool, isSuper: Bool = false, tierLabel: String? = nil, load: Double) {
        self.id = id
        self.isPerformance = isPerformance
        self.isSuper = isSuper
        self.tierLabel = tierLabel ?? (isSuper ? "S\(id)" : (isPerformance ? "P\(id)" : "E\(id)"))
        self.load = load
    }
}

public struct VitalsFanInfo: Identifiable, Sendable {
    public let id: Int
    public let name: String
    public let currentRPM: Double
    public let minRPM: Double
    public let maxRPM: Double
    public let isAutomatic: Bool

    public var fraction: Double {
        guard maxRPM > minRPM else { return 0 }
        return min(1.0, max(0.0, (currentRPM - minRPM) / (maxRPM - minRPM)))
    }
}

public struct VitalsTempSensor: Identifiable, Sendable {
    public enum Group: String, CaseIterable, Sendable {
        case cpu = "CPU"
        case gpu = "GPU"
        case soc = "SoC"
        case storage = "Storage"
        case battery = "Battery"
        case system = "System"

        public var title: String {
            switch self {
            case .cpu:     return "CPU"
            case .gpu:     return "GPU"
            case .soc:     return "SoC"
            case .storage: return ZtatL10n.tr("存储", "Storage")
            case .battery: return ZtatL10n.tr("电池", "Battery")
            case .system:  return ZtatL10n.tr("整机", "System")
            }
        }
    }

    public let id: String
    public let name: String
    public let group: Group
    public let celsius: Double
}

public struct VitalsPowerRails: Sendable {
    public var cpuWatts: Double = 0
    public var gpuWatts: Double = 0
    public var aneWatts: Double = 0
    public var dramWatts: Double = 0
    public var systemTotalWatts: Double? = nil

    public var packageTotalWatts: Double {
        cpuWatts + gpuWatts + aneWatts + dramWatts
    }
}

public struct VitalsDiskVolume: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let mountPath: String
    public let fileSystem: String
    public let totalGB: Double
    public let freeGB: Double
    public let purgeableGB: Double
    public let isExternal: Bool
    public let isEjectable: Bool

    public var usedGB: Double { max(0, totalGB - freeGB) }
    public var usedFraction: Double { totalGB > 0 ? min(1.0, max(0.0, usedGB / totalGB)) : 0 }
}

public struct VitalsBluetoothDevice: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let category: String
    public let symbolName: String
    public let batteryPercent: Int?
    public let rssi: Int?
}

public struct VitalsAudioDevice: Identifiable, Sendable {
    public let id: AudioDeviceID
    public let name: String
    public let isDefault: Bool
}

public struct VitalsContainerItem: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let image: String
    public let engine: String
    public let status: String
    public let cpuPercent: Double
    public let memoryText: String
    public let ports: String
}

public struct VitalsSleepAssertion: Identifiable, Sendable {
    public let id: String
    public let pid: Int32
    public let processName: String
    public let assertionType: String
    public let reason: String
}

public struct VitalsHealthAlert: Identifiable, Sendable {
    public enum Severity: Sendable { case warning, critical }
    public let id: String
    public let severity: Severity
    public let title: String
    public let detail: String
    public let targetPane: VitalsPane
}

public struct VitalsMemoryPressure: Sendable {
    public enum Level: Int, Sendable {
        case normal = 1
        case warning = 2
        case critical = 4

        public var label: String {
            switch self {
            case .normal:   return ZtatL10n.tr("正常", "Normal")
            case .warning:  return ZtatL10n.tr("警告", "Warning")
            case .critical: return ZtatL10n.tr("严重", "Critical")
            }
        }
    }

    public var level: Level = .normal
    public var totalGB: Double = 0
    public var usedGB: Double = 0
    public var appGB: Double = 0
    public var wiredGB: Double = 0
    public var compressedGB: Double = 0
    public var cachedGB: Double = 0
    public var freeGB: Double = 0
    public var swapUsedGB: Double = 0
    public var swapTotalGB: Double = 0
    public var pageIns: UInt64 = 0
    public var pageOuts: UInt64 = 0
    public var usedFraction: Double { totalGB > 0 ? min(1.0, max(0.0, usedGB / totalGB)) : 0 }
}

public struct VitalsHardwareSnapshot: Sendable {
    // CPU
    public var chipName: String = ""
    public var cpuUsage: Double = 0
    public var cpuUser: Double = 0
    public var cpuSystem: Double = 0
    public var cpuIdle: Double = 1
    public var performanceCoreCount: Int = 0
    public var efficiencyCoreCount: Int = 0
    public var coreSamples: [VitalsCoreSample] = []
    public var loadAverages: [Double] = [0, 0, 0]

    // GPU & ANE
    public var gpuName: String = "Apple Silicon GPU"
    public var gpuCoreCount: Int = 0
    public var gpuHasUnifiedMemory: Bool = true
    public var gpuRecommendedMaxVRAMGB: Double = 0
    public var gpuUsage: Double = 0
    public var gpuRendererUtilization: Double = 0
    public var gpuTilerUtilization: Double = 0
    public var gpuAllocatedMB: Double = 0
    public var gpuInUseMB: Double = 0
    public var gpuWiredLimitMB: Double = 0
    public var displayFPS: Double? = nil
    public var aneUtilization: Double = 0
    public var aneMaxPowerWatts: Double = 8.0
    public var aneSupported: Bool = false

    // Memory
    public var memory = VitalsMemoryPressure()

    // Disk
    public var diskVolumes: [VitalsDiskVolume] = []
    public var diskReadMBs: Double = 0
    public var diskWriteMBs: Double = 0
    public var diskReadIOPS: Double = 0
    public var diskWriteIOPS: Double = 0
    public var diskTotalReadGB: Double = 0
    public var diskTotalWrittenGB: Double = 0

    // Network
    public var activeInterfaceName: String = "en0"
    public var activeInterfaceKind: String = "Wi-Fi"
    public var localIPv4: String = "—"
    public var wifiSSID: String? = nil
    public var wifiRSSI: Int? = nil
    public var wifiNoise: Int? = nil
    public var wifiTxRateMbps: Double? = nil
    public var wifiChannel: Int? = nil
    public var netDownloadKBs: Double = 0
    public var netUploadKBs: Double = 0
    public var netTotalInMB: Double = 0
    public var netTotalOutMB: Double = 0

    // Battery & Power
    public var hasBattery: Bool = false
    public var batteryPercent: Int? = nil
    public var batteryCharging: Bool = false
    public var batteryExternalConnected: Bool = false
    public var batteryFullyCharged: Bool = false
    public var batteryWatts: Double? = nil
    public var batteryAdapterWatts: Int? = nil
    public var batteryCycleCount: Int? = nil
    public var batteryHealthPercent: Double? = nil
    public var batteryCurrentCapacityMah: Int? = nil
    public var batteryMaxCapacityMah: Int? = nil
    public var batteryDesignCapacityMah: Int? = nil
    public var batteryVoltageV: Double? = nil
    public var batteryAmperageMA: Int? = nil
    public var batteryTempC: Double? = nil
    public var batteryTimeRemainingMinutes: Int? = nil

    // Thermals, Fans & Power Rails
    public var thermalState: ProcessInfo.ThermalState = .nominal
    public var fans: [VitalsFanInfo] = []
    public var temperatureSensors: [VitalsTempSensor] = []
    public var powerRails = VitalsPowerRails()
    public var cpuTempC: Double? = nil
    public var gpuTempC: Double? = nil
    public var hottestTempC: Double? = nil
    public var hottestSensorName: String? = nil

    // Peripherals & Audio
    public var bluetoothDevices: [VitalsBluetoothDevice] = []
    public var outputAudioDevices: [VitalsAudioDevice] = []
    public var activeOutputAudioName: String = "—"
    public var activeInputAudioName: String = "—"
    public var systemVolume: Float = 0.5
    public var isSystemMuted: Bool = false

    // System
    public var uptimeSeconds: TimeInterval = 0
}

// MARK: - Native Hardware Collector Engine

internal final class VitalsHardwareCollector {
    private let hostPort: mach_port_t = mach_host_self()
    private var prevCPUTicks: (user: UInt32, system: UInt32, idle: UInt32, nice: UInt32)?
    private var prevCoreTicks: [[UInt32]] = []
    private var prevNetByIndex: [UInt32: (inBytes: UInt64, outBytes: UInt64)] = [:]
    private var prevNetTime: TimeInterval?
    private var prevDiskByID: [UInt64: (readBytes: UInt64, writeBytes: UInt64, readOps: UInt64, writeOps: UInt64)] = [:]
    private var prevDiskTime: TimeInterval?

    // IOReport channels (Apple Silicon Power + Display FPS)
    private var energyChannels: CFMutableDictionary?
    private var energySubscription: IOReportSubscriptionRef?
    private var prevEnergy: (cpu: Double, gpu: Double, ane: Double, dram: Double, time: TimeInterval)?

    private var fpsChannels: CFMutableDictionary?
    private var fpsSubscription: IOReportSubscriptionRef?
    private var prevFramesByGroup: [String: Int64] = [:]
    private var prevFramesTime: TimeInterval?
    private var didUseHIDSensors: Bool = false

    // Static hardware metadata cached once
    private let chipName: String
    private let perfCoreCount: Int
    private let effCoreCount: Int
    private let aneMaxPower: Double
    private let aneSupported: Bool
    private let smcTempKeys: [(key: String, name: String, group: VitalsTempSensor.Group)]
    private var hasPSTRKey: Bool = false

    deinit {
        mach_port_deallocate(mach_task_self_, hostPort)
        #if arch(arm64)
        if let sub = energySubscription {
            ztat_ioreport_release_subscription(sub)
        }
        if let sub = fpsSubscription {
            ztat_ioreport_release_subscription(sub)
        }
        if didUseHIDSensors {
            AppleSiliconSensorsReset()
        }
        #endif
    }

    init() {
        var brandBuf = [CChar](repeating: 0, count: 128)
        var brandSize = brandBuf.count
        if sysctlbyname("machdep.cpu.brand_string", &brandBuf, &brandSize, nil, 0) == 0 {
            let s = String(cString: brandBuf).trimmingCharacters(in: .whitespacesAndNewlines)
            self.chipName = s.isEmpty ? (SystemKit.shared.device.info.cpu?.name ?? "Apple Silicon") : s
        } else {
            self.chipName = SystemKit.shared.device.info.cpu?.name ?? "Apple Silicon"
        }

        var pCores: Int32 = 0
        var eCores: Int32 = 0
        var intSize = MemoryLayout<Int32>.size
        if sysctlbyname("hw.perflevel0.logicalcpu", &pCores, &intSize, nil, 0) != 0 { pCores = 0 }
        intSize = MemoryLayout<Int32>.size
        if sysctlbyname("hw.perflevel1.logicalcpu", &eCores, &intSize, nil, 0) != 0 { eCores = 0 }
        self.perfCoreCount = Int(pCores)
        self.effCoreCount = Int(eCores)

        #if arch(arm64)
        self.aneSupported = true
        self.aneMaxPower = Self.resolveMaxANEPower(for: SystemKit.shared.device.platform)
        #else
        self.aneSupported = false
        self.aneMaxPower = 0
        #endif

        // Discover available SMC keys once
        let allSMCKeys = Set(SMC.shared.getAllKeys())
        self.hasPSTRKey = allSMCKeys.contains("PSTR")
        self.smcTempKeys = Self.discoverSMCTemperatureKeys(available: allSMCKeys)

        #if arch(arm64)
        setupIOReportEnergy()
        setupIOReportFPS()
        #endif
    }

    func resetDeltaBaselines() {
        prevCPUTicks = nil
        prevCoreTicks = []
        prevNetByIndex.removeAll()
        prevNetTime = nil
        prevDiskByID.removeAll()
        prevDiskTime = nil
        prevEnergy = nil
        prevFramesByGroup.removeAll()
        prevFramesTime = nil
        #if arch(arm64)
        if didUseHIDSensors {
            AppleSiliconSensorsReset()
            didUseHIDSensors = false
        }
        #endif
    }

    func collect(includeSlowPeripherals: Bool) -> VitalsHardwareSnapshot {
        var snap = VitalsHardwareSnapshot()
        snap.chipName = chipName
        snap.performanceCoreCount = perfCoreCount
        snap.efficiencyCoreCount = effCoreCount
        snap.aneMaxPowerWatts = aneMaxPower
        snap.aneSupported = aneSupported
        snap.thermalState = ProcessInfo.processInfo.thermalState
        snap.uptimeSeconds = ProcessInfo.processInfo.systemUptime

        collectCPU(into: &snap)
        collectGPU(into: &snap)
        collectMemory(into: &snap)
        collectDisk(into: &snap)
        collectNetwork(into: &snap)
        collectBattery(into: &snap)
        collectSMCAndPower(into: &snap)
        if includeSlowPeripherals {
            collectBluetooth(into: &snap)
            collectAudio(into: &snap)
        }
        return snap
    }

    // MARK: - CPU

    private func collectCPU(into snap: inout VitalsHardwareSnapshot) {
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        var info = host_cpu_load_info_data_t()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(hostPort, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        if result == KERN_SUCCESS {
            let user = info.cpu_ticks.0
            let system = info.cpu_ticks.1
            let idle = info.cpu_ticks.2
            let nice = info.cpu_ticks.3
            if let prev = prevCPUTicks {
                // 32-bit wrapping subtraction BEFORE widening to UInt64 prevents 27.6-day wraparound traps
                let du = UInt64(user &- prev.user)
                let ds = UInt64(system &- prev.system)
                let di = UInt64(idle &- prev.idle)
                let dn = UInt64(nice &- prev.nice)
                let total = Double(du &+ ds &+ di &+ dn)
                if total > 0 {
                    snap.cpuUser = Double(du &+ dn) / total
                    snap.cpuSystem = Double(ds) / total
                    snap.cpuUsage = min(1.0, max(0.0, snap.cpuUser + snap.cpuSystem))
                    snap.cpuIdle = max(0.0, 1.0 - snap.cpuUsage)
                }
            }
            prevCPUTicks = (user, system, idle, nice)
        }

        var processorCount: natural_t = 0
        var processorInfo: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        if host_processor_info(hostPort, PROCESSOR_CPU_LOAD_INFO, &processorCount, &processorInfo, &infoCount) == KERN_SUCCESS,
           let pInfo = processorInfo {
            let numCores = Int(processorCount)
            var samples: [VitalsCoreSample] = []
            samples.reserveCapacity(numCores)
            var newTicks: [[UInt32]] = []
            newTicks.reserveCapacity(numCores)

            // Prefer exact cluster topology from SystemKit (correctly handles M5 Super/Performance & M1-M4 E/P cores)
            let knownCores = SystemKit.shared.device.info.cpu?.cores
            let hasSystemKitTopology = (knownCores?.count == numCores)
            let hasHybridTopology = effCoreCount > 0 && perfCoreCount > 0 && (effCoreCount + perfCoreCount == numCores)

            var eIdx = 0
            var pIdx = 0
            var sIdx = 0

            for i in 0..<numCores {
                let base = i * Int(CPU_STATE_MAX)
                // pInfo holds signed Int32 bit patterns of unsigned 32-bit tick counters — use UInt32(bitPattern:)
                let u = UInt32(bitPattern: pInfo[base + Int(CPU_STATE_USER)])
                let s = UInt32(bitPattern: pInfo[base + Int(CPU_STATE_SYSTEM)])
                let id = UInt32(bitPattern: pInfo[base + Int(CPU_STATE_IDLE)])
                let n = UInt32(bitPattern: pInfo[base + Int(CPU_STATE_NICE)])
                newTicks.append([u, s, id, n])

                var load: Double = 0
                if prevCoreTicks.count == numCores {
                    let prev = prevCoreTicks[i]
                    let du = UInt64(u &- prev[0])
                    let ds = UInt64(s &- prev[1])
                    let did = UInt64(id &- prev[2])
                    let dn = UInt64(n &- prev[3])
                    let dtot = Double(du &+ ds &+ did &+ dn)
                    if dtot > 0 {
                        load = min(1.0, max(0.0, Double(du &+ ds &+ dn) / dtot))
                    }
                }

                let isSuper: Bool
                let isPerf: Bool
                let tierLabel: String
                if hasSystemKitTopology, let cType = knownCores?[i].type {
                    switch cType {
                    case .super:
                        isSuper = true
                        isPerf = true
                        tierLabel = "S\(sIdx)"
                        sIdx += 1
                    case .performance:
                        isSuper = false
                        isPerf = true
                        tierLabel = "P\(pIdx)"
                        pIdx += 1
                    case .efficiency:
                        isSuper = false
                        isPerf = false
                        tierLabel = "E\(eIdx)"
                        eIdx += 1
                    default:
                        isSuper = false
                        isPerf = true
                        tierLabel = "C\(i)"
                    }
                } else if hasHybridTopology {
                    isSuper = false
                    isPerf = (i >= effCoreCount)
                    if isPerf {
                        tierLabel = "P\(pIdx)"
                        pIdx += 1
                    } else {
                        tierLabel = "E\(eIdx)"
                        eIdx += 1
                    }
                } else {
                    isSuper = false
                    isPerf = true
                    tierLabel = "C\(i)"
                }
                samples.append(VitalsCoreSample(id: i, isPerformance: isPerf, isSuper: isSuper, tierLabel: tierLabel, load: load))
            }
            snap.coreSamples = samples
            prevCoreTicks = newTicks

            let deallocSize = vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride)
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: pInfo), deallocSize)
        }

        var loads = [Double](repeating: 0.0, count: 3)
        if getloadavg(&loads, 3) == 3 {
            snap.loadAverages = loads
        }
    }

    // MARK: - GPU & Display FPS

    private func collectGPU(into snap: inout VitalsHardwareSnapshot) {
        if let dev = MTLCreateSystemDefaultDevice() {
            snap.gpuName = dev.name
            snap.gpuHasUnifiedMemory = dev.hasUnifiedMemory
            snap.gpuRecommendedMaxVRAMGB = Double(dev.recommendedMaxWorkingSetSize) / 1_073_741_824.0
        }

        var wiredLimitMB: Int64 = 0
        var wlSize = MemoryLayout<Int64>.size
        if sysctlbyname("iogpu.wired_limit_mb", &wiredLimitMB, &wlSize, nil, 0) == 0, wiredLimitMB > 0 {
            snap.gpuWiredLimitMB = Double(wiredLimitMB)
        }

        var iterator: io_iterator_t = 0
        if IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == kIOReturnSuccess {
            defer { IOObjectRelease(iterator) }
            while case let service = IOIteratorNext(iterator), service != 0 {
                defer { IOObjectRelease(service) }
                var props: Unmanaged<CFMutableDictionary>?
                guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == kIOReturnSuccess,
                      let dict = props?.takeRetainedValue() as? [String: Any] else { continue }

                if let cores = (dict["gpu-core-count"] as? NSNumber)?.intValue, cores > 0 {
                    snap.gpuCoreCount = cores
                }
                if let stats = dict["PerformanceStatistics"] as? [String: Any] {
                    if let dev = stats["Device Utilization %"] as? NSNumber {
                        snap.gpuUsage = min(1.0, max(0.0, dev.doubleValue / 100.0))
                    }
                    if let ren = stats["Renderer Utilization %"] as? NSNumber {
                        snap.gpuRendererUtilization = min(1.0, max(0.0, ren.doubleValue / 100.0))
                    }
                    if let til = stats["Tiler Utilization %"] as? NSNumber {
                        snap.gpuTilerUtilization = min(1.0, max(0.0, til.doubleValue / 100.0))
                    }
                    if let alloc = stats["Alloc system memory"] as? NSNumber {
                        snap.gpuAllocatedMB = alloc.doubleValue / 1_048_576.0
                    }
                    if let inUse = stats["In use system memory"] as? NSNumber {
                        snap.gpuInUseMB = inUse.doubleValue / 1_048_576.0
                    }
                    break
                }
            }
        }

        #if arch(arm64)
        snap.displayFPS = readIOReportFPS()
        #endif
    }

    // MARK: - Memory & Swap & Kernel Pressure

    private func collectMemory(into snap: inout VitalsHardwareSnapshot) {
        let totalBytes = Double(ProcessInfo.processInfo.physicalMemory)
        snap.memory.totalGB = totalBytes / 1_073_741_824.0

        var size = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        var vmStat = vm_statistics64_data_t()
        let result = withUnsafeMutablePointer(to: &vmStat) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                host_statistics64(hostPort, HOST_VM_INFO64, $0, &size)
            }
        }
        if result == KERN_SUCCESS {
            let pageSize = Double(vm_kernel_page_size)
            // Matches macOS Activity Monitor accounting:
            // App Memory = internal - purgeable; Cached = external + purgeable
            let internalPages = Double(vmStat.internal_page_count)
            let purgeablePages = Double(vmStat.purgeable_count)
            let externalPages = Double(vmStat.external_page_count)

            let appBytes = max(0, internalPages - purgeablePages) * pageSize
            let wiredBytes = Double(vmStat.wire_count) * pageSize
            let compressedBytes = Double(vmStat.compressor_page_count) * pageSize
            let cachedBytes = (externalPages + purgeablePages) * pageSize
            let usedBytes = appBytes + wiredBytes + compressedBytes
            let freeBytes = max(0, totalBytes - usedBytes)

            snap.memory.appGB = appBytes / 1_073_741_824.0
            snap.memory.wiredGB = wiredBytes / 1_073_741_824.0
            snap.memory.compressedGB = compressedBytes / 1_073_741_824.0
            snap.memory.cachedGB = cachedBytes / 1_073_741_824.0
            snap.memory.usedGB = usedBytes / 1_073_741_824.0
            snap.memory.freeGB = freeBytes / 1_073_741_824.0
            snap.memory.pageIns = UInt64(vmStat.pageins)
            snap.memory.pageOuts = UInt64(vmStat.pageouts)
        }

        // Real swap usage via sysctl vm.swapusage
        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0 {
            snap.memory.swapUsedGB = Double(swap.xsu_used) / 1_073_741_824.0
            snap.memory.swapTotalGB = Double(swap.xsu_total) / 1_073_741_824.0
        }

        // Real kernel memory pressure level (1 = Normal, 2 = Warning, 4 = Critical)
        var pressureRaw: Int32 = 1
        var pSize = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &pressureRaw, &pSize, nil, 0) == 0 {
            if pressureRaw >= 4 {
                snap.memory.level = .critical
            } else if pressureRaw >= 2 {
                snap.memory.level = .warning
            } else {
                snap.memory.level = .normal
            }
        }
    }

    // MARK: - Disk Volumes & Real IOKit Throughput

    private func collectDisk(into snap: inout VitalsHardwareSnapshot) {
        let keys: [URLResourceKey] = [
            .volumeNameKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey,
            .volumeIsLocalKey,
            .volumeIsInternalKey,
            .volumeIsRemovableKey,
            .volumeIsEjectableKey,
            .volumeLocalizedFormatDescriptionKey
        ]

        var volumes: [VitalsDiskVolume] = []
        if let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) {
            var seenMounts = Set<String>()
            for url in urls {
                let path = url.path
                if path.hasPrefix("/System/Volumes/") && path != "/System/Volumes/Data" { continue }
                if path == "/System/Volumes/Data" { continue }
                guard seenMounts.insert(path).inserted else { continue }
                guard let vals = try? url.resourceValues(forKeys: Set(keys)) else { continue }
                guard vals.volumeIsLocal ?? true else { continue }

                let totalBytes = Double(vals.volumeTotalCapacity ?? 0)
                guard totalBytes > 1_000_000_000 else { continue }
                let importantFree = Double(vals.volumeAvailableCapacityForImportantUsage ?? 0)
                let rawFree = Double(vals.volumeAvailableCapacity ?? 0)
                let freeBytes = importantFree > 0 ? importantFree : rawFree
                let purgeableBytes = max(0, importantFree - rawFree)

                let isInternal = vals.volumeIsInternal ?? (path == "/")
                let isEjectable = (vals.volumeIsEjectable ?? false) || (vals.volumeIsRemovable ?? false) || !isInternal
                let name = vals.volumeName ?? (path == "/" ? "Macintosh HD" : url.lastPathComponent)
                let fs = vals.volumeLocalizedFormatDescription ?? "APFS"

                volumes.append(VitalsDiskVolume(
                    id: path,
                    name: name,
                    mountPath: path,
                    fileSystem: fs,
                    totalGB: totalBytes / 1_000_000_000.0,
                    freeGB: freeBytes / 1_000_000_000.0,
                    purgeableGB: purgeableBytes / 1_000_000_000.0,
                    isExternal: !isInternal,
                    isEjectable: isEjectable
                ))
            }
        }
        volumes.sort { a, b in
            if a.mountPath == "/" { return true }
            if b.mountPath == "/" { return false }
            return a.totalGB > b.totalGB
        }
        snap.diskVolumes = volumes

        // Real block storage throughput via IOKit IOBlockStorageDriver (per-entry delta avoids eject underflow & virtual DMG double-counting)
        var totalReadBytes: UInt64 = 0
        var totalWriteBytes: UInt64 = 0
        var currentByID: [UInt64: (readBytes: UInt64, writeBytes: UInt64, readOps: UInt64, writeOps: UInt64)] = [:]

        var iterator: io_iterator_t = 0
        if IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator) == kIOReturnSuccess {
            defer { IOObjectRelease(iterator) }
            while case let service = IOIteratorNext(iterator), service != 0 {
                defer { IOObjectRelease(service) }
                // Exclude mounted virtual disk images (.dmg) whose backing I/O is already counted on physical NVMe
                var parent: io_registry_entry_t = 0
                if IORegistryEntryGetParentEntry(service, kIOServicePlane, &parent) == kIOReturnSuccess {
                    let isDiskImage = IOObjectConformsTo(parent, "AppleDiskImageDevice") != 0
                        || IOObjectConformsTo(parent, "IOHDIXHDDrive") != 0
                    IOObjectRelease(parent)
                    if isDiskImage { continue }
                }

                var entryID: UInt64 = 0
                guard IORegistryEntryGetRegistryEntryID(service, &entryID) == kIOReturnSuccess else { continue }

                var props: Unmanaged<CFMutableDictionary>?
                if IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == kIOReturnSuccess,
                   let dict = props?.takeRetainedValue() as? [String: Any],
                   let stats = dict["Statistics"] as? [String: Any] {
                    let rb = (stats["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
                    let wb = (stats["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
                    let ro = (stats["Operations (Read)"] as? NSNumber)?.uint64Value ?? 0
                    let wo = (stats["Operations (Write)"] as? NSNumber)?.uint64Value ?? 0
                    currentByID[entryID] = (rb, wb, ro, wo)
                    totalReadBytes &+= rb
                    totalWriteBytes &+= wb
                }
            }
        }

        let now = ProcessInfo.processInfo.systemUptime
        if let prevTime = prevDiskTime, now > prevTime {
            let dt = now - prevTime
            var dReadBytes: UInt64 = 0
            var dWriteBytes: UInt64 = 0
            var dReadOps: UInt64 = 0
            var dWriteOps: UInt64 = 0
            for (id, cur) in currentByID {
                guard let prev = prevDiskByID[id] else { continue }
                if cur.readBytes >= prev.readBytes { dReadBytes &+= (cur.readBytes - prev.readBytes) }
                if cur.writeBytes >= prev.writeBytes { dWriteBytes &+= (cur.writeBytes - prev.writeBytes) }
                if cur.readOps >= prev.readOps { dReadOps &+= (cur.readOps - prev.readOps) }
                if cur.writeOps >= prev.writeOps { dWriteOps &+= (cur.writeOps - prev.writeOps) }
            }
            snap.diskReadMBs = max(0, Double(dReadBytes) / dt / 1_048_576.0)
            snap.diskWriteMBs = max(0, Double(dWriteBytes) / dt / 1_048_576.0)
            snap.diskReadIOPS = max(0, Double(dReadOps) / dt)
            snap.diskWriteIOPS = max(0, Double(dWriteOps) / dt)
        }
        prevDiskByID = currentByID
        prevDiskTime = now
        snap.diskTotalReadGB = Double(totalReadBytes) / 1_073_741_824.0
        snap.diskTotalWrittenGB = Double(totalWriteBytes) / 1_073_741_824.0
    }

    // MARK: - Network & CoreWLAN

    private func collectNetwork(into snap: inout VitalsHardwareSnapshot) {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&ifaddr) == 0, let first = ifaddr {
            defer { freeifaddrs(ifaddr) }
            var activeIfIndices = Set<UInt32>()
            var primaryName: String?
            var primaryIP: String?
            var fallbackIP: String?

            var ptr: UnsafeMutablePointer<ifaddrs>? = first
            while let curr = ptr {
                let flags = Int32(curr.pointee.ifa_flags)
                let isUp = (flags & IFF_UP) != 0
                let isRunning = (flags & IFF_RUNNING) != 0
                let isLoopback = (flags & IFF_LOOPBACK) != 0
                let name = String(cString: curr.pointee.ifa_name)

                if isUp && isRunning && !isLoopback {
                    if let addr = curr.pointee.ifa_addr {
                        let family = addr.pointee.sa_family
                        if family == UInt8(AF_LINK) {
                            // Count physical interfaces once (AF_LINK), excluding bridge* which duplicates en* traffic
                            if name.hasPrefix("en") || name.hasPrefix("pdp_ip") {
                                let idx = if_nametoindex(curr.pointee.ifa_name)
                                if idx != 0 {
                                    activeIfIndices.insert(idx)
                                }
                            }
                        } else if family == UInt8(AF_INET) {
                            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                            if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST) == 0 {
                                let ip = String(cString: hostname)
                                if !ip.hasPrefix("169.254.") {
                                    if name == "en0" {
                                        primaryName = name
                                        primaryIP = ip
                                    } else if name.hasPrefix("en"), primaryIP == nil {
                                        primaryName = name
                                        primaryIP = ip
                                    } else if fallbackIP == nil {
                                        fallbackIP = ip
                                        if primaryName == nil { primaryName = name }
                                    }
                                }
                            }
                        }
                    }
                }
                ptr = curr.pointee.ifa_next
            }

            // Read true 64-bit per-interface byte counters via NET_RT_IFLIST2 (avoids 4 GB wraparound & interface-down spikes)
            let currentByIdx = Self.read64BitNetworkBytesByIndex(forIndices: activeIfIndices)
            var totalIn: UInt64 = 0
            var totalOut: UInt64 = 0
            for (_, v) in currentByIdx {
                totalIn &+= v.inBytes
                totalOut &+= v.outBytes
            }

            let now = ProcessInfo.processInfo.systemUptime
            if let prevTime = prevNetTime, now > prevTime {
                let dt = now - prevTime
                var dIn: UInt64 = 0
                var dOut: UInt64 = 0
                for (idx, cur) in currentByIdx {
                    guard let prev = prevNetByIndex[idx] else { continue }
                    if cur.inBytes >= prev.inBytes { dIn &+= (cur.inBytes - prev.inBytes) }
                    if cur.outBytes >= prev.outBytes { dOut &+= (cur.outBytes - prev.outBytes) }
                }
                snap.netDownloadKBs = max(0, Double(dIn) / dt / 1024.0)
                snap.netUploadKBs = max(0, Double(dOut) / dt / 1024.0)
            }
            prevNetByIndex = currentByIdx
            prevNetTime = now
            snap.netTotalInMB = Double(totalIn) / 1_048_576.0
            snap.netTotalOutMB = Double(totalOut) / 1_048_576.0
            snap.activeInterfaceName = primaryName ?? "en0"
            snap.localIPv4 = primaryIP ?? fallbackIP ?? "—"
            snap.activeInterfaceKind = (primaryIP != nil || fallbackIP != nil) ? ZtatL10n.tr("以太网", "Ethernet") : ZtatL10n.tr("离线", "Offline")
        }

        if let wifi = CWWiFiClient.shared().interface() {
            if wifi.powerOn() {
                snap.wifiSSID = wifi.ssid()
                let rssi = wifi.rssiValue()
                if rssi != 0 { snap.wifiRSSI = rssi }
                let noise = wifi.noiseMeasurement()
                if noise != 0 { snap.wifiNoise = noise }
                let tx = wifi.transmitRate()
                if tx > 0 { snap.wifiTxRateMbps = tx }
                if let ch = wifi.wlanChannel() {
                    snap.wifiChannel = ch.channelNumber
                }
                if wifi.interfaceName == snap.activeInterfaceName {
                    snap.activeInterfaceKind = "Wi-Fi"
                } else {
                    snap.activeInterfaceKind = ZtatL10n.tr("以太网", "Ethernet")
                }
            } else {
                snap.activeInterfaceKind = ZtatL10n.tr("以太网 / 离线", "Ethernet / Offline")
            }
        }
    }

    // MARK: - Battery (AppleSmartBattery IOKit + IOPS)

    private func collectBattery(into snap: inout VitalsHardwareSnapshot) {
        // Direct AppleSmartBattery read for rich cycle count, health, design capacity, temp, voltage, amperage, adapter watts
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        if service != 0 {
            defer { IOObjectRelease(service) }
            var props: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == kIOReturnSuccess,
               let dict = props?.takeRetainedValue() as? [String: Any] {
                snap.hasBattery = true

                let currentPct = (dict["CurrentCapacity"] as? NSNumber)?.intValue
                let maxPct = (dict["MaxCapacity"] as? NSNumber)?.intValue
                if let c = currentPct, let m = maxPct, m > 0 {
                    snap.batteryPercent = min(100, max(0, Int((Double(c) / Double(m) * 100.0).rounded())))
                }

                snap.batteryCharging = (dict["IsCharging"] as? Bool) ?? false
                snap.batteryExternalConnected = (dict["ExternalConnected"] as? Bool) ?? false
                snap.batteryFullyCharged = (dict["FullyCharged"] as? Bool) ?? false
                snap.batteryCycleCount = (dict["CycleCount"] as? NSNumber)?.intValue

                let batteryData = dict["BatteryData"] as? [String: Any]

                let rawMax = (dict["AppleRawMaxCapacity"] as? NSNumber)?.intValue
                    ?? (batteryData?["AppleRawMaxCapacity"] as? NSNumber)?.intValue
                    ?? (dict["NominalChargeCapacity"] as? NSNumber)?.intValue
                    ?? (batteryData?["NominalChargeCapacity"] as? NSNumber)?.intValue
                    ?? (batteryData?["FullChargeCapacity"] as? NSNumber)?.intValue
                let rawCur = (dict["AppleRawCurrentCapacity"] as? NSNumber)?.intValue
                    ?? (batteryData?["AppleRawCurrentCapacity"] as? NSNumber)?.intValue
                    ?? (batteryData?["RemainingCapacity"] as? NSNumber)?.intValue
                let design = (dict["DesignCapacity"] as? NSNumber)?.intValue
                    ?? (batteryData?["DesignCapacity"] as? NSNumber)?.intValue
                snap.batteryCurrentCapacityMah = rawCur
                snap.batteryMaxCapacityMah = rawMax
                snap.batteryDesignCapacityMah = design
                if let rawMax, let design, design > 0 {
                    snap.batteryHealthPercent = min(100.0, (Double(rawMax) / Double(design)) * 100.0)
                }

                if let tempCenti = (dict["Temperature"] as? NSNumber)?.doubleValue
                    ?? (batteryData?["Temperature"] as? NSNumber)?.doubleValue,
                   tempCenti > 0 {
                    // AppleSmartBattery reports temperature in centi-Celsius (e.g. 3050 = 30.50 C)
                    snap.batteryTempC = tempCenti / 100.0
                } else {
                    let packSvc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceNameMatching("AppleSmartBatteryPack"))
                    if packSvc != 0 {
                        defer { IOObjectRelease(packSvc) }
                        if let cfBD = IORegistryEntryCreateCFProperty(packSvc, "BatteryData" as CFString, kCFAllocatorDefault, 0),
                           let packBD = cfBD.takeRetainedValue() as? [String: Any],
                           let packTemp = (packBD["Temperature"] as? NSNumber)?.doubleValue,
                           packTemp > 0 {
                            snap.batteryTempC = packTemp / 100.0
                        }
                    }
                }
                if let mv = (dict["Voltage"] as? NSNumber)?.doubleValue
                    ?? (dict["AppleRawBatteryVoltage"] as? NSNumber)?.doubleValue,
                   mv > 0 {
                    snap.batteryVoltageV = mv / 1000.0
                }
                if let ma = (dict["InstantAmperage"] as? NSNumber)?.intValue ?? (dict["Amperage"] as? NSNumber)?.intValue {
                    snap.batteryAmperageMA = ma
                    if let v = snap.batteryVoltageV {
                        snap.batteryWatts = abs(v * Double(ma) / 1000.0)
                    }
                }
                if let adapter = dict["AdapterDetails"] as? [String: Any],
                   let w = (adapter["Watts"] as? NSNumber)?.intValue, w > 0 {
                    snap.batteryAdapterWatts = w
                } else if let adapters = dict["AppleRawAdapterDetails"] as? [[String: Any]],
                          let w = adapters.compactMap({ ($0["Watts"] as? NSNumber)?.intValue }).first(where: { $0 > 0 }) {
                    snap.batteryAdapterWatts = w
                } else if let acDetails = IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any],
                          let w = (acDetails[kIOPSPowerAdapterWattsKey] as? NSNumber)?.intValue, w > 0 {
                    snap.batteryAdapterWatts = w
                }

                let timeEstimate = IOPSGetTimeRemainingEstimate()
                if timeEstimate > 0 && timeEstimate.isFinite {
                    snap.batteryTimeRemainingMinutes = Int(timeEstimate / 60.0)
                } else if snap.batteryCharging, let t = (dict["AvgTimeToFull"] as? NSNumber)?.intValue, t > 0 && t < 60000 {
                    snap.batteryTimeRemainingMinutes = t
                } else if !snap.batteryExternalConnected, let t = (dict["AvgTimeToEmpty"] as? NSNumber)?.intValue, t > 0 && t < 60000 {
                    snap.batteryTimeRemainingMinutes = t
                }
            }
        }

        if !snap.hasBattery,
           let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef],
           let first = sources.first,
           let desc = IOPSGetPowerSourceDescription(snapshot, first)?.takeUnretainedValue() as? [String: Any] {
            snap.hasBattery = true
            if let current = desc[kIOPSCurrentCapacityKey] as? Int,
               let maxCap = desc[kIOPSMaxCapacityKey] as? Int, maxCap > 0 {
                snap.batteryPercent = Int((Double(current) / Double(maxCap) * 100.0).rounded())
            }
            snap.batteryCharging = (desc[kIOPSIsChargingKey] as? Bool) ?? false
            snap.batteryExternalConnected = (desc[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
        }
    }

    // MARK: - SMC Fans, Temperatures & IOReport Power Rails

    private func collectSMCAndPower(into snap: inout VitalsHardwareSnapshot) {
        // 1. Fans from SMC
        if let fanCountDouble = SMC.shared.getValue("FNum") {
            let count = max(0, min(8, Int(fanCountDouble.rounded())))
            var fans: [VitalsFanInfo] = []
            for i in 0..<count {
                let rawName = SMC.shared.getStringValue("F\(i)ID")?.trimmingCharacters(in: .whitespacesAndNewlines)
                let fallbackName: String
                if count == 2 {
                    fallbackName = i == 0 ? ZtatL10n.tr("左侧风扇", "Left Fan") : ZtatL10n.tr("右侧风扇", "Right Fan")
                } else {
                    fallbackName = ZtatL10n.tr("风扇 #\(i + 1)", "Fan #\(i + 1)")
                }
                let name = (rawName?.isEmpty == false) ? rawName! : fallbackName
                let cur = SMC.shared.getValue("F\(i)Ac") ?? 0
                let minR = SMC.shared.getValue("F\(i)Mn") ?? 0
                let maxR = SMC.shared.getValue("F\(i)Mx") ?? 6000
                let modeVal = Int(SMC.shared.getValue(SMC.shared.fanModeKey(i)) ?? 0)
                let isAuto = (modeVal != 1)
                fans.append(VitalsFanInfo(
                    id: i,
                    name: name,
                    currentRPM: max(0, cur),
                    minRPM: max(0, minR),
                    maxRPM: max(minR + 1, maxR),
                    isAutomatic: isAuto
                ))
            }
            snap.fans = fans
        }

        // 2. Temperatures from SMC
        var temps: [VitalsTempSensor] = []
        for entry in smcTempKeys {
            if let v = SMC.shared.getValue(entry.key), v > 10 && v < 125 {
                temps.append(VitalsTempSensor(id: entry.key, name: entry.name, group: entry.group, celsius: v))
            }
        }

        // Supplement with Battery temp if SMC didn't expose one
        if let bt = snap.batteryTempC, bt > 5 && bt < 90, !temps.contains(where: { $0.group == .battery }) {
            temps.append(VitalsTempSensor(id: "IOPS_BAT", name: ZtatL10n.tr("电池电芯", "Battery Pack"), group: .battery, celsius: bt))
        }

        // If SMC returned very few CPU/GPU temps on newer Apple Silicon, supplement with AppleSilicon HID sensors
        #if arch(arm64)
        if !temps.contains(where: { $0.group == .cpu }) {
            if let hid = AppleSiliconSensors(0xff00, 5, 15) as? [String: Double] {
                didUseHIDSensors = true
                var cpuVals: [Double] = []
                var gpuVals: [Double] = []
                var socVals: [Double] = []
                for (k, v) in hid where v > 15 && v < 120 {
                    if k.contains("pACC") || k.contains("eACC") || k.contains("PMU tdie") {
                        cpuVals.append(v)
                    } else if k.contains("GPU") {
                        gpuVals.append(v)
                    } else if k.contains("SOC") {
                        socVals.append(v)
                    }
                }
                if !cpuVals.isEmpty {
                    let avg = cpuVals.reduce(0, +) / Double(cpuVals.count)
                    temps.append(VitalsTempSensor(id: "HID_CPU_AVG", name: ZtatL10n.tr("CPU 核心平均", "CPU Core Avg"), group: .cpu, celsius: avg))
                }
                if !gpuVals.isEmpty {
                    let avg = gpuVals.reduce(0, +) / Double(gpuVals.count)
                    temps.append(VitalsTempSensor(id: "HID_GPU_AVG", name: ZtatL10n.tr("GPU 核心平均", "GPU Die Avg"), group: .gpu, celsius: avg))
                }
                if !socVals.isEmpty {
                    let avg = socVals.reduce(0, +) / Double(socVals.count)
                    temps.append(VitalsTempSensor(id: "HID_SOC_AVG", name: ZtatL10n.tr("SoC 封装", "SoC Package"), group: .soc, celsius: avg))
                }
            }
        }
        #endif

        temps.sort { $0.celsius > $1.celsius }
        snap.temperatureSensors = temps

        let cpuTemps = temps.filter { $0.group == .cpu }.map(\.celsius)
        if !cpuTemps.isEmpty {
            snap.cpuTempC = cpuTemps.reduce(0, +) / Double(cpuTemps.count)
        }
        let gpuTemps = temps.filter { $0.group == .gpu }.map(\.celsius)
        if !gpuTemps.isEmpty {
            snap.gpuTempC = gpuTemps.reduce(0, +) / Double(gpuTemps.count)
        }
        if let hottest = temps.first {
            snap.hottestTempC = hottest.celsius
            snap.hottestSensorName = hottest.name
        }

        // 3. System Power & IOReport Power Rails
        if hasPSTRKey, let pstr = SMC.shared.getValue("PSTR"), pstr > 0 && pstr < 400 {
            snap.powerRails.systemTotalWatts = pstr
        }
        #if arch(arm64)
        if let rails = readIOReportPower() {
            snap.powerRails.cpuWatts = rails.cpu
            snap.powerRails.gpuWatts = rails.gpu
            snap.powerRails.aneWatts = rails.ane
            snap.powerRails.dramWatts = rails.dram
            if aneMaxPower > 0 {
                snap.aneUtilization = min(1.0, max(0.0, rails.ane / aneMaxPower))
            }
        }
        #endif
    }

    // MARK: - Bluetooth Connected Peripherals

    private func collectBluetooth(into snap: inout VitalsHardwareSnapshot) {
        snap.bluetoothDevices = Self.collectBluetoothSnapshot()
    }

    static func collectBluetoothSnapshot() -> [VitalsBluetoothDevice] {
        // Build battery lookup from AppleDeviceManagementHIDEventService IORegistry
        var hidBatteryByAddr: [String: Int] = [:]
        var hidBatteryByName: [String: Int] = [:]
        var iter: io_iterator_t = 0
        if IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleDeviceManagementHIDEventService"), &iter) == kIOReturnSuccess {
            defer { IOObjectRelease(iter) }
            while case let svc = IOIteratorNext(iter), svc != 0 {
                defer { IOObjectRelease(svc) }
                var props: Unmanaged<CFMutableDictionary>?
                if IORegistryEntryCreateCFProperties(svc, &props, kCFAllocatorDefault, 0) == kIOReturnSuccess,
                   let dict = props?.takeRetainedValue() as? [String: Any],
                   let pct = (dict["BatteryPercent"] as? NSNumber)?.intValue {
                    if let addr = (dict["DeviceAddress"] as? String)?.lowercased().replacingOccurrences(of: "-", with: ":") {
                        hidBatteryByAddr[addr] = pct
                    }
                    if let product = (dict["Product"] as? String)?.lowercased() {
                        hidBatteryByName[product] = pct
                    }
                }
            }
        }

        var list: [VitalsBluetoothDevice] = []
        if let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] {
            for dev in paired where dev.isConnected() {
                let name = dev.nameOrAddress ?? "Bluetooth Device"
                let addr = (dev.addressString ?? name).lowercased().replacingOccurrences(of: "-", with: ":")
                let lower = name.lowercased()

                let (cat, sym): (String, String)
                if lower.contains("airpods") {
                    (cat, sym) = ("AirPods", "airpodspro")
                } else if lower.contains("headphone") || lower.contains("buds") || lower.contains("beats") || lower.contains("sony") || lower.contains("bose") || dev.isHandsFreeDevice {
                    (cat, sym) = (ZtatL10n.tr("音频", "Audio"), "headphones")
                } else if lower.contains("mouse") || lower.contains("mx master") || lower.contains("anywhere") {
                    (cat, sym) = (ZtatL10n.tr("鼠标", "Mouse"), "computermouse.fill")
                } else if lower.contains("trackpad") {
                    (cat, sym) = (ZtatL10n.tr("触控板", "Trackpad"), "rectangle.and.hand.point.up.left.filled")
                } else if lower.contains("keyboard") || lower.contains("keychron") || lower.contains("hhkb") {
                    (cat, sym) = (ZtatL10n.tr("键盘", "Keyboard"), "keyboard.fill")
                } else {
                    (cat, sym) = (ZtatL10n.tr("外设", "Peripheral"), "dot.radiowaves.left.and.right")
                }

                let bat = hidBatteryByAddr[addr] ?? hidBatteryByName[lower]
                let rssiVal = Int(dev.rawRSSI())
                let rssi = (rssiVal < 0 && rssiVal > -120) ? rssiVal : nil
                list.append(VitalsBluetoothDevice(
                    id: addr,
                    name: name,
                    category: cat,
                    symbolName: sym,
                    batteryPercent: bat,
                    rssi: rssi
                ))
            }
        }
        return list
    }

    // MARK: - CoreAudio Devices & Volume

    struct AudioSnapshot: Sendable {
        let outputs: [VitalsAudioDevice]
        let activeOut: String
        let activeIn: String
        let vol: Float
        let muted: Bool
    }

    private func collectAudio(into snap: inout VitalsHardwareSnapshot) {
        let audio = Self.collectAudioSnapshot()
        snap.outputAudioDevices = audio.outputs
        snap.activeOutputAudioName = audio.activeOut
        snap.activeInputAudioName = audio.activeIn
        snap.systemVolume = audio.vol
        snap.isSystemMuted = audio.muted
    }

    static func collectAudioSnapshot() -> AudioSnapshot {
        let defaultOut = Self.defaultAudioDeviceID(isInput: false)
        let defaultIn = Self.defaultAudioDeviceID(isInput: true)

        var activeOut = "—"
        var activeIn = "—"
        var vol: Float = 0.5
        var muted = false
        if let defaultOut {
            activeOut = Self.audioDeviceName(defaultOut) ?? "—"
            vol = Self.getOutputVolume(deviceID: defaultOut)
            muted = Self.getOutputMuted(deviceID: defaultOut)
        }
        if let defaultIn {
            activeIn = Self.audioDeviceName(defaultIn) ?? "—"
        }

        return AudioSnapshot(
            outputs: Self.allOutputAudioDevices(defaultID: defaultOut),
            activeOut: activeOut,
            activeIn: activeIn,
            vol: vol,
            muted: muted
        )
    }

    static func setSystemVolume(_ volume: Float) {
        guard let dev = defaultAudioDeviceID(isInput: false) else { return }
        var clamped = min(1.0, max(0.0, volume))
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectHasProperty(dev, &addr) {
            AudioObjectSetPropertyData(dev, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &clamped)
            return
        }
        for ch: UInt32 in [0, 1, 2] {
            var chAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: ch
            )
            if AudioObjectHasProperty(dev, &chAddr) {
                AudioObjectSetPropertyData(dev, &chAddr, 0, nil, UInt32(MemoryLayout<Float32>.size), &clamped)
            }
        }
    }

    static func setSystemMuted(_ muted: Bool) {
        guard let dev = defaultAudioDeviceID(isInput: false) else { return }
        var val: UInt32 = muted ? 1 : 0
        for ch: UInt32 in [kAudioObjectPropertyElementMain, 1, 2] {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyMute,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: ch
            )
            if AudioObjectHasProperty(dev, &addr) {
                AudioObjectSetPropertyData(dev, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &val)
                if ch == kAudioObjectPropertyElementMain { return }
            }
        }
    }

    static func setDefaultOutputDevice(_ deviceID: AudioDeviceID) {
        var dev = deviceID
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &dev)
    }

    private static func defaultAudioDeviceID(isInput: Bool) -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: isInput ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID) == noErr,
              deviceID != 0 else { return nil }
        return deviceID
    }

    private static func audioDeviceName(_ deviceID: AudioDeviceID) -> String? {
        var cfName: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &cfName) == noErr,
              let name = cfName?.takeRetainedValue() as String? else { return nil }
        return name
    }

    private static func getOutputVolume(deviceID: AudioDeviceID) -> Float {
        var vol: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectHasProperty(deviceID, &addr),
           AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &vol) == noErr {
            return vol
        }
        for ch: UInt32 in [0, 1] {
            var chAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: ch
            )
            if AudioObjectHasProperty(deviceID, &chAddr),
               AudioObjectGetPropertyData(deviceID, &chAddr, 0, nil, &size, &vol) == noErr {
                return vol
            }
        }
        return 0.5
    }

    private static func getOutputMuted(deviceID: AudioDeviceID) -> Bool {
        var muted: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        for ch: UInt32 in [kAudioObjectPropertyElementMain, 1, 2] {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyMute,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: ch
            )
            if AudioObjectHasProperty(deviceID, &addr),
               AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &muted) == noErr {
                return muted != 0
            }
        }
        return false
    }

    private static func allOutputAudioDevices(defaultID: AudioDeviceID?) -> [VitalsAudioDevice] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr,
              size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        let actualCount = min(count, Int(size) / MemoryLayout<AudioDeviceID>.size)

        var result: [VitalsAudioDevice] = []
        for id in ids.prefix(actualCount) {
            var streamAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            var streamSize: UInt32 = 0
            if AudioObjectGetPropertyDataSize(id, &streamAddr, 0, nil, &streamSize) == noErr, streamSize > 0,
               let name = audioDeviceName(id) {
                result.append(VitalsAudioDevice(id: id, name: name, isDefault: id == defaultID))
            }
        }
        return result
    }

    // MARK: - IOReport Setup & Reading (Apple Silicon)

    #if arch(arm64)
    private func setupIOReportEnergy() {
        guard let ch = IOReportCopyChannelsInGroup("Energy Model" as CFString, nil, 0, 0, 0)?.takeRetainedValue() else { return }
        let size = CFDictionaryGetCount(ch)
        guard let mutable = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, size, ch),
              let dict = mutable as? [String: Any], dict["IOReportChannels"] != nil else { return }
        var sub: Unmanaged<CFMutableDictionary>?
        guard let subscription = IOReportCreateSubscription(nil, mutable, &sub, 0, nil) else {
            sub?.release()
            return
        }
        self.energySubscription = subscription
        self.energyChannels = sub?.takeRetainedValue() ?? mutable
    }

    private func readIOReportPower() -> (cpu: Double, gpu: Double, ane: Double, dram: Double)? {
        guard let sub = energySubscription,
              let ch = energyChannels,
              let sample = IOReportCreateSamples(sub, ch, nil)?.takeRetainedValue(),
              let dict = sample as? [String: Any],
              let list = dict["IOReportChannels"] as? NSArray else { return nil }

        let items = list as CFArray
        var cpuTotalJ: Double? = nil
        var cpuClusterSumJ: Double = 0
        var gpuTotalJ: Double? = nil
        var gpuClusterSumJ: Double = 0
        var aneTotalJ: Double? = nil
        var aneSumJ: Double = 0
        var dramTotalJ: Double? = nil
        var dramSumJ: Double = 0

        for i in 0..<CFArrayGetCount(items) {
            let item = unsafeBitCast(CFArrayGetValueAtIndex(items, i), to: CFDictionary.self)
            guard let group = IOReportChannelGetGroup(item)?.takeUnretainedValue() as? String,
                  group == "Energy Model",
                  let name = IOReportChannelGetChannelName(item)?.takeUnretainedValue() as? String else { continue }

            let raw = Double(IOReportSimpleGetIntegerValue(item, 0))
            let unit = (IOReportChannelGetUnitLabel(item)?.takeUnretainedValue() as? String)?
                .trimmingCharacters(in: .whitespaces).lowercased() ?? ""
            let joules: Double
            switch unit {
            case "mj":              joules = raw / 1e3
            case "uj", "µj", "μj":  joules = raw / 1e6
            case "nj":              joules = raw / 1e9
            case "pj":              joules = raw / 1e12
            default:                joules = raw / 1e9
            }

            if name.hasSuffix("CPU Energy") {
                cpuTotalJ = (cpuTotalJ ?? 0) + joules
            } else if name.hasPrefix("ECPU") || name.hasPrefix("PCPU") || name == "CPU" {
                cpuClusterSumJ += joules
            } else if name.hasSuffix("GPU Energy") {
                gpuTotalJ = (gpuTotalJ ?? 0) + joules
            } else if name == "GPU" || name.hasPrefix("GPU0") || name.hasPrefix("GPU1") {
                gpuClusterSumJ += joules
            } else if name == "ANE0" || name == "ANE" || name.hasSuffix("ANE Energy") {
                aneTotalJ = (aneTotalJ ?? 0) + joules
            } else if name.hasPrefix("ANE") {
                aneSumJ += joules
            } else if name == "DRAM0" || name == "DRAM" || name.hasSuffix("DRAM Energy") {
                dramTotalJ = (dramTotalJ ?? 0) + joules
            } else if name.hasPrefix("DRAM") {
                dramSumJ += joules
            }
        }

        let cpuJ = cpuTotalJ ?? cpuClusterSumJ
        let gpuJ = gpuTotalJ ?? gpuClusterSumJ
        let aneJ = aneTotalJ ?? aneSumJ
        let dramJ = dramTotalJ ?? dramSumJ

        let now = ProcessInfo.processInfo.systemUptime
        defer { prevEnergy = (cpuJ, gpuJ, aneJ, dramJ, now) }

        guard let prev = prevEnergy, now > prev.time else { return nil }
        let dt = now - prev.time
        return (
            cpu: max(0, (cpuJ - prev.cpu) / dt),
            gpu: max(0, (gpuJ - prev.gpu) / dt),
            ane: max(0, (aneJ - prev.ane) / dt),
            dram: max(0, (dramJ - prev.dram) / dt)
        )
    }

    private func setupIOReportFPS() {
        let groups = ["DCP", "DCP0", "DCPEXT0", "DCPEXT1", "DCPEXT2", "DCPEXT3"]
        var merged: CFMutableDictionary?
        for g in groups {
            guard let ch = IOReportCopyChannelsInGroup(g as CFString, "swap" as CFString, 0, 0, 0)?.takeRetainedValue() else { continue }
            if merged == nil {
                merged = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, ch)
            } else {
                IOReportMergeChannels(merged, ch, nil)
            }
        }
        guard let merged, let dict = merged as? [String: Any], dict["IOReportChannels"] != nil else { return }
        var sub: Unmanaged<CFMutableDictionary>?
        guard let subscription = IOReportCreateSubscription(nil, merged, &sub, 0, nil) else {
            sub?.release()
            return
        }
        self.fpsSubscription = subscription
        self.fpsChannels = sub?.takeRetainedValue() ?? merged
    }

    private func readIOReportFPS() -> Double? {
        guard let sub = fpsSubscription,
              let ch = fpsChannels,
              let sample = IOReportCreateSamples(sub, ch, nil)?.takeRetainedValue(),
              let dict = sample as? [String: Any],
              let list = dict["IOReportChannels"] as? NSArray else { return nil }
        let items = list as CFArray
        var totalsByGroup: [String: Int64] = [:]
        for i in 0..<CFArrayGetCount(items) {
            let item = unsafeBitCast(CFArrayGetValueAtIndex(items, i), to: CFDictionary.self)
            guard let g = IOReportChannelGetGroup(item)?.takeUnretainedValue() as? String,
                  g.hasPrefix("DCP"),
                  let sg = IOReportChannelGetSubGroup(item)?.takeUnretainedValue() as? String,
                  sg == "swap" else { continue }
            totalsByGroup[g, default: 0] += IOReportSimpleGetIntegerValue(item, 0)
        }
        let now = ProcessInfo.processInfo.systemUptime
        defer {
            prevFramesByGroup = totalsByGroup
            prevFramesTime = now
        }
        guard let prevTime = prevFramesTime, now > prevTime else { return nil }
        let dt = now - prevTime
        // Report the max active display pipe's FPS instead of summing across multiple monitors
        var maxFPS: Double = 0
        for (group, curCount) in totalsByGroup {
            guard let prevCount = prevFramesByGroup[group], curCount >= prevCount else { continue }
            let fps = Double(curCount - prevCount) / dt
            if fps > maxFPS { maxFPS = fps }
        }
        return maxFPS > 0 ? maxFPS : nil
    }
    #endif

    private static func read64BitNetworkBytesByIndex(forIndices targetIndices: Set<UInt32>) -> [UInt32: (inBytes: UInt64, outBytes: UInt64)] {
        guard !targetIndices.isEmpty else { return [:] }
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var size: size_t = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return [:] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, u_int(mib.count), &buffer, &size, nil, 0) == 0 else { return [:] }

        var result: [UInt32: (inBytes: UInt64, outBytes: UInt64)] = [:]
        var offset = 0
        while offset + MemoryLayout<if_msghdr>.size <= size {
            var header = if_msghdr()
            buffer.withUnsafeBytes { src in
                if let base = src.baseAddress {
                    _ = memcpy(&header, base.advanced(by: offset), MemoryLayout<if_msghdr>.size)
                }
            }
            guard header.ifm_msglen > 0 else { break }
            if Int32(header.ifm_type) == RTM_IFINFO2,
               offset + MemoryLayout<if_msghdr2>.size <= size {
                var header2 = if_msghdr2()
                buffer.withUnsafeBytes { src in
                    if let base = src.baseAddress {
                        _ = memcpy(&header2, base.advanced(by: offset), MemoryLayout<if_msghdr2>.size)
                    }
                }
                let idx = UInt32(header2.ifm_index)
                if targetIndices.contains(idx) {
                    result[idx] = (header2.ifm_data.ifi_ibytes, header2.ifm_data.ifi_obytes)
                }
            }
            offset += Int(header.ifm_msglen)
        }
        return result
    }

    // MARK: - Helpers

    private static func resolveMaxANEPower(for platform: Platform?) -> Double {
        switch platform {
        case .m1, .m1Pro, .m1Max: return 2.0
        case .m1Ultra:            return 4.0
        case .m2, .m2Pro, .m2Max: return 2.5
        case .m2Ultra:            return 5.0
        case .m3, .m3Pro, .m3Max: return 3.0
        case .m3Ultra:            return 6.0
        case .m4, .m4Pro, .m4Max: return 6.0
        case .m5, .m5Pro, .m5Max: return 8.0
        case .m5Ultra, .m6, .m6Pro, .m6Max: return 16.0
        default: return 8.0
        }
    }

    private static func discoverSMCTemperatureKeys(available: Set<String>) -> [(String, String, VitalsTempSensor.Group)] {
        let candidates: [(String, String, VitalsTempSensor.Group)] = [
            // Apple Silicon M1/M2/M3/M4/M5 CPU P/E clusters
            ("Tp09", "CPU E-Core 1", .cpu),
            ("Tp0T", "CPU E-Core 2", .cpu),
            ("Tp01", "CPU P-Core 1", .cpu),
            ("Tp05", "CPU P-Core 2", .cpu),
            ("Tp0D", "CPU P-Core 3", .cpu),
            ("Tp0H", "CPU P-Core 4", .cpu),
            ("Tp0L", "CPU P-Core 5", .cpu),
            ("Tp0P", "CPU P-Core 6", .cpu),
            ("Tp0X", "CPU P-Core 7", .cpu),
            ("Tp0b", "CPU P-Core 8", .cpu),
            ("Tp0f", "CPU P-Core 9", .cpu),
            ("Tp0j", "CPU P-Core 10", .cpu),
            ("Te05", "CPU E-Core Cluster", .cpu),
            ("Te0L", "CPU E-Core Die", .cpu),
            ("Te0P", "CPU E-Core Thermal", .cpu),
            ("Te0S", "CPU E-Core Sensor", .cpu),
            ("Tf04", "CPU P-Core Cluster 1", .cpu),
            ("Tf09", "CPU P-Core Cluster 2", .cpu),
            ("Tf0A", "CPU P-Core Cluster 3", .cpu),
            ("Tf0B", "CPU P-Core Cluster 4", .cpu),
            ("Tf0D", "CPU P-Core Cluster 5", .cpu),
            ("Tf0E", "CPU P-Core Cluster 6", .cpu),
            // Intel CPU
            ("TC0P", "CPU Proximity", .cpu),
            ("TC0D", "CPU Die", .cpu),
            ("TC0E", "CPU Core Avg", .cpu),
            ("TC0F", "CPU Core Max", .cpu),
            // GPU (Apple Silicon & Intel)
            ("Tg05", "GPU Core 1", .gpu),
            ("Tg0D", "GPU Core 2", .gpu),
            ("Tg0L", "GPU Core 3", .gpu),
            ("Tg0T", "GPU Core 4", .gpu),
            ("Tg0f", "GPU Die 1", .gpu),
            ("Tg0j", "GPU Die 2", .gpu),
            ("Tf14", "GPU Cluster 1", .gpu),
            ("Tf18", "GPU Cluster 2", .gpu),
            ("Tf19", "GPU Cluster 3", .gpu),
            ("Tf1A", "GPU Cluster 4", .gpu),
            ("TG0D", "GPU Die", .gpu),
            ("TG0P", "GPU Proximity", .gpu),
            // SoC / Power / System
            ("Tp0h", "SoC Die", .soc),
            ("Ts0P", "Palm Rest Left", .system),
            ("Ts1P", "Palm Rest Right", .system),
            ("TaLP", "Airflow Left", .system),
            ("TaRF", "Airflow Right", .system),
            ("TW0P", "Wi-Fi / Airport", .system),
            ("Tm0P", "Main Logic Board", .system),
            // Storage / NAND
            ("TH0a", "NVMe SSD A", .storage),
            ("TH0b", "NVMe SSD B", .storage),
            ("TH0x", "NAND Flash", .storage),
            // Battery
            ("TB0T", "Battery Sensor 1", .battery),
            ("TB1T", "Battery Sensor 2", .battery),
            ("TB2T", "Battery Sensor 3", .battery),
        ]
        return candidates.filter { available.contains($0.0) }
    }
}

// MARK: - Async Auxiliary Scanners (Sleep Assertions & Containers)

internal enum VitalsAuxiliaryScanner {
    static func scanSleepAssertions() -> [VitalsSleepAssertion] {
        // Native IOKit IOPMCopyAssertionsByProcess (zero subprocess fork, strictly filters to real sleep-preventing types)
        let sleepTypes: Set<String> = [
            "PreventUserIdleSystemSleep",
            "PreventUserIdleDisplaySleep",
            "NoIdleSleepAssertion",
            "NoDisplaySleepAssertion",
            "PreventSystemSleep"
        ]
        var cfDict: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&cfDict) == kIOReturnSuccess,
              let byPID = cfDict?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else {
            return []
        }

        var results: [VitalsSleepAssertion] = []
        var seen = Set<String>()
        for (pidNum, list) in byPID {
            let pid = pidNum.int32Value
            guard pid > 0 else { continue }
            for entry in list {
                guard let assertType = entry["AssertType"] as? String,
                      sleepTypes.contains(assertType) else { continue }
                let procName = (entry["Process Name"] as? String)
                    ?? Self.processShortName(pid: pid)
                let reason = (entry["AssertName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let key = "\(pid):\(assertType):\(reason)"
                guard seen.insert(key).inserted else { continue }
                results.append(VitalsSleepAssertion(
                    id: key,
                    pid: pid,
                    processName: procName,
                    assertionType: assertType,
                    reason: reason.isEmpty ? assertType : reason
                ))
            }
        }
        return results.sorted { $0.processName.localizedCaseInsensitiveCompare($1.processName) == .orderedAscending }
    }

    private static func processShortName(pid: Int32) -> String {
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        if proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 {
            return (String(cString: buf) as NSString).lastPathComponent
        }
        var nameBuf = [CChar](repeating: 0, count: 256)
        if proc_name(pid, &nameBuf, UInt32(nameBuf.count)) > 0 {
            return String(cString: nameBuf)
        }
        return "PID \(pid)"
    }

    static func scanContainersQuick() -> (bin: String, items: [VitalsContainerItem])? {
        let fm = FileManager.default
        let home = NSHomeDirectory()
        // Zero-idle check: only run CLI if a known container runtime socket actually exists
        let dockerSockets = [
            "/var/run/docker.sock",
            "\(home)/.docker/run/docker.sock",
            "\(home)/.orbstack/run/docker.sock",
            "\(home)/.colima/default/docker.sock",
            "\(home)/.rd/docker.sock"
        ]
        let hasDockerSocket = dockerSockets.contains { fm.fileExists(atPath: $0) }
        let dockerPaths = ["/usr/local/bin/docker", "/opt/homebrew/bin/docker", "/Applications/Docker.app/Contents/Resources/bin/docker"]
        let dockerBin = dockerPaths.first { fm.isExecutableFile(atPath: $0) }

        guard hasDockerSocket, let bin = dockerBin else { return nil }

        let engineName: String
        if fm.fileExists(atPath: "\(home)/.orbstack/run/docker.sock") {
            engineName = "OrbStack"
        } else if fm.fileExists(atPath: "\(home)/.colima/default/docker.sock") {
            engineName = "Colima"
        } else {
            engineName = "Docker"
        }

        // Fast docker ps (~30-50ms)
        guard let psOut = runCommand(bin, args: ["ps", "--format", "{{.ID}}\t{{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}"], timeoutSeconds: 2.0),
              !psOut.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return (bin, [])
        }

        var items: [VitalsContainerItem] = []
        for line in psOut.split(separator: "\n") {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 4 else { continue }
            let cid = String(parts[0].prefix(12))
            items.append(VitalsContainerItem(
                id: cid,
                name: parts[1],
                image: parts[2],
                engine: engineName,
                status: parts[3],
                cpuPercent: 0,
                memoryText: "—",
                ports: parts.count > 4 ? parts[4] : ""
            ))
        }
        return (bin, items)
    }

    static func enrichContainerStats(bin: String, items: [VitalsContainerItem]) -> [VitalsContainerItem] {
        guard !items.isEmpty else { return items }
        var statsMap: [String: (cpu: Double, mem: String)] = [:]
        if let stOut = runCommand(bin, args: ["stats", "--no-stream", "--format", "{{.ID}}\t{{.CPUPerc}}\t{{.MemUsage}}"], timeoutSeconds: 3.0) {
            for line in stOut.split(separator: "\n") {
                let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                guard parts.count >= 3 else { continue }
                let cid = String(parts[0].prefix(12))
                let cpuStr = parts[1].replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces)
                statsMap[cid] = (Double(cpuStr) ?? 0, parts[2])
            }
        }
        return items.map { item in
            guard let st = statsMap[item.id] else { return item }
            return VitalsContainerItem(
                id: item.id,
                name: item.name,
                image: item.image,
                engine: item.engine,
                status: item.status,
                cpuPercent: st.cpu,
                memoryText: st.mem,
                ports: item.ports
            )
        }
    }

    static func scanContainers() -> [VitalsContainerItem] {
        guard let quick = scanContainersQuick(), !quick.items.isEmpty else { return [] }
        return enrichContainerStats(bin: quick.bin, items: quick.items)
    }

    static func controlContainer(id: String, action: String) {
        let fm = FileManager.default
        let dockerPaths = ["/usr/local/bin/docker", "/opt/homebrew/bin/docker", "/Applications/Docker.app/Contents/Resources/bin/docker"]
        guard let bin = dockerPaths.first(where: { fm.isExecutableFile(atPath: $0) }) else { return }
        _ = runCommand(bin, args: [action, id], timeoutSeconds: 5.0)
    }

    static func runCommand(_ path: String, args: [String], timeoutSeconds: TimeInterval) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = args
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return nil }

        // CRITICAL: Drain stdout concurrently BEFORE waitUntilExit() so outputs > 64 KB
        // (such as `/bin/ps` at ~160 KB or `lsof`/`sample`) never deadlock the pipe buffer.
        let readHandle = pipe.fileHandleForReading
        var collected = Data()
        let sema = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            collected = readHandle.readDataToEndOfFile()
            task.waitUntilExit()
            sema.signal()
        }

        if sema.wait(timeout: .now() + timeoutSeconds) == .timedOut {
            if task.isRunning {
                task.terminate()
            }
            try? readHandle.close()
            return nil
        }
        return String(data: collected, encoding: .utf8)
    }
}
