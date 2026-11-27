// SPDX-License-Identifier: GPL-3.0-or-later
// ZTAT-PATCH: Reference-counted Zero-Idle VitalsDashboardModel powering both
// the Vitals Menu Bar Popover and the Full Activity Monitor Replacement Task Manager.

import AppKit
import Combine
import CoreAudio
import Darwin
import Foundation
import StatsKit
import ZtatCore

public enum VitalsUnixSignal: Int32, CaseIterable, Identifiable, Sendable {
    case sighup  = 1
    case sigint  = 2
    case sigquit = 3
    case sigabrt = 6
    case sigkill = 9
    case sigterm = 15
    case sigstop = 17
    case sigcont = 19
    case sigusr1 = 30
    case sigusr2 = 31

    public var id: Int32 { rawValue }

    public var label: String {
        switch self {
        case .sighup:  return "SIGHUP (1) — 挂起/重载"
        case .sigint:  return "SIGINT (2) — 中断"
        case .sigquit: return "SIGQUIT (3) — 退出"
        case .sigabrt: return "SIGABRT (6) — 中止"
        case .sigkill: return "SIGKILL (9) — 强制终止"
        case .sigterm: return "SIGTERM (15) — 优雅终止"
        case .sigstop: return "SIGSTOP (17) — 暂停挂起"
        case .sigcont: return "SIGCONT (19) — 恢复运行"
        case .sigusr1: return "SIGUSR1 (30) — 用户信号 1"
        case .sigusr2: return "SIGUSR2 (31) — 用户信号 2"
        }
    }
}

@MainActor
public final class VitalsDashboardModel: ObservableObject {
    public static let shared = VitalsDashboardModel()

    // Navigation
    @Published public var activePane: VitalsPane = .overview

    // Hardware Telemetry Snapshot
    @Published public var hardware = VitalsHardwareSnapshot()

    // Rolling Sparkline Histories (60 samples)
    private let maxHistoryCount = 60
    @Published public var cpuHistory: [Double] = []
    @Published public var gpuHistory: [Double] = []
    @Published public var aneHistory: [Double] = []
    @Published public var memHistory: [Double] = []
    @Published public var diskReadHistory: [Double] = []
    @Published public var diskWriteHistory: [Double] = []
    @Published public var netDownHistory: [Double] = []
    @Published public var netUpHistory: [Double] = []
    @Published public var powerHistory: [Double] = []
    @Published public var tempHistory: [Double] = []

    // Process, App Group, Dev & Auxiliary State
    @Published public var processes: [VitalsProcessItem] = []
    @Published public var appGroups: [VitalsAppGroup] = []
    @Published public var listeningPorts: [VitalsPortItem] = []
    @Published public var agentSessions: [VitalsAgentSession] = []
    @Published public var devProjects: [VitalsDevProject] = []
    @Published public var containers: [VitalsContainerItem] = []
    @Published public var sleepAssertions: [VitalsSleepAssertion] = []
    @Published public var healthAlerts: [VitalsHealthAlert] = []
    @Published public var totalThreadCount: Int = 0
    @Published public var lastUpdatedAt: Date = Date()

    // Task Manager Controls
    @Published public var searchQuery: String = ""
    @Published public var processViewMode: Int = 0 // 0: App Grouped, 1: Flat List, 2: Hierarchy Tree
    @Published public var processScope: Int = 0    // 0: All, 1: My Processes, 2: User Apps, 3: System/Daemons, 4: Active CPU, 5: Dev & Ports, 6: AI Agents
    @Published public var sortColumn: Int = 0      // 0: CPU, 1: Memory, 2: Energy, 3: Disk Write, 4: Disk Read, 5: Threads, 6: Name, 7: PID, 8: CPU Time
    @Published public var sortAscending: Bool = false
    @Published public var expandedGroupIDs: Set<String> = []
    @Published public var updateIntervalSeconds: Double = 2.0 {
        didSet {
            if !activeConsumers.isEmpty { rescheduleTimer() }
        }
    }
    @Published public var isSamplingPaused: Bool = false

    // On-Demand Deep Inspector State
    @Published public var deepDetails: VitalsProcessDeepDetails? = nil
    @Published public var isLoadingDeepDetails: Bool = false
    @Published public var sampleOutput: String = ""
    @Published public var isSamplingCallStack: Bool = false
    @Published public var diskHolders: [VitalsDiskHolderItem] = []
    @Published public var diskHoldersTarget: String? = nil
    @Published public var isScanningDiskHolders: Bool = false
    @Published public var actionFeedback: String? = nil

