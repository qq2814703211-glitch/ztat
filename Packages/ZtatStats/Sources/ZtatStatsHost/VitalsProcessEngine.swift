// SPDX-License-Identifier: GPL-3.0-or-later
// ZTAT-PATCH: Real Native Mach/libproc Process Engine, App Grouper, Process Tree,
// Port & AI Agent Scanner, and On-Demand Deep Inspector (Activity Monitor + Vitals parity).

import AppKit
import CStatsHardware
import Darwin
import Foundation
import Security
import ZtatCore

// MARK: - Process & Developer Models

public struct VitalsProcessItem: Identifiable, Sendable {
    public let id: Int32
    public let ppid: Int32
    public let uid: UInt32
    public let name: String
    public let path: String
    public let user: String
    public let cpuPercent: Double
    public let memoryMB: Double        // Physical Footprint (matches Activity Monitor Memory column!)
    public let rssMB: Double           // Resident Set Size
    public let virtualMemoryMB: Double
    public let threads: Int
    public let cpuTimeSeconds: Double
    public let diskReadBytes: UInt64
    public let diskWriteBytes: UInt64
    public let diskReadRateBps: Double
    public let diskWriteRateBps: Double
    public let idleWakeups: UInt64
    public let idleWakeupsPerSec: Double
    public let energyImpact: Double
    public let isUserApp: Bool
    public let isSystemProcess: Bool
    public let bundleURL: URL?
    public let bundleIdentifier: String?
    public var ports: [UInt16]
    public let isPaused: Bool
    public let stateLabel: String
    public let architecture: String    // "Apple" / "Intel"
    public let startTime: Date?
    public let workingDir: String?
    public var preventingSleep: Bool
}

public struct VitalsAppGroup: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let bundleURL: URL?
    public var processes: [VitalsProcessItem]

    public var totalCPU: Double { processes.reduce(0) { $0 + $1.cpuPercent } }
    public var totalMemoryMB: Double { processes.reduce(0) { $0 + $1.memoryMB } }
    public var totalRSSMB: Double { processes.reduce(0) { $0 + $1.rssMB } }
    public var totalThreads: Int { processes.reduce(0) { $0 + $1.threads } }
    public var totalDiskReadBytes: UInt64 { processes.reduce(0) { $0 &+ $1.diskReadBytes } }
    public var totalDiskWriteBytes: UInt64 { processes.reduce(0) { $0 &+ $1.diskWriteBytes } }
    public var totalDiskReadRateBps: Double { processes.reduce(0) { $0 + $1.diskReadRateBps } }
    public var totalDiskWriteRateBps: Double { processes.reduce(0) { $0 + $1.diskWriteRateBps } }
    public var totalEnergyImpact: Double { processes.reduce(0) { $0 + $1.energyImpact } }
    public var totalIdleWakeups: UInt64 { processes.reduce(0) { $0 &+ $1.idleWakeups } }
    public var totalIdleWakeupsPerSec: Double { processes.reduce(0) { $0 + $1.idleWakeupsPerSec } }
    public var processCount: Int { processes.count }
    public var ports: [UInt16] { Array(Set(processes.flatMap(\.ports))).sorted() }
    public var preventingSleep: Bool { processes.contains(where: \.preventingSleep) }
    public var primaryProcess: VitalsProcessItem? {
        // Stable primary selection: prefer direct NSRunningApplication (bundleIdentifier != nil),
        // then main bundle binary under <bundle>/Contents/MacOS/, breaking ties deterministically by lowest PID.
        let runningApps = processes.filter { $0.bundleIdentifier != nil }
        if let appMain = runningApps.min(by: { $0.id < $1.id }) {
            return appMain
        }
        if let bundlePath = bundleURL?.path {
            let macOSPrefix = bundlePath + "/Contents/MacOS/"
            let directBins = processes.filter { $0.path.hasPrefix(macOSPrefix) }
            if let binMain = directBins.min(by: { $0.id < $1.id }) {
                return binMain
            }
        }
        return processes.min(by: { a, b in
            if a.ppid != b.ppid { return a.ppid < b.ppid }
            return a.id < b.id
        })
    }
}

public struct VitalsProcessTreeRow: Identifiable, Sendable {
    public var id: Int32 { process.id }
    public let process: VitalsProcessItem
    public let depth: Int
    public let childCount: Int
}

public struct VitalsPortItem: Identifiable, Sendable {
    public enum PortCategory: String, Sendable {
        case devServer = "Dev"
        case database = "DB"
        case agent = "AI"
        case system = "System"
        case other = "Port"
    }

    public let id: String
    public let pid: Int32
    public let processName: String
    public let port: UInt16
    public let address: String
    public let protocolName: String
    public let category: PortCategory
    public let isNetworkExposed: Bool
    public let workingDir: String?
}

public struct VitalsAgentSession: Identifiable, Sendable {
    public let id: String
    public let pid: Int32
    public let name: String
    public let executable: String
    public let cpuPercent: Double
    public let memoryMB: Double
    public let activePorts: [UInt16]
    public let workingDir: String?
    public let isIdle: Bool
}

public struct VitalsDevProject: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let path: String
    public let pids: [Int32]
    public let ports: [UInt16]
    public let totalCPU: Double
    public let totalMemoryMB: Double
}

public struct VitalsOpenFileEntry: Identifiable, Sendable {
    public let id: String
    public let fd: String
    public let type: String
    public let name: String
}

public struct VitalsProcessDeepDetails: Sendable {
    public let pid: Int32
    public let commandLine: String
    public let environment: [(key: String, value: String)]
    public let workingDir: String?
    public let signingIdentifier: String?
    public let teamIdentifier: String?
    public let authority: String?
    public let isHardenedRuntime: Bool
    public let isSandboxed: Bool
    public let openFiles: [VitalsOpenFileEntry]
    public let networkSockets: [VitalsOpenFileEntry]
    public let parentName: String?
    public let children: [(pid: Int32, name: String)]
}

public struct VitalsDiskHolderItem: Identifiable, Sendable {
    public let id: String
    public let pid: Int32
    public let processName: String
    public let path: String
    public let mode: String
}

public struct VitalsProcessSnapshot: Sendable {
    public let processes: [VitalsProcessItem]
    public let appGroups: [VitalsAppGroup]
    public let listeningPorts: [VitalsPortItem]
    public let agentSessions: [VitalsAgentSession]
    public let devProjects: [VitalsDevProject]
    public let totalThreadCount: Int
}

// MARK: - Native Process Engine

internal final class VitalsProcessEngine {
    // Mach timebase factor to convert mach absolute time -> nanoseconds
    private let timebaseNumer: UInt64
    private let timebaseDenom: UInt64
    private let currentUID: UInt32 = getuid()

    // Previous samples for exact CPU% and Disk R/W rate deltas
    private struct PrevSample {
        let cpuNanos: UInt64
        let diskRead: UInt64
        let diskWrite: UInt64
        let wakeups: UInt64
        let startTimeSec: Int64
        let timestamp: TimeInterval
    }
    private var prevSamples: [Int32: PrevSample] = [:]
    private var userNameCache: [UInt32: String] = [:]

    private static let kProcFlagTranslated: Int32 = 0x0002_0000 // P_TRANSLATED in <sys/proc.h>
    private static let kProcStatRun: UInt32 = 2
    private static let kProcStatSleep: UInt32 = 3
    private static let kProcStatStop: UInt32 = 4
    private static let kProcStatZombie: UInt32 = 5

    init() {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        self.timebaseNumer = UInt64(max(1, tb.numer))
        self.timebaseDenom = UInt64(max(1, tb.denom))
    }

    private func machToNanos(_ ticks: UInt64) -> UInt64 {
        if timebaseNumer == timebaseDenom { return ticks }
        let (q, r) = ticks.quotientAndRemainder(dividingBy: timebaseDenom)
        return q &* timebaseNumer &+ (r &* timebaseNumer) / timebaseDenom
    }

    private func userName(for uid: UInt32) -> String {
        if let cached = userNameCache[uid] { return cached }
        if uid == 0 {
            userNameCache[0] = "root"
            return "root"
        }
        var pwd = passwd()
        var result: UnsafeMutablePointer<passwd>?
        var buf = [CChar](repeating: 0, count: 1024)
        if getpwuid_r(uid, &pwd, &buf, buf.count, &result) == 0,
           let res = result, let cstr = res.pointee.pw_name {
            let name = String(cString: cstr)
            userNameCache[uid] = name
            return name
        }
        let fallback = "_\(uid)"
        userNameCache[uid] = fallback
        return fallback
    }

    func resetBaselines() {
        prevSamples.removeAll()
    }

    /// Samples every running process using native `libproc` (`proc_listpids`, `proc_pidinfo`,
    /// `proc_pid_rusage`, `sysctl KERN_PROC_PID`) with a lightweight `ps` supplement ONLY for
    /// root/privileged processes whose `proc_pidinfo` returns EPERM.
    func sample(
        ports: [VitalsPortItem],
        sleepAssertionPIDs: Set<Int32>,
        runningAppsSnapshot: [Int32: (name: String, bundleURL: URL?, bundleID: String?)]
    ) -> VitalsProcessSnapshot {
        let now = ProcessInfo.processInfo.systemUptime

        // 1. Lightweight ps table for root/system processes (and fallback CPU/RSS/threads/time)
        let psFallback = readLightweightPSTable()

        // 2. Native proc_listpids (deduplicated against XNU concurrent fork/exit duplicates)
        let rawCount = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        var pids: [Int32] = []
        var pidSet = Set<Int32>()
        if rawCount > 0 {
            let capacity = Int(rawCount) / MemoryLayout<pid_t>.size + 64
            var buf = [pid_t](repeating: 0, count: capacity)
            let bytesReturned = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &buf, Int32(capacity * MemoryLayout<pid_t>.size))
            if bytesReturned > 0 {
                let actual = Int(bytesReturned) / MemoryLayout<pid_t>.size
                pids.reserveCapacity(actual)
                for p in buf.prefix(actual) where p > 0 {
                    if pidSet.insert(p).inserted {
                        pids.append(p)
                    }
                }
            }
        }
        // Merge any PIDs visible in ps but missing from proc_listpids (e.g. PID 0 kernel_task)
        for pid in psFallback.keys where pid >= 0 {
            if pidSet.insert(pid).inserted {
                pids.append(pid)
            }
        }

        var portMap: [Int32: [UInt16]] = [:]
        var portCwdMap: [Int32: String] = [:]
        for p in ports {
            portMap[p.pid, default: []].append(p.port)
            if let cwd = p.workingDir { portCwdMap[p.pid] = cwd }
        }

        var nextPrev: [Int32: PrevSample] = [:]
        nextPrev.reserveCapacity(pids.count)

        var items: [VitalsProcessItem] = []
        items.reserveCapacity(pids.count)
        var agents: [VitalsAgentSession] = []