    // Engines (lazily initialized & accessed exclusively on serial background queue — zero main-thread SMC/IOReport stall)
    private let samplerQueue = DispatchQueue(label: "dev.ztat.vitals.sampler", qos: .userInitiated)
    private let auxQueue = DispatchQueue(label: "dev.ztat.vitals.aux", qos: .utility)
    private let containerQueue = DispatchQueue(label: "dev.ztat.vitals.containers", qos: .utility)
    private let audioWriteQueue = DispatchQueue(label: "dev.ztat.vitals.audio", qos: .userInteractive)
    private nonisolated(unsafe) var hardwareCollector: VitalsHardwareCollector?
    private nonisolated(unsafe) var processEngine: VitalsProcessEngine?
    private var needsBaselineReset: Bool = false
    private var pendingForceSlowScan: Bool = false
    private var pendingRefresh: Bool = false
    private var warmupWorkItem: DispatchWorkItem?
    private var deepDetailsRequestID: UInt64 = 0
    private var sampleRequestID: UInt64 = 0
    private var sessionGeneration: UInt64 = 0

    private var timer: AnyCancellable?
    private var activeConsumers: Set<String> = []
    private var isSamplingInFlight: Bool = false
    private var isAuxScanInFlight: Bool = false
    private var isContainerScanInFlight: Bool = false
    private var tickCounter: Int = 0
    private var cachedPorts: [VitalsPortItem] = []
    private var cachedAssertions: [VitalsSleepAssertion] = []
    private var cachedContainers: [VitalsContainerItem] = []
    private var cachedBluetooth: [VitalsBluetoothDevice] = []
    private var cachedAudio: (outputs: [VitalsAudioDevice], activeOut: String, activeIn: String, vol: Float, muted: Bool)?

    private init() {}

    // MARK: - Reference-Counted Zero-Idle Consumer Lifecycle

    public func beginConsumer(_ id: String) {
        let wasEmpty = activeConsumers.isEmpty
        activeConsumers.insert(id)
        if wasEmpty {
            sessionGeneration &+= 1
            tickCounter = 0
            needsBaselineReset = true
            refresh(forceSlowScans: true)
            rescheduleTimer()
        } else {
            refresh(forceSlowScans: false)
        }
    }

    public func endConsumer(_ id: String) {
        activeConsumers.remove(id)
        if activeConsumers.isEmpty {
            sessionGeneration &+= 1
            timer?.cancel()
            timer = nil
            warmupWorkItem?.cancel()
            warmupWorkItem = nil
            pendingRefresh = false
            pendingForceSlowScan = false
            needsBaselineReset = true
            samplerQueue.async { [weak self] in
                self?.hardwareCollector?.resetDeltaBaselines()
                self?.processEngine?.resetBaselines()
            }
        }
    }

    /// Backwards-compatible convenience wrappers
    public func start() { beginConsumer("legacy") }
    public func stop() { endConsumer("legacy") }

    private func rescheduleTimer() {
        timer?.cancel()
        let interval = max(1.0, updateIntervalSeconds)
        timer = Timer.publish(every: interval, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self, !self.isSamplingPaused else { return }
                self.refresh(forceSlowScans: false)
            }
    }

    // MARK: - Asynchronous Coordinated Telemetry Refresh