        for pid in pids {
            let psRow = psFallback[pid]
            let appInfo = runningAppsSnapshot[pid]

            // Try native libproc PROC_PIDTASKALLINFO
            var taskAll = proc_taskallinfo()
            let taskAllSize = Int32(MemoryLayout<proc_taskallinfo>.size)
            let gotTaskAll = pid > 0 && proc_pidinfo(pid, PROC_PIDTASKALLINFO, 0, &taskAll, taskAllSize) == taskAllSize

            // Try native proc_pid_rusage (RUSAGE_INFO_V4) via safe C inline wrapper (zero pointer-rebinding UB)
            var rusage = rusage_info_v4()
            let gotRusage: Bool = pid > 0 && ztat_proc_pid_rusage_v4(pid, &rusage) == 0

            // Per-PID sysctl KERN_PROC_PID for exact architecture (P_TRANSLATED), state, start time, uid, ppid
            var kinfo = kinfo_proc()
            var kinfoSize = MemoryLayout<kinfo_proc>.size
            var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
            let gotKinfo = sysctl(&mib, 4, &kinfo, &kinfoSize, nil, 0) == 0 && kinfoSize > 0

            guard gotTaskAll || gotRusage || gotKinfo || psRow != nil else { continue }

            // Executable path via proc_pidpath (PROC_PIDPATHINFO_MAXSIZE = 4 * MAXPATHLEN = 4096)
            var pathBuf = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
            let pathLen = pid > 0 ? proc_pidpath(pid, &pathBuf, UInt32(pathBuf.count)) : 0
            let fullPath: String
            if pathLen > 0 {
                fullPath = String(cString: pathBuf)
            } else if let psComm = psRow?.comm, !psComm.isEmpty {
                fullPath = psComm
            } else if let bPath = appInfo?.bundleURL?.path {
                fullPath = bPath
            } else {
                fullPath = pid == 0 ? "kernel_task" : "pid_\(pid)"
            }

            let ppid: Int32
            if gotTaskAll {
                ppid = Int32(taskAll.pbsd.pbi_ppid)
            } else if gotKinfo {
                ppid = kinfo.kp_eproc.e_ppid
            } else {
                ppid = psRow?.ppid ?? 0
            }

            let uid: UInt32
            if gotTaskAll {
                uid = taskAll.pbsd.pbi_uid
            } else if gotKinfo {
                uid = kinfo.kp_eproc.e_ucred.cr_uid
            } else {
                uid = psRow?.user == "root" ? 0 : currentUID
            }
            let user = psRow?.user.isEmpty == false ? psRow!.user : userName(for: uid)

            // Exact per-PID architecture!
            let arch: String
            #if arch(arm64)
            if gotKinfo {
                arch = (kinfo.kp_proc.p_flag & Self.kProcFlagTranslated) != 0 ? "Intel" : "Apple"
            } else {
                arch = "Apple"
            }
            #else
            arch = "Intel"
            #endif

            // Exact process status (on macOS pbi_status==SRUN for almost all sleeping tasks; check pti_numrunning > 0!)
            let rawStat: UInt32 = gotTaskAll ? taskAll.pbsd.pbi_status : (gotKinfo ? UInt32(kinfo.kp_proc.p_stat) : 0)
            let isPaused: Bool = (rawStat == Self.kProcStatStop) || (psRow?.state.contains("T") == true)
            let isZombie: Bool = (rawStat == Self.kProcStatZombie) || (psRow?.state.contains("Z") == true)
            let isActivelyRunning: Bool = gotTaskAll
                ? (taskAll.ptinfo.pti_numrunning > 0)
                : (psRow?.state.hasPrefix("R") == true)
            let stateLabel: String
            if isPaused {
                stateLabel = ZtatL10n.tr("已暂停", "Paused")
            } else if isZombie {
                stateLabel = ZtatL10n.tr("僵尸", "Zombie")
            } else if isActivelyRunning {
                stateLabel = ZtatL10n.tr("运行中", "Running")
            } else {
                stateLabel = ZtatL10n.tr("休眠", "Sleeping")
            }

            // Start time
            let startTimeSec: Int64
            let startTime: Date?
            if gotTaskAll, taskAll.pbsd.pbi_start_tvsec > 0 {
                startTimeSec = Int64(taskAll.pbsd.pbi_start_tvsec)
                startTime = Date(timeIntervalSince1970: TimeInterval(startTimeSec))
            } else if gotKinfo, kinfo.kp_proc.p_starttime.tv_sec > 0 {
                startTimeSec = Int64(kinfo.kp_proc.p_starttime.tv_sec)
                startTime = Date(timeIntervalSince1970: TimeInterval(startTimeSec))
            } else {
                startTimeSec = 0
                startTime = nil
            }

            // CPU Time, CPU %, Threads, Memory (Footprint + RSS + Virtual), Disk I/O, Energy
            var cpuNanos: UInt64 = 0
            var cpuTimeSeconds: Double = psRow?.cpuTimeSeconds ?? 0
            var cpuPercent: Double = psRow?.cpuPercent ?? 0
            var threads: Int = 1
            var rssMB: Double = (psRow?.rssKB ?? 0) / 1024.0
            var virtualMB: Double = (psRow?.vszKB ?? 0) / 1024.0
            var footprintMB: Double = rssMB
            var diskReadBytes: UInt64 = 0
            var diskWriteBytes: UInt64 = 0
            var diskReadRateBps: Double = 0
            var diskWriteRateBps: Double = 0
            var idleWakeups: UInt64 = 0
            var wakeupsPerSec: Double = 0

            if gotTaskAll {
                cpuNanos = machToNanos(taskAll.ptinfo.pti_total_user &+ taskAll.ptinfo.pti_total_system)
                cpuTimeSeconds = Double(cpuNanos) / 1_000_000_000.0
                threads = max(1, Int(taskAll.ptinfo.pti_threadnum))
                rssMB = Double(taskAll.ptinfo.pti_resident_size) / 1_048_576.0
                virtualMB = Double(taskAll.ptinfo.pti_virtual_size) / 1_048_576.0
                footprintMB = rssMB
            }

            if gotRusage {
                let fp = Double(rusage.ri_phys_footprint) / 1_048_576.0
                if fp > 0 { footprintMB = fp }
                if cpuNanos == 0 {
                    cpuNanos = machToNanos(rusage.ri_user_time &+ rusage.ri_system_time)
                    cpuTimeSeconds = Double(cpuNanos) / 1_000_000_000.0
                }
                diskReadBytes = rusage.ri_diskio_bytesread
                diskWriteBytes = rusage.ri_diskio_byteswritten
                idleWakeups = rusage.ri_pkg_idle_wkups
            }

            if cpuNanos > 0 {
                if let prev = prevSamples[pid], now > prev.timestamp,
                   (startTimeSec == 0 || prev.startTimeSec == 0 || startTimeSec == prev.startTimeSec) {
                    let dt = now - prev.timestamp
                    if cpuNanos >= prev.cpuNanos {
                        let dCpuSec = Double(cpuNanos - prev.cpuNanos) / 1_000_000_000.0
                        cpuPercent = min(Double(ProcessInfo.processInfo.processorCount) * 100.0, max(0, (dCpuSec / dt) * 100.0))
                    }
                    if diskReadBytes >= prev.diskRead {
                        diskReadRateBps = Double(diskReadBytes - prev.diskRead) / dt
                    }
                    if diskWriteBytes >= prev.diskWrite {
                        diskWriteRateBps = Double(diskWriteBytes - prev.diskWrite) / dt
                    }
                    if idleWakeups >= prev.wakeups {
                        wakeupsPerSec = Double(idleWakeups - prev.wakeups) / dt
                    }
                }
                nextPrev[pid] = PrevSample(
                    cpuNanos: cpuNanos,
                    diskRead: diskReadBytes,
                    diskWrite: diskWriteBytes,
                    wakeups: idleWakeups,
                    startTimeSec: startTimeSec,
                    timestamp: now
                )
            }

            // Realistic Energy Impact model (weighted CPU% + idle wakeups/s + disk I/O MB/s, matching Activity Monitor scale)
            let diskMBs = (diskReadRateBps + diskWriteRateBps) / 1_048_576.0
            let energyImpact = max(0, cpuPercent + wakeupsPerSec * 0.08 + diskMBs * 1.5)

            // Resolve display name & bundle URL
            let inferredBundleURL = appInfo?.bundleURL ?? Self.extractAppBundleURL(from: fullPath)
            let displayName: String
            if let appName = appInfo?.name, !appName.isEmpty {
                displayName = appName
            } else {
                let last = (fullPath as NSString).lastPathComponent
                displayName = last.isEmpty ? (psRow?.comm ?? "pid_\(pid)") : last
            }

            let isUserApp = appInfo != nil || inferredBundleURL != nil
            let isSystem = uid == 0 || uid < 500 || fullPath.hasPrefix("/System/") || fullPath.hasPrefix("/usr/libexec/") || fullPath.hasPrefix("/sbin/")
            let activePorts = portMap[pid] ?? []

            // Working dir (fast native PROC_PIDVNODEPATHINFO only for dev/port/agent processes to keep latency tiny)
            var cwd = portCwdMap[pid]
            let lowerPath = fullPath.lowercased()
            let lowerName = displayName.lowercased()
            let isAgentCandidate = Self.detectAgentLabel(lowerName: lowerName, lowerPath: lowerPath) != nil
            let isDevCandidate = !activePorts.isEmpty || isAgentCandidate ||
                lowerName == "node" || lowerName == "python3" || lowerName == "bun" || lowerName == "deno" || lowerName == "go" || lowerName == "cargo" || lowerName == "ruby" || lowerName == "java" || lowerName == "vite"
            if cwd == nil && isDevCandidate && uid == currentUID {
                cwd = Self.readWorkingDirectory(pid: pid)
            }

            let item = VitalsProcessItem(
                id: pid,
                ppid: ppid,
                uid: uid,
                name: displayName,
                path: fullPath,
                user: user,
                cpuPercent: cpuPercent,
                memoryMB: footprintMB,
                rssMB: rssMB,
                virtualMemoryMB: virtualMB,
                threads: threads,
                cpuTimeSeconds: cpuTimeSeconds,
                diskReadBytes: diskReadBytes,
                diskWriteBytes: diskWriteBytes,
                diskReadRateBps: diskReadRateBps,
                diskWriteRateBps: diskWriteRateBps,
                idleWakeups: idleWakeups,
                idleWakeupsPerSec: wakeupsPerSec,
                energyImpact: energyImpact,
                isUserApp: isUserApp,
                isSystemProcess: isSystem,
                bundleURL: inferredBundleURL,
                bundleIdentifier: appInfo?.bundleID,
                ports: activePorts,
                isPaused: isPaused,
                stateLabel: stateLabel,
                architecture: arch,
                startTime: startTime,
                workingDir: cwd,
                preventingSleep: sleepAssertionPIDs.contains(pid)
            )
            items.append(item)

            if let agentName = Self.detectAgentLabel(lowerName: lowerName, lowerPath: lowerPath) {
                agents.append(VitalsAgentSession(
                    id: "\(pid)",
                    pid: pid,
                    name: agentName,
                    executable: fullPath,
                    cpuPercent: cpuPercent,
                    memoryMB: footprintMB,
                    activePorts: activePorts,
                    workingDir: cwd,
                    isIdle: cpuPercent < 0.3 && diskReadRateBps < 1024 && diskWriteRateBps < 1024
                ))
            }
        }

        prevSamples = nextPrev
        items.sort { $0.cpuPercent > $1.cpuPercent }
        agents.sort { $0.cpuPercent > $1.cpuPercent }

        // Build App Groups (also walking parent chain so helpers launched by an App fold under their parent!)
        let byPID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var groupsDict: [String: VitalsAppGroup] = [:]
        for proc in items {
            let (groupKey, groupName, groupBundle) = Self.resolveAppGroup(for: proc, byPID: byPID)
            if var existing = groupsDict[groupKey] {
                existing.processes.append(proc)
                groupsDict[groupKey] = existing
            } else {
                groupsDict[groupKey] = VitalsAppGroup(
                    id: groupKey,
                    name: groupName,
                    bundleURL: groupBundle,
                    processes: [proc]
                )
            }
        }
        let appGroups = groupsDict.values.sorted { $0.totalCPU > $1.totalCPU }

        // Build Active Dev Projects from processes with real user project working directories
        let devProjects = Self.buildDevProjects(from: items)
        let totalThreads = items.reduce(0) { $0 + $1.threads }

        return VitalsProcessSnapshot(
            processes: items,
            appGroups: appGroups,
            listeningPorts: ports,
            agentSessions: agents,
            devProjects: devProjects,
            totalThreadCount: totalThreads
        )
    }

    // MARK: - Build Process Hierarchy Tree

    public static func buildHierarchyTree(
        from processes: [VitalsProcessItem],
        sortComparator: (VitalsProcessItem, VitalsProcessItem) -> Bool
    ) -> [VitalsProcessTreeRow] {
        let byPID = Dictionary(processes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var childrenMap: [Int32: [VitalsProcessItem]] = [:]
        var roots: [VitalsProcessItem] = []

        for p in processes {
            if p.ppid != p.id && byPID[p.ppid] != nil {
                childrenMap[p.ppid, default: []].append(p)
            } else {
                roots.append(p)
            }
        }

        roots.sort(by: sortComparator)
        var rows: [VitalsProcessTreeRow] = []
        rows.reserveCapacity(processes.count)
        var visited = Set<Int32>()

        func dfs(_ node: VitalsProcessItem, depth: Int) {
            guard visited.insert(node.id).inserted else { return }
            let kids = (childrenMap[node.id] ?? []).sorted(by: sortComparator)
            rows.append(VitalsProcessTreeRow(process: node, depth: depth, childCount: kids.count))
            for child in kids {
                dfs(child, depth: min(depth + 1, 10))
            }
        }

        for r in roots { dfs(r, depth: 0) }
        return rows
    }

    // MARK: - Port Scanner

    static func scanListeningPorts() -> [VitalsPortItem] {
        // Machine-readable -F pcnPt avoids 9-char command truncation & whitespace column shifting
        guard let output = VitalsAuxiliaryScanner.runCommand("/usr/sbin/lsof", args: ["-nP", "-iTCP", "-sTCP:LISTEN", "-F", "pcnt"], timeoutSeconds: 3.0) else {
            return []
        }

        struct RawPort {
            var pid: Int32
            var comm: String
            var port: UInt16
            var address: String
            var proto: String
            var isExposed: Bool
        }

        var mergedByID: [String: RawPort] = [:]
        var curPID: Int32 = 0
        var curComm = ""
        var curProto = "TCP"

        for rawLine in output.split(separator: "\n") {
            guard let tag = rawLine.first else { continue }
            let val = String(rawLine.dropFirst())
            switch tag {
            case "p":
                curPID = Int32(val) ?? 0
                curComm = ""
                curProto = "TCP"
            case "c":
                curComm = val
            case "t":
                curProto = val
            case "n":
                guard curPID > 0, let colonIdx = val.lastIndex(of: ":") else { continue }
                let portStr = String(val[val.index(after: colonIdx)...])
                let addr = String(val[..<colonIdx])
                guard let portNum = UInt16(portStr) else { continue }

                // Resolve untruncated process name via proc_pidpath when possible
                let fullName: String = {
                    var pbuf = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
                    if proc_pidpath(curPID, &pbuf, UInt32(pbuf.count)) > 0 {
                        let base = (String(cString: pbuf) as NSString).lastPathComponent
                        if !base.isEmpty { return base }
                    }
                    return curComm.isEmpty ? "pid_\(curPID)" : curComm
                }()

                let isLoopback = addr == "127.0.0.1" || addr == "[::1]" || addr == "::1" || addr.lowercased() == "localhost"
                let isExposed = !isLoopback
                let itemID = "\(curPID):\(portNum)"
                if var existing = mergedByID[itemID] {
                    if isExposed && !existing.isExposed {
                        existing.isExposed = true
                        existing.address = addr
                    }
                    mergedByID[itemID] = existing
                } else {
                    mergedByID[itemID] = RawPort(
                        pid: curPID,
                        comm: fullName,
                        port: portNum,
                        address: addr,
                        proto: curProto,
                        isExposed: isExposed
                    )
                }
            default:
                break
            }
        }

        var cwdCache: [Int32: String?] = [:]
        let results: [VitalsPortItem] = mergedByID.map { itemID, raw in
            let cwd: String?
            if let cached = cwdCache[raw.pid] {
                cwd = cached
            } else {
                let resolved = readWorkingDirectory(pid: raw.pid)
                cwdCache[raw.pid] = resolved
                cwd = resolved
            }
            return VitalsPortItem(
                id: itemID,
                pid: raw.pid,
                processName: raw.comm,
                port: raw.port,
                address: raw.address,
                protocolName: raw.proto,
                category: categorizePort(port: raw.port, comm: raw.comm),
                isNetworkExposed: raw.isExposed,
                workingDir: cwd
            )
        }

        return results.sorted {
            if $0.category == .devServer && $1.category != .devServer { return true }
            if $0.category != .devServer && $1.category == .devServer { return false }
            if $0.category == .agent && $1.category != .agent { return true }
            if $0.category != .agent && $1.category == .agent { return false }
            return $0.port < $1.port
        }
    }

    // MARK: - On-Demand Deep Process Inspector

    static func inspectProcessDeep(pid: Int32, allProcesses: [VitalsProcessItem]) -> VitalsProcessDeepDetails {
        let proc = allProcesses.first(where: { $0.id == pid })
        let parent = proc.flatMap { p in allProcesses.first(where: { $0.id == p.ppid }) }
        let children = allProcesses.filter { $0.ppid == pid && $0.id != pid }.map { ($0.id, $0.name) }
        let cwd = readWorkingDirectory(pid: pid)

        // 1 & 2. Native sysctl KERN_PROCARGS2 for exact argv + envp (zero subprocess, real env vars on macOS!)
        let (nativeArgs, nativeEnv) = Self.readProcessArgsAndEnv(pid: pid)
        let cmdLine: String
        if !nativeArgs.isEmpty {
            cmdLine = nativeArgs.joined(separator: " ")
        } else {
            cmdLine = VitalsAuxiliaryScanner.runCommand("/bin/ps", args: ["-ww", "-p", "\(pid)", "-o", "args="], timeoutSeconds: 1.5)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? proc?.path ?? ""
        }
        var envPairs = nativeEnv
        envPairs.sort { $0.0 < $1.0 }

        // 3. Code signature & security flags via Security.framework
        var signingID: String?
        var teamID: String?
        var authority: String?
        var hardenedRuntime = false
        var sandboxed = false

        var secCode: SecCode?
        let attrs = [kSecGuestAttributePid: NSNumber(value: pid)] as CFDictionary
        if SecCodeCopyGuestWithAttributes(nil, attrs, [], &secCode) == errSecSuccess, let secCode {
            var staticCode: SecStaticCode?
            if SecCodeCopyStaticCode(secCode, [], &staticCode) == errSecSuccess, let staticCode {
                var infoCF: CFDictionary?
                if SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &infoCF) == errSecSuccess,
                   let info = infoCF as? [String: Any] {
                    signingID = info[kSecCodeInfoIdentifier as String] as? String
                    teamID = info[kSecCodeInfoTeamIdentifier as String] as? String
                    if let flags = (info[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value {
                        hardenedRuntime = (flags & 0x10000) != 0 // kSecCodeSignatureRuntime
                    }
                    if let ent = info[kSecCodeInfoEntitlementsDict as String] as? [String: Any] {
                        sandboxed = (ent["com.apple.security.app-sandbox"] as? Bool) == true
                    }
                    if let certs = info[kSecCodeInfoCertificates as String] as? [SecCertificate], let leaf = certs.first {
                        var cn: CFString?
                        if SecCertificateCopyCommonName(leaf, &cn) == errSecSuccess, let cn {
                            authority = cn as String
                        }
                    }
                }
            }
        }

        // 4. Open files & network sockets via lsof -nP -Fftn -p <pid>
        var openFiles: [VitalsOpenFileEntry] = []
        var sockets: [VitalsOpenFileEntry] = []
        if let lsofOut = VitalsAuxiliaryScanner.runCommand("/usr/sbin/lsof", args: ["-nP", "-Fftn", "-p", "\(pid)"], timeoutSeconds: 2.5) {
            var curFD = ""
            var curType = ""
            var idx = 0
            for rawLine in lsofOut.split(separator: "\n") {
                guard let first = rawLine.first else { continue }
                let val = String(rawLine.dropFirst())
                switch first {
                case "f":
                    curFD = val
                    curType = ""
                case "t":
                    curType = val
                case "n":
                    idx += 1
                    let entry = VitalsOpenFileEntry(id: "\(pid):\(idx):\(curFD)", fd: curFD, type: curType, name: val)
                    if curType == "IPv4" || curType == "IPv6" || curType == "unix" {
                        if sockets.count < 200 { sockets.append(entry) }
                    } else {
                        if openFiles.count < 250 { openFiles.append(entry) }
                    }
                default: break
                }
            }
        }

        return VitalsProcessDeepDetails(
            pid: pid,
            commandLine: cmdLine,
            environment: envPairs,
            workingDir: cwd,
            signingIdentifier: signingID,
            teamIdentifier: teamID,
            authority: authority,
            isHardenedRuntime: hardenedRuntime,
            isSandboxed: sandboxed,
            openFiles: openFiles,
            networkSockets: sockets,
            parentName: parent?.name,
            children: children
        )
    }

    static func sampleCallStack(pid: Int32, durationSeconds: Int = 1) -> String {
        if let out = VitalsAuxiliaryScanner.runCommand("/usr/bin/sample", args: ["\(pid)", "\(durationSeconds)", "-mayDie"], timeoutSeconds: TimeInterval(durationSeconds + 4)) {
            return out
        }
        return ZtatL10n.tr(
            "无法采样该进程（可能属于 root/系统受保护进程，或进程已退出）。",
            "Unable to sample this process (it may be SIP/root-protected or has already exited)."
        )
    }

    static func findDiskHolders(mountPath: String) -> [VitalsDiskHolderItem] {
        guard mountPath != "/" else { return [] }
        guard let out = VitalsAuxiliaryScanner.runCommand("/usr/sbin/lsof", args: ["+f", "--", mountPath], timeoutSeconds: 3.0) else {
            return []
        }
        var results: [VitalsDiskHolderItem] = []
        var seen = Set<String>()
        for line in out.split(separator: "\n").dropFirst() {
            let parts = line.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: true)
            guard parts.count >= 9, let pid = Int32(parts[1]) else { continue }
            let name = String(parts[0]).replacingOccurrences(of: "\\x20", with: " ")
            let fd = String(parts[3])
            let path = String(parts[8])
            let key = "\(pid):\(path)"
            guard seen.insert(key).inserted else { continue }
            results.append(VitalsDiskHolderItem(id: key, pid: pid, processName: name, path: path, mode: fd))
        }
        return results
    }

    // MARK: - Internal Helpers

    private struct PSRow {
        let ppid: Int32
        let cpuPercent: Double
        let rssKB: Double
        let vszKB: Double
        let cpuTimeSeconds: Double
        let state: String
        let user: String
        let comm: String
    }

    private func readLightweightPSTable() -> [Int32: PSRow] {
        guard let out = VitalsAuxiliaryScanner.runCommand("/bin/ps", args: ["-Axo", "pid=,ppid=,pcpu=,rss=,vsz=,time=,state=,user=,comm="], timeoutSeconds: 2.0) else {
            return [:]
        }
        var map: [Int32: PSRow] = [:]
        for line in out.split(separator: "\n") {
            let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 8, omittingEmptySubsequences: true)
            guard parts.count >= 9,
                  let pid = Int32(parts[0]),
                  let ppid = Int32(parts[1]),
                  let cpu = Double(parts[2].replacingOccurrences(of: ",", with: ".")),
                  let rss = Double(parts[3].replacingOccurrences(of: ",", with: ".")),
                  let vsz = Double(parts[4].replacingOccurrences(of: ",", with: ".")) else { continue }
            let timeSec = Self.parsePSTime(String(parts[5]))
            map[pid] = PSRow(
                ppid: ppid,
                cpuPercent: cpu,
                rssKB: rss,
                vszKB: vsz,
                cpuTimeSeconds: timeSec,
                state: String(parts[6]),
                user: String(parts[7]),
                comm: String(parts[8])
            )
        }
        return map
    }

    private static func parsePSTime(_ s: String) -> Double {
        // Formats: MM:SS.cc or HH:MM:SS or D-HH:MM:SS
        var days: Double = 0
        var rest = s
        if let dash = rest.firstIndex(of: "-") {
            days = Double(rest[..<dash]) ?? 0
            rest = String(rest[rest.index(after: dash)...])
        }
        let comps = rest.split(separator: ":").compactMap { Double($0) }
        if comps.count == 2 {
            return days * 86400 + comps[0] * 60 + comps[1]
        } else if comps.count == 3 {
            return days * 86400 + comps[0] * 3600 + comps[1] * 60 + comps[2]
        }
        return 0
    }

    private static func readWorkingDirectory(pid: Int32) -> String? {
        guard pid > 0 else { return nil }
        var vnodeInfo = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &vnodeInfo, size) == size else { return nil }
        return withUnsafePointer(to: &vnodeInfo.pvi_cdir.vip_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { cstr in
                let path = String(cString: cstr)
                return path.isEmpty ? nil : path
            }
        }
    }

    private static func extractAppBundleURL(from path: String) -> URL? {
        guard let range = path.range(of: ".app/") else {
            return path.hasSuffix(".app") ? URL(fileURLWithPath: path) : nil
        }
        // Take the outermost .app bundle so embedded Helper.app folds cleanly under its parent App!
        let bundlePath = String(path[..<range.lowerBound]) + ".app"
        return URL(fileURLWithPath: bundlePath)
    }

    private static func resolveAppGroup(
        for proc: VitalsProcessItem,
        byPID: [Int32: VitalsProcessItem]
    ) -> (key: String, name: String, bundleURL: URL?) {
        // 1. Direct outer .app bundle
        if let bundle = proc.bundleURL {
            let name = bundle.deletingPathExtension().lastPathComponent
            return ("app:\(bundle.path)", name, bundle)
        }
        // 2. Walk up parent chain (up to 4 hops) to find owning .app (e.g. XPC/Helper/Renderer child)
        var cursor = proc.ppid
        for _ in 0..<4 {
            guard cursor > 1, let parent = byPID[cursor] else { break }
            if let bundle = parent.bundleURL {
                let name = bundle.deletingPathExtension().lastPathComponent
                return ("app:\(bundle.path)", name, bundle)
            }
            cursor = parent.ppid
        }
        // 3. Well-known service families
        let lower = proc.name.lowercased()
        let lowerPath = proc.path.lowercased()
        if lowerPath.contains("docker") || lowerPath.contains("orbstack") { return ("svc:docker", "Docker / Containers", nil) }
        if lower.contains("antigravity") || lower == "agy" || lowerPath.contains("antigravity") { return ("svc:agy", "Antigravity", nil) }
        if lower.contains("claude") { return ("svc:claude", "Claude Code", nil) }
        if lower.contains("ollama") { return ("svc:ollama", "Ollama", nil) }
        if lower == "node" || lower == "vite" || lower == "next-server" { return ("svc:node", "Node.js", nil) }
        if lower.hasPrefix("python") { return ("svc:python", "Python", nil) }
        if proc.isSystemProcess { return ("sys:\(proc.name)", proc.name, nil) }
        return ("proc:\(proc.name)", proc.name, nil)
    }

    private static func detectAgentLabel(lowerName: String, lowerPath: String) -> String? {
        if lowerName.contains("claude") || lowerPath.contains("/claude") { return "Claude Code" }
        if lowerName == "codex" || lowerPath.contains("/codex") { return "OpenAI Codex" }
        if lowerName.contains("antigravity") || lowerName == "agy" || lowerPath.contains("agy-acp") { return "Antigravity (agy)" }
        if lowerName.contains("cursor") && !lowerName.contains("cursoruiview") { return "Cursor" }
        if lowerName.contains("windsurf") { return "Windsurf" }
        if lowerName.contains("ollama") { return "Ollama" }
        if lowerName.contains("opencode") { return "OpenCode" }
        if lowerName == "gemini" || lowerPath.contains("gemini-cli") { return "Gemini CLI" }
        if lowerName.contains("aider") { return "Aider" }
        if lowerName.contains("lmstudio") || lowerName.contains("lms") { return "LM Studio" }
        return nil
    }

    private static func buildDevProjects(from items: [VitalsProcessItem]) -> [VitalsDevProject] {
        let home = NSHomeDirectory()
        var byDir: [String: (pids: [Int32], ports: Set<UInt16>, cpu: Double, mem: Double)] = [:]
        for p in items {
            guard let cwd = p.workingDir,
                  cwd != "/", cwd != home,
                  !cwd.hasPrefix("/System"), !cwd.hasPrefix("/Library"), !cwd.hasPrefix("/Applications"),
                  !cwd.hasPrefix("/private/var"), !cwd.hasPrefix("/usr") else { continue }
            var cur = byDir[cwd] ?? ([], [], 0, 0)
            cur.pids.append(p.id)
            cur.ports.formUnion(p.ports)
            cur.cpu += p.cpuPercent
            cur.mem += p.memoryMB
            byDir[cwd] = cur
        }
        return byDir.map { path, agg in
            VitalsDevProject(
                id: path,
                name: (path as NSString).lastPathComponent,
                path: path,
                pids: agg.pids,
                ports: Array(agg.ports).sorted(),
                totalCPU: agg.cpu,
                totalMemoryMB: agg.mem
            )
        }.sorted {
            if !$0.ports.isEmpty && $1.ports.isEmpty { return true }
            if $0.ports.isEmpty && !$1.ports.isEmpty { return false }
            return $0.totalMemoryMB > $1.totalMemoryMB
        }
    }

    private static func readProcessArgsAndEnv(pid: Int32) -> (args: [String], env: [(String, String)]) {
        guard pid > 0 else { return ([], []) }
        var argmax: Int32 = 0
        var argmaxSize = MemoryLayout<Int32>.size
        var maxMib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        if sysctl(&maxMib, 2, &argmax, &argmaxSize, nil, 0) != 0 || argmax <= 0 {
            argmax = 262_144
        }
        var size = Int(argmax)
        var buffer = [UInt8](repeating: 0, count: size)
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0,
              size > MemoryLayout<Int32>.size else {
            return ([], [])
        }

        // Format of KERN_PROCARGS2:
        // [Int32 argc][exec_path\0][\0 padding...][argv[0]\0]...[argv[argc-1]\0][env[0]\0]...[env[k]\0]
        var argc: Int32 = 0
        _ = withUnsafeMutableBytes(of: &argc) { dst in
            buffer.withUnsafeBytes { src in
                memcpy(dst.baseAddress!, src.baseAddress!, MemoryLayout<Int32>.size)
            }
        }
        guard argc >= 0, argc < 16_384 else { return ([], []) }

        var idx = MemoryLayout<Int32>.size
        // Skip exec_path
        while idx < size && buffer[idx] != 0 { idx += 1 }
        // Skip trailing NUL padding after exec_path
        while idx < size && buffer[idx] == 0 { idx += 1 }

        func readNextCString() -> String? {
            guard idx < size else { return nil }
            let start = idx
            while idx < size && buffer[idx] != 0 { idx += 1 }
            let str = String(decoding: buffer[start..<idx], as: UTF8.self)
            idx += 1 // consume NUL
            return str
        }

        var args: [String] = []
        args.reserveCapacity(Int(argc))
        for _ in 0..<argc {
            guard let s = readNextCString() else { break }
            args.append(s)
        }

        var env: [(String, String)] = []
        while idx < size {
            if buffer[idx] == 0 {
                idx += 1
                continue
            }
            guard let entry = readNextCString(), !entry.isEmpty else { break }
            if let eq = entry.firstIndex(of: "="), eq > entry.startIndex {
                let k = String(entry[..<eq])
                let v = String(entry[entry.index(after: eq)...])
                env.append((k, v))
            }
            if env.count >= 512 { break }
        }
        return (args, env)
    }

    private static func categorizePort(port: UInt16, comm: String) -> VitalsPortItem.PortCategory {
        let lower = comm.lowercased()
        if lower.contains("agy") || lower.contains("antigravity") || lower.contains("claude") || lower.contains("cursor") || lower.contains("ollama") || port == 11434 {
            return .agent
        }
        if [3306, 5432, 6379, 27017, 9200, 9300, 11211, 1433, 5672].contains(port) ||
            lower.contains("postgres") || lower.contains("mysql") || lower.contains("redis") || lower.contains("mongo") {
            return .database
        }
        if [3000, 3001, 3002, 4000, 4173, 4174, 4200, 5001, 5173, 5174, 8000, 8080, 8081, 8888, 9000, 9090].contains(port) ||
            lower.contains("node") || lower.contains("vite") || lower.contains("python") || lower.contains("bun") || lower.contains("ruby") || lower.contains("next") || lower.contains("uvicorn") || lower == "go" {
            return .devServer
        }
        if [5000, 7000, 55156].contains(port) || lower.contains("controlcenter") || lower.contains("rapportd") || lower.contains("airplay") {
            return .system
        }
        return .other
    }
}