    public func refresh(forceSlowScans: Bool = false) {
        if isSamplingInFlight {
            pendingRefresh = true
            if forceSlowScans { pendingForceSlowScan = true }
            return
        }
        isSamplingInFlight = true
        tickCounter += 1
        let runSlowScans = forceSlowScans || (tickCounter == 1) || (tickCounter % 3 == 0)
        let generation = sessionGeneration

        // Snapshot NSWorkspace.runningApplications on MainActor cleanly
        var appsSnapshot: [Int32: (name: String, bundleURL: URL?, bundleID: String?)] = [:]
        for app in NSWorkspace.shared.runningApplications {
            appsSnapshot[app.processIdentifier] = (
                name: app.localizedName ?? "",
                bundleURL: app.bundleURL,
                bundleID: app.bundleIdentifier
            )
        }

        let prevPorts = cachedPorts
        let prevAssertions = cachedAssertions
        let prevContainers = cachedContainers
        let prevBT = cachedBluetooth
        let prevAudio = cachedAudio
        let shouldResetBaselines = needsBaselineReset
        needsBaselineReset = false
        let currentTick = tickCounter

        // Decouple slow peripheral/subprocess scans (lsof, IOBluetooth, CoreAudio, docker ps/stats)
        // onto dedicated background queues so core hardware + process telemetry ALWAYS lands in <100ms.
        if runSlowScans {
            triggerAuxScan(generation: generation)
            triggerContainerScan(generation: generation)
        }

        samplerQueue.async { [weak self] in
            guard let self else { return }
            let hwCollector: VitalsHardwareCollector
            if let existing = self.hardwareCollector {
                hwCollector = existing
            } else {
                let created = VitalsHardwareCollector()
                self.hardwareCollector = created
                hwCollector = created
            }
            let procEngine: VitalsProcessEngine
            if let existing = self.processEngine {
                procEngine = existing
            } else {
                let created = VitalsProcessEngine()
                self.processEngine = created
                procEngine = created
            }
            if shouldResetBaselines {
                hwCollector.resetDeltaBaselines()
                procEngine.resetBaselines()
            }

            var hwSnap = hwCollector.collect(includeSlowPeripherals: false)
            hwSnap.bluetoothDevices = prevBT
            if let a = prevAudio {
                hwSnap.outputAudioDevices = a.outputs
                hwSnap.activeOutputAudioName = a.activeOut
                hwSnap.activeInputAudioName = a.activeIn
                hwSnap.systemVolume = a.vol
                hwSnap.isSystemMuted = a.muted
            }

            let assertionPIDs = Set(prevAssertions.map(\.pid))
            let procSnap = procEngine.sample(
                ports: prevPorts,
                sleepAssertionPIDs: assertionPIDs,
                runningAppsSnapshot: appsSnapshot
            )

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isSamplingInFlight = false
                guard self.sessionGeneration == generation, !self.activeConsumers.isEmpty else {
                    self.pendingRefresh = false
                    self.pendingForceSlowScan = false
                    return
                }

                // Preserve any newer aux BT/Audio data that finished while fast sample was in flight
                var mergedHW = hwSnap
                mergedHW.bluetoothDevices = self.cachedBluetooth
                if let latestAudio = self.cachedAudio {
                    mergedHW.outputAudioDevices = latestAudio.outputs
                    mergedHW.activeOutputAudioName = latestAudio.activeOut
                    mergedHW.activeInputAudioName = latestAudio.activeIn
                    mergedHW.systemVolume = latestAudio.vol
                    mergedHW.isSystemMuted = latestAudio.muted
                }

                self.hardware = mergedHW
                self.processes = procSnap.processes
                self.appGroups = procSnap.appGroups
                self.listeningPorts = self.cachedPorts
                self.agentSessions = procSnap.agentSessions
                self.devProjects = procSnap.devProjects
                self.containers = self.cachedContainers.isEmpty ? prevContainers : self.cachedContainers
                self.sleepAssertions = self.cachedAssertions
                self.totalThreadCount = procSnap.totalThreadCount
                self.lastUpdatedAt = Date()

                // Skip pushing the initial zero-delta baseline sample into sparklines;
                // schedule an immediate 0.4s follow-up sample so real deltas populate right away!
                if !shouldResetBaselines {
                    self.appendHistory(&self.cpuHistory, mergedHW.cpuUsage)
                    self.appendHistory(&self.gpuHistory, mergedHW.gpuUsage)
                    self.appendHistory(&self.aneHistory, mergedHW.aneUtilization)
                    self.appendHistory(&self.memHistory, mergedHW.memory.usedFraction)
                    self.appendHistory(&self.diskReadHistory, mergedHW.diskReadMBs)
                    self.appendHistory(&self.diskWriteHistory, mergedHW.diskWriteMBs)
                    self.appendHistory(&self.netDownHistory, mergedHW.netDownloadKBs)
                    self.appendHistory(&self.netUpHistory, mergedHW.netUploadKBs)
                    let powerVal = mergedHW.powerRails.systemTotalWatts ?? mergedHW.powerRails.packageTotalWatts
                    self.appendHistory(&self.powerHistory, powerVal)
                    if let temp = mergedHW.hottestTempC ?? mergedHW.cpuTempC {
                        self.appendHistory(&self.tempHistory, temp)
                    }
                } else if currentTick == 1 && !self.activeConsumers.isEmpty && !self.isSamplingPaused {
                    self.warmupWorkItem?.cancel()
                    let work = DispatchWorkItem { [weak self] in
                        guard let self, !self.activeConsumers.isEmpty, !self.isSamplingPaused else { return }
                        self.refresh(forceSlowScans: false)
                    }
                    self.warmupWorkItem = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
                }

                self.healthAlerts = self.computeHealthAlerts(hw: mergedHW, procs: procSnap.processes, assertions: self.cachedAssertions)

                if self.pendingRefresh && !self.activeConsumers.isEmpty {
                    let forceSlow = self.pendingForceSlowScan
                    self.pendingRefresh = false
                    self.pendingForceSlowScan = false
                    self.refresh(forceSlowScans: forceSlow)
                } else {
                    self.pendingRefresh = false
                    self.pendingForceSlowScan = false
                }
            }
        }
    }

    private func triggerAuxScan(generation: UInt64) {
        guard !isAuxScanInFlight else { return }
        isAuxScanInFlight = true
        auxQueue.async { [weak self] in
            let bt = VitalsHardwareCollector.collectBluetoothSnapshot()
            let audio = VitalsHardwareCollector.collectAudioSnapshot()
            let assertions = VitalsAuxiliaryScanner.scanSleepAssertions()
            let ports = VitalsProcessEngine.scanListeningPorts()

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isAuxScanInFlight = false
                guard self.sessionGeneration == generation, !self.activeConsumers.isEmpty else { return }

                self.cachedBluetooth = bt
                self.cachedAudio = (audio.outputs, audio.activeOut, audio.activeIn, audio.vol, audio.muted)
                self.cachedAssertions = assertions
                self.cachedPorts = ports

                var hw = self.hardware
                hw.bluetoothDevices = bt
                hw.outputAudioDevices = audio.outputs
                hw.activeOutputAudioName = audio.activeOut
                hw.activeInputAudioName = audio.activeIn
                hw.systemVolume = audio.vol
                hw.isSystemMuted = audio.muted
                self.hardware = hw

                self.sleepAssertions = assertions
                self.listeningPorts = ports

                // Patch fresh port & sleep-assertion annotations onto already-displayed processes immediately
                let portByPID = Dictionary(grouping: ports, by: \.pid).mapValues {
                    Array(Set($0.map(\.port))).sorted()
                }
                let assertPIDs = Set(assertions.map(\.pid))
                if !self.processes.isEmpty {
                    self.processes = self.processes.map { proc in
                        var copy = proc
                        copy.ports = portByPID[proc.id] ?? []
                        copy.preventingSleep = assertPIDs.contains(proc.id)
                        return copy
                    }
                    self.appGroups = self.appGroups.map { group in
                        var g = group
                        g.processes = g.processes.map { proc in
                            var copy = proc
                            copy.ports = portByPID[proc.id] ?? []
                            copy.preventingSleep = assertPIDs.contains(proc.id)
                            return copy
                        }
                        return g
                    }
                }
                self.healthAlerts = self.computeHealthAlerts(hw: hw, procs: self.processes, assertions: assertions)
            }
        }
    }

    private func triggerContainerScan(generation: UInt64) {
        guard !isContainerScanInFlight else { return }
        isContainerScanInFlight = true
        let prevStatsByID: [String: (cpu: Double, mem: String)] = Dictionary(
            cachedContainers.map { ($0.id, ($0.cpuPercent, $0.memoryText)) },
            uniquingKeysWith: { first, _ in first }
        )

        containerQueue.async { [weak self] in
            guard let quick = VitalsAuxiliaryScanner.scanContainersQuick() else {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.isContainerScanInFlight = false
                    guard self.sessionGeneration == generation, !self.activeConsumers.isEmpty else { return }
                    self.cachedContainers = []
                    self.containers = []
                }
                return
            }

            // Stage 1 (~35ms): publish running container inventory immediately (carrying prior CPU/mem until stage 2 lands)
            let quickMerged = quick.items.map { item -> VitalsContainerItem in
                guard let prev = prevStatsByID[item.id] else { return item }
                return VitalsContainerItem(
                    id: item.id,
                    name: item.name,
                    image: item.image,
                    engine: item.engine,
                    status: item.status,
                    cpuPercent: prev.cpu,
                    memoryText: prev.mem,
                    ports: item.ports
                )
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if quickMerged.isEmpty {
                    self.isContainerScanInFlight = false
                }
                guard self.sessionGeneration == generation, !self.activeConsumers.isEmpty else { return }
                self.cachedContainers = quickMerged
                self.containers = quickMerged
            }

            guard !quick.items.isEmpty else { return }

            // Stage 2 (~1.5-2s): enrich with live `docker stats --no-stream` asynchronously
            let enriched = VitalsAuxiliaryScanner.enrichContainerStats(bin: quick.bin, items: quick.items)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isContainerScanInFlight = false
                guard self.sessionGeneration == generation, !self.activeConsumers.isEmpty else { return }
                self.cachedContainers = enriched
                self.containers = enriched
            }
        }
    }

    private func appendHistory(_ arr: inout [Double], _ val: Double) {
        let safe = val.isFinite ? max(0, val) : 0
        arr.append(safe)
        if arr.count > maxHistoryCount {
            arr.removeFirst(arr.count - maxHistoryCount)
        }
    }

    private func computeHealthAlerts(
        hw: VitalsHardwareSnapshot,
        procs: [VitalsProcessItem],
        assertions: [VitalsSleepAssertion]
    ) -> [VitalsHealthAlert] {
        var alerts: [VitalsHealthAlert] = []
        if hw.memory.level == .critical {
            alerts.append(VitalsHealthAlert(
                id: "mem-crit",
                severity: .critical,
                title: ZtatL10n.tr("内存压力严重", "Critical Memory Pressure"),
                detail: String(format: ZtatL10n.tr("已用 %.1f / %.0f GB，Swap %.1f GB", "Used %.1f / %.0f GB, Swap %.1f GB"), hw.memory.usedGB, hw.memory.totalGB, hw.memory.swapUsedGB),
                targetPane: .memory
            ))
        } else if hw.memory.level == .warning {
            alerts.append(VitalsHealthAlert(
                id: "mem-warn",
                severity: .warning,
                title: ZtatL10n.tr("内存承压", "Elevated Memory Pressure"),
                detail: String(format: ZtatL10n.tr("压缩 %.1f GB · Swap %.1f GB", "Compressed %.1f GB · Swap %.1f GB"), hw.memory.compressedGB, hw.memory.swapUsedGB),
                targetPane: .memory
            ))
        }
        if hw.thermalState == .critical || hw.thermalState == .serious {
            let tempStr = hw.hottestTempC.map { String(format: "%.0f°C", $0) } ?? ""
            alerts.append(VitalsHealthAlert(
                id: "thermal",
                severity: hw.thermalState == .critical ? .critical : .warning,
                title: ZtatL10n.tr("整机发热偏高 \(tempStr)", "Thermal Strain \(tempStr)"),
                detail: hw.hottestSensorName ?? ZtatL10n.tr("建议查看温控与高负载进程", "Inspect thermals & high-CPU apps"),
                targetPane: .fans
            ))
        }
        if let rootVol = hw.diskVolumes.first, rootVol.usedFraction > 0.90 {
            alerts.append(VitalsHealthAlert(
                id: "disk-low",
                severity: rootVol.usedFraction > 0.95 ? .critical : .warning,
                title: ZtatL10n.tr("磁盘剩余空间紧张", "Low Disk Space"),
                detail: String(format: ZtatL10n.tr("%@ 仅剩 %.1f GB 可用", "%@ has only %.1f GB free"), rootVol.name, rootVol.freeGB),
                targetPane: .disk
            ))
        }
        if let runaway = procs.first, runaway.cpuPercent >= 180 {
            alerts.append(VitalsHealthAlert(
                id: "cpu-hot",
                severity: .warning,
                title: ZtatL10n.tr("\(runaway.name) 正在高负载占用 CPU", "\(runaway.name) High CPU Load"),
                detail: String(format: "%.0f%% CPU · PID %d", runaway.cpuPercent, runaway.id),
                targetPane: .cpu
            ))
        }
        let nonZtatAssertions = assertions.filter { !$0.processName.lowercased().contains("ztat") && $0.assertionType.contains("Sleep") }
        if !nonZtatAssertions.isEmpty, let first = nonZtatAssertions.first {
            alerts.append(VitalsHealthAlert(
                id: "sleep-assert",
                severity: .warning,
                title: ZtatL10n.tr("\(first.processName) 正在阻止 Mac 休眠", "\(first.processName) Preventing Sleep"),
                detail: nonZtatAssertions.count > 1
                    ? ZtatL10n.tr("共 \(nonZtatAssertions.count) 个防休眠断言活跃", "\(nonZtatAssertions.count) active sleep assertions")
                    : first.reason,
                targetPane: .battery
            ))
        }
        return alerts
    }

    // MARK: - Filtered & Sorted Process Queries

    private var currentUserName: String { NSUserName() }

    public var filteredProcesses: [VitalsProcessItem] {
        var list = applyScopeFilter(processes)
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !q.isEmpty {
            list = list.filter {
                $0.name.lowercased().contains(q) ||
                $0.path.lowercased().contains(q) ||
                String($0.id).contains(q) ||
                $0.user.lowercased().contains(q) ||
                $0.ports.contains(where: { String($0).contains(q) }) ||
                ($0.workingDir?.lowercased().contains(q) == true)
            }
        }
        list.sort(by: processSortComparator)
        return list
    }

    public var filteredAppGroups: [VitalsAppGroup] {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var groups = appGroups.compactMap { group -> VitalsAppGroup? in
            let scoped = applyScopeFilter(group.processes)
            guard !scoped.isEmpty else { return nil }
            if !q.isEmpty {
                let nameMatch = group.name.lowercased().contains(q)
                let matchingProcs = nameMatch ? scoped : scoped.filter {
                    $0.name.lowercased().contains(q) ||
                    String($0.id).contains(q) ||
                    $0.user.lowercased().contains(q) ||
                    $0.ports.contains(where: { String($0).contains(q) })
                }
                guard !matchingProcs.isEmpty else { return nil }
                return VitalsAppGroup(id: group.id, name: group.name, bundleURL: group.bundleURL, processes: matchingProcs.sorted(by: processSortComparator))
            }
            return VitalsAppGroup(id: group.id, name: group.name, bundleURL: group.bundleURL, processes: scoped.sorted(by: processSortComparator))
        }

        let asc = sortAscending
        groups.sort { a, b in
            switch sortColumn {
            case 0: return asc ? a.totalCPU < b.totalCPU : a.totalCPU > b.totalCPU
            case 1: return asc ? a.totalMemoryMB < b.totalMemoryMB : a.totalMemoryMB > b.totalMemoryMB
            case 2: return asc ? a.totalEnergyImpact < b.totalEnergyImpact : a.totalEnergyImpact > b.totalEnergyImpact
            case 3: return asc ? a.totalDiskWriteBytes < b.totalDiskWriteBytes : a.totalDiskWriteBytes > b.totalDiskWriteBytes
            case 4: return asc ? a.totalDiskReadBytes < b.totalDiskReadBytes : a.totalDiskReadBytes > b.totalDiskReadBytes
            case 5: return asc ? a.totalThreads < b.totalThreads : a.totalThreads > b.totalThreads
            case 6: return asc ? a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending : a.name.localizedCaseInsensitiveCompare(b.name) == .orderedDescending
            case 7: return asc ? (a.primaryProcess?.id ?? 0) < (b.primaryProcess?.id ?? 0) : (a.primaryProcess?.id ?? 0) > (b.primaryProcess?.id ?? 0)
            case 8:
                let at = a.processes.reduce(0) { $0 + $1.cpuTimeSeconds }
                let bt = b.processes.reduce(0) { $0 + $1.cpuTimeSeconds }
                return asc ? at < bt : at > bt
            default: return a.totalCPU > b.totalCPU
            }
        }
        return groups
    }

    public var filteredHierarchyRows: [VitalsProcessTreeRow] {
        VitalsProcessEngine.buildHierarchyTree(from: filteredProcesses, sortComparator: processSortComparator)
    }

    private func applyScopeFilter(_ list: [VitalsProcessItem]) -> [VitalsProcessItem] {
        switch processScope {
        case 1: return list.filter { $0.user == currentUserName }
        case 2: return list.filter(\.isUserApp)
        case 3: return list.filter(\.isSystemProcess)
        case 4: return list.filter { $0.cpuPercent > 0.1 }
        case 5: return list.filter { !$0.ports.isEmpty || $0.workingDir != nil }
        case 6:
            let agentPIDs = Set(agentSessions.map(\.pid))
            return list.filter { agentPIDs.contains($0.id) }
        default: return list
        }
    }

    private func processSortComparator(_ a: VitalsProcessItem, _ b: VitalsProcessItem) -> Bool {
        let asc = sortAscending
        switch sortColumn {
        case 0: return asc ? a.cpuPercent < b.cpuPercent : a.cpuPercent > b.cpuPercent
        case 1: return asc ? a.memoryMB < b.memoryMB : a.memoryMB > b.memoryMB
        case 2: return asc ? a.energyImpact < b.energyImpact : a.energyImpact > b.energyImpact
        case 3: return asc ? a.diskWriteBytes < b.diskWriteBytes : a.diskWriteBytes > b.diskWriteBytes
        case 4: return asc ? a.diskReadBytes < b.diskReadBytes : a.diskReadBytes > b.diskReadBytes
        case 5: return asc ? a.threads < b.threads : a.threads > b.threads
        case 6: return asc ? a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending : a.name.localizedCaseInsensitiveCompare(b.name) == .orderedDescending
        case 7: return asc ? a.id < b.id : a.id > b.id
        case 8: return asc ? a.cpuTimeSeconds < b.cpuTimeSeconds : a.cpuTimeSeconds > b.cpuTimeSeconds
        default: return a.cpuPercent > b.cpuPercent
        }
    }

    // MARK: - On-Demand Deep Inspection & Disk Holders

    public func loadDeepDetails(for pid: Int32, preserveSampleOutput: Bool = false) {
        deepDetailsRequestID &+= 1
        let reqID = deepDetailsRequestID
        isLoadingDeepDetails = true
        deepDetails = nil
        if !preserveSampleOutput {
            sampleOutput = ""
        }
        let snapshot = processes
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let details = VitalsProcessEngine.inspectProcessDeep(pid: pid, allProcesses: snapshot)
            DispatchQueue.main.async {
                guard let self, self.deepDetailsRequestID == reqID else { return }
                self.deepDetails = details
                self.isLoadingDeepDetails = false
            }
        }
    }

    public func runCallStackSample(for pid: Int32) {
        sampleRequestID &+= 1
        let reqID = sampleRequestID
        isSamplingCallStack = true
        sampleOutput = ZtatL10n.tr("正在采样进程 \(pid) 的实时调用栈（1 秒）…", "Sampling call stack for PID \(pid) (1s)…")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let out = VitalsProcessEngine.sampleCallStack(pid: pid, durationSeconds: 1)
            DispatchQueue.main.async {
                guard let self, self.sampleRequestID == reqID else { return }
                self.sampleOutput = out
                self.isSamplingCallStack = false
            }
        }
    }

    public func scanDiskHolders(for volume: VitalsDiskVolume) {
        guard !isScanningDiskHolders else { return }
        isScanningDiskHolders = true
        diskHoldersTarget = volume.name
        diskHolders = []
        let path = volume.mountPath
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let items = VitalsProcessEngine.findDiskHolders(mountPath: path)
            DispatchQueue.main.async {
                guard let self else { return }
                self.diskHolders = items
                self.isScanningDiskHolders = false
            }
        }
    }

    // MARK: - Process, Volume, Audio & Container Actions

    /// CRITICAL: POSIX `kill(0, sig)` delivers `sig` to the entire caller process group (killing/freezing ztat!).
    /// Never allow sending signals to PID <= 0 or our own PID.
    private func isSafeTargetPID(_ pid: Int32) -> Bool {
        pid > 0 && pid != getpid()
    }

    private func scheduleActiveRefresh(after delay: TimeInterval, forceSlowScans: Bool) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.activeConsumers.isEmpty else { return }
            self.refresh(forceSlowScans: forceSlowScans)
        }
    }

    public func togglePauseProcess(_ item: VitalsProcessItem) {
        guard isSafeTargetPID(item.id) else {
            flashFeedback(ZtatL10n.tr("禁止对内核或 ztat 自身发送暂停信号", "Cannot pause kernel_task or ztat itself"))
            return
        }
        let sig: Int32 = item.isPaused ? SIGCONT : SIGSTOP
        let res = kill(item.id, sig)
        flashFeedback(res == 0
            ? (item.isPaused ? ZtatL10n.tr("已恢复 \(item.name)", "Resumed \(item.name)") : ZtatL10n.tr("已暂停 \(item.name)", "Paused \(item.name)"))
            : ZtatL10n.tr("操作被拒绝（需要更高权限）", "Permission denied for PID \(item.id)"))
        scheduleActiveRefresh(after: 0.25, forceSlowScans: false)
    }

    public func terminateProcess(_ item: VitalsProcessItem, force: Bool = false) {
        guard isSafeTargetPID(item.id) else {
            flashFeedback(ZtatL10n.tr("禁止终止内核进程或 ztat 自身", "Cannot terminate kernel_task or ztat itself"))
            return
        }
        if force {
            let res = kill(item.id, SIGKILL)
            flashFeedback(res == 0
                ? ZtatL10n.tr("已强制终止 \(item.name) (PID \(item.id))", "Force quit \(item.name) (PID \(item.id))")
                : ZtatL10n.tr("无法强制终止 PID \(item.id)（系统/root 受保护）", "Cannot kill PID \(item.id) (protected)"))
        } else {
            if let app = NSRunningApplication(processIdentifier: item.id) {
                app.terminate()
                flashFeedback(ZtatL10n.tr("已请求优雅退出 \(item.name)", "Sent quit request to \(item.name)"))
            } else {
                let res = kill(item.id, SIGTERM)
                flashFeedback(res == 0
                    ? ZtatL10n.tr("已发送 SIGTERM 至 \(item.name)", "Sent SIGTERM to \(item.name)")
                    : ZtatL10n.tr("操作被拒绝（系统/root 受保护）", "Permission denied for PID \(item.id)"))
            }
        }
        scheduleActiveRefresh(after: 0.35, forceSlowScans: true)
    }

    public func terminateAppGroup(_ group: VitalsAppGroup, force: Bool = false) {
        let safeProcs = group.processes.filter { isSafeTargetPID($0.id) }
        guard !safeProcs.isEmpty else {
            flashFeedback(ZtatL10n.tr("禁止终止内核或 ztat 自身进程组", "Cannot terminate kernel_task or ztat itself"))
            return
        }
        for proc in safeProcs {
            if force {
                _ = kill(proc.id, SIGKILL)
            } else if let app = NSRunningApplication(processIdentifier: proc.id) {
                app.terminate()
            } else {
                _ = kill(proc.id, SIGTERM)
            }
        }
        flashFeedback(force
            ? ZtatL10n.tr("已强制退出应用组 \(group.name)", "Force quit \(group.name)")
            : ZtatL10n.tr("已退出应用组 \(group.name)", "Quit \(group.name)"))
        scheduleActiveRefresh(after: 0.4, forceSlowScans: true)
    }

    public func sendSignal(_ signal: VitalsUnixSignal, to item: VitalsProcessItem) {
        guard isSafeTargetPID(item.id) else {
            flashFeedback(ZtatL10n.tr("禁止向内核或 ztat 自身发送信号", "Cannot signal kernel_task or ztat itself"))
            return
        }
        let res = kill(item.id, signal.rawValue)
        flashFeedback(res == 0
            ? ZtatL10n.tr("已向 \(item.name) 发送 \(signal.label)", "Sent \(signal.label) to \(item.name)")
            : ZtatL10n.tr("发送信号失败（需要更高权限）", "Signal refused (permission denied)"))
        scheduleActiveRefresh(after: 0.3, forceSlowScans: false)
    }

    public func terminatePID(_ pid: Int32, force: Bool = false) {
        guard isSafeTargetPID(pid) else {
            flashFeedback(ZtatL10n.tr("禁止终止内核或 ztat 自身", "Cannot terminate kernel_task or ztat itself"))
            return
        }
        if let proc = processes.first(where: { $0.id == pid }) {
            terminateProcess(proc, force: force)
        } else {
            _ = kill(pid, force ? SIGKILL : SIGTERM)
            scheduleActiveRefresh(after: 0.35, forceSlowScans: true)
        }
    }

    public func revealInFinder(_ item: VitalsProcessItem) {
        if let url = item.bundleURL ?? (item.path.hasPrefix("/") ? URL(fileURLWithPath: item.path) : nil) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    public func revealPathInFinder(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    public func openLocalPort(_ port: UInt16) {
        if let url = URL(string: "http://localhost:\(port)") {
            NSWorkspace.shared.open(url)
        }
    }

    public func ejectVolume(_ volume: VitalsDiskVolume) {
        let url = URL(fileURLWithPath: volume.mountPath)
        do {
            try NSWorkspace.shared.unmountAndEjectDevice(at: url)
            flashFeedback(ZtatL10n.tr("已安全推出 \(volume.name)", "Ejected \(volume.name)"))
            scheduleActiveRefresh(after: 0.5, forceSlowScans: true)
        } catch {
            flashFeedback(ZtatL10n.tr("推出 \(volume.name) 失败，正在扫描占用进程…", "Could not eject \(volume.name), scanning open files…"))
            scanDiskHolders(for: volume)
        }
    }

    public func setSystemVolume(_ volume: Float) {
        hardware.systemVolume = volume
        if var audio = cachedAudio {
            audio.vol = volume
            cachedAudio = audio
        }
        audioWriteQueue.async {
            VitalsHardwareCollector.setSystemVolume(volume)
        }
    }

    public func toggleSystemMute() {
        let next = !hardware.isSystemMuted
        hardware.isSystemMuted = next
        if var audio = cachedAudio {
            audio.muted = next
            cachedAudio = audio
        }
        audioWriteQueue.async {
            VitalsHardwareCollector.setSystemMuted(next)
        }
    }

    public func selectOutputAudioDevice(_ deviceID: AudioDeviceID) {
        audioWriteQueue.async {
            VitalsHardwareCollector.setDefaultOutputDevice(deviceID)
        }
        scheduleActiveRefresh(after: 0.15, forceSlowScans: true)
    }

    public func controlContainer(_ container: VitalsContainerItem, action: String) {
        let cid = container.id
        let name = container.name
        flashFeedback(ZtatL10n.tr("正在对容器 \(name) 执行 \(action)…", "Running \(action) on \(name)…"))
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            VitalsAuxiliaryScanner.controlContainer(id: cid, action: action)
            DispatchQueue.main.async {
                guard let self, !self.activeConsumers.isEmpty else { return }
                self.refresh(forceSlowScans: true)
            }
        }
    }

    public func copyText(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        flashFeedback(ZtatL10n.tr("已复制到剪贴板", "Copied to clipboard"))
    }

    public func toggleGroupExpanded(_ id: String) {
        if expandedGroupIDs.contains(id) {
            expandedGroupIDs.remove(id)
        } else {
            expandedGroupIDs.insert(id)
        }
    }

    private static func csvField(_ raw: String) -> String {
        let cleaned = raw
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(cleaned)\""
    }

    public func exportProcessesCSV() {
        let panel = NSSavePanel()
        panel.title = ZtatL10n.tr("导出进程快照 (CSV)", "Export Process Snapshot (CSV)")
        panel.nameFieldStringValue = "ztat-processes.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }

        var lines = ["PID,PPID,Name,User,Arch,State,CPU%,FootprintMB,RSSMB,VirtualMB,Threads,CPUTimeSec,DiskReadBytes,DiskWriteBytes,EnergyImpact,WakeupsPerSec,Ports,Path"]
        for p in filteredProcesses {
            let portsStr = p.ports.map(String.init).joined(separator: ";")
            lines.append([
                "\(p.id)",
                "\(p.ppid)",
                Self.csvField(p.name),
                Self.csvField(p.user),
                Self.csvField(p.architecture),
                Self.csvField(p.stateLabel),
                String(format: "%.2f", p.cpuPercent),
                String(format: "%.2f", p.memoryMB),
                String(format: "%.2f", p.rssMB),
                String(format: "%.2f", p.virtualMemoryMB),
                "\(p.threads)",
                String(format: "%.2f", p.cpuTimeSeconds),
                "\(p.diskReadBytes)",
                "\(p.diskWriteBytes)",
                String(format: "%.2f", p.energyImpact),
                String(format: "%.1f", p.idleWakeupsPerSec),
                Self.csvField(portsStr),
                Self.csvField(p.path)
            ].joined(separator: ","))
        }
        do {
            try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
            flashFeedback(ZtatL10n.tr("已导出 CSV 至 \(url.lastPathComponent)", "Exported CSV to \(url.lastPathComponent)"))
        } catch {
            flashFeedback(ZtatL10n.tr("导出 CSV 失败：\(error.localizedDescription)", "CSV export failed: \(error.localizedDescription)"))
        }
    }

    public var uptimeFormatted: String {
        let total = Int(hardware.uptimeSeconds)
        let days = total / 86400
        let hours = (total % 86400) / 3600
        let mins = (total % 3600) / 60
        if days > 0 { return "\(days)d \(hours)h \(mins)m" }
        if hours > 0 { return "\(hours)h \(mins)m" }
        return "\(mins)m"
    }

    private func flashFeedback(_ message: String) {
        actionFeedback = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.8) { [weak self] in
            if self?.actionFeedback == message {
                self?.actionFeedback = nil
            }
        }
    }
}
