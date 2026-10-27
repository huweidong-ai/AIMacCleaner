import Foundation
import Darwin

/// 进程分类：决定「能不能杀」与「在哪个筛选档里显示」。
enum ProcessKind: String, CaseIterable, Identifiable {
    /// 用户级、无 GUI 的进程（node / python / 数据库 / dev server …）—— 主要目标
    case background
    /// GUI 应用（位于 `*.app/Contents/MacOS`）
    case app
    /// 系统进程（root / 系统路径）—— 永不杀
    case system

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .background: return L10n.t("后台", "Background")
        case .app:        return L10n.t("应用", "App")
        case .system:     return L10n.t("系统", "System")
        }
    }
}

/// 枚举到的一个运行中进程。
struct LiveProcess: Identifiable, Hashable {
    let pid: pid_t
    /// 展示名：优先命令行首段 basename，否则可执行文件 basename，再否则内核 comm
    let name: String
    /// 内核截断名（≤15 字符），用于关键进程名兜底判断
    let comm: String
    let executablePath: String
    let arguments: [String]
    let uid: uid_t
    let ppid: pid_t
    /// 常驻内存 RSS（字节）
    let memoryBytes: Int64
    /// 采样窗口内的 CPU 占用（%）
    let cpuPercent: Double
    let kind: ProcessKind
    var id: pid_t { pid }

    /// 是否可被用户结束：系统进程、AI Mac Cleaner 自身、关键进程名 一律 false。
    let isKillable: Bool
    /// 该进程正在监听的 TCP 端口（LISTEN 状态），通过 lsof 获取。
    let ports: [Int]
}

/// 全局进程枚举与分类。「进程」tab 与自检共用。
///
/// 用 `proc_listpids` + `proc_pidinfo`（而非 `NSRunningApplication`）枚举——
/// 后者只认 GUI app，看不到用户忘关的 `node` / `python` / 数据库这类无界面进程。
enum ProcessLister {
    /// 绝不被杀的关键进程名（即便分类没挡住，也兜底拦一道）。
    private static let criticalNames: Set<String> = [
        "launchd", "kernel_task", "WindowServer", "loginwindow",
        "SystemUIServer", "cfprefsd", "trustd", "opendirectoryd",
        "mDNSResponder", "configd", "syslogd", "kextd", "fseventsd"
    ]

    /// 系统路径前缀：uid 非 0 之外的保险，这些目录下的也归系统。
    private static let systemPrefixes = [
        "/System/", "/usr/libexec/", "/sbin/", "/usr/sbin/",
        "/Library/Apple/", "/Library/PrivilegedHelperTools/"
    ]

    /// 取命令行参数用的 flavor。本 SDK 的 `<sys/proc_info.h>` 没导出这个宏，
    /// 但头文件里它就是 `2`（`PROC_PIDPATHINFO=1`, `PROC_PIDARGS=2`,
    /// `PROC_PIDTBSDINFO=3`, `PROC_PIDTASKINFO=4`），照此补一个本地常量。
    private static let PROC_PIDARGS: Int32 = 2

    /// 枚举当前用户能看到的所有进程（含系统），分类并采样 CPU。
    /// **不会杀任何进程**。返回的项不排除自身——能否杀由 `isKillable` 标明，
    /// 调用方（UI / 自检）按需取用。
    static func snapshot() -> [LiveProcess] {
        // 1) 拿到全部 PID 列表。
        let capacity = 8192
        var pids = [pid_t](repeating: 0, count: capacity)
        let needed = proc_listpids(UInt32(PROC_ALL_PIDS), UInt32(0), &pids, Int32(MemoryLayout<pid_t>.stride * capacity))
        guard needed > 0 else { return [] }
        let count = min(Int(needed) / MemoryLayout<pid_t>.stride, capacity)

        let ownPid = ProcessInfo.processInfo.processIdentifier

        // 2) 第一遍：静态信息 + CPU 起点。
        struct Partial {
            let pid: pid_t
            let comm: String
            let path: String
            let args: [String]
            let uid: uid_t
            let ppid: pid_t
            let mem: Int64
            let cpu0: UInt64
        }
        var partials: [Partial] = []
        for i in 0..<count {
            let pid = pids[i]
            guard pid > 0 else { continue }

            // 注意：本 SDK 里 Swift 的 `proc_bsdshortinfo` 只有 64 字节，
            // 但内核实际结构是 136 字节。按 MemoryLayout 传 64 当 buffersize
            // 会被内核判 ENOMEM 返回 0（每个进程都被 guard 跳过 → 列表空）。
            // 所以用一块足够大的字节缓冲，再 reinterpret 成结构体读字段
            // （前 64 字节布局一致，uid/ppid 经验证读取正确）。
            var bsdBuf = [UInt8](repeating: 0, count: 256)
            let brc = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsdBuf, Int32(bsdBuf.count))

            var task = proc_taskinfo()
            let trc = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, Int32(MemoryLayout<proc_taskinfo>.size))
            let mem = trc > 0 ? Int64(task.pti_resident_size) : 0
            let cpu0 = trc > 0 ? (task.pti_total_user + task.pti_total_system) : 0

            let path = Self.executablePath(for: pid)
            let args = Self.arguments(for: pid)

            let uid: uid_t
            let ppid: pid_t
            if brc > 0 {
                let bsd = bsdBuf.withUnsafeBytes { $0.bindMemory(to: proc_bsdshortinfo.self).baseAddress!.pointee }
                uid = bsd.pbsi_uid
                ppid = pid_t(bsd.pbsi_ppid)
            } else {
                // 读不到 BSD 信息：通常是 root 系统进程（proc_pidinfo 需 entitlement）。
                // 无法确认 uid，保守按系统进程处理、不可杀——宁可漏报也不误杀。
                uid = 0
                ppid = 0
            }

            // 内核 comm 字段在本 SDK 的 Swift 结构里偏移对不上（读出乱码），
            // 直接用路径 / 命令行首段的 basename 当名称，足够用于显示与关键进程判断。
            let comm: String = {
                if !path.isEmpty { return (path as NSString).lastPathComponent }
                if let first = args.first { return (first as NSString).lastPathComponent }
                return ""
            }()

            partials.append(Partial(pid: pid, comm: comm, path: path, args: args,
                                    uid: uid, ppid: ppid,
                                    mem: mem, cpu0: cpu0))
        }

        // 3) 单段停顿采样 CPU（避免逐个进程 sleep 拖垮速度）。
        let start = Date()
        Thread.sleep(forTimeInterval: 0.25)
        let wallNs = max(1, UInt64(-start.timeIntervalSinceNow * 1_000_000_000))

        // 3.5) 端口映射：PID → 监听的 TCP 端口列表。
        let portMap = Self.scanPorts()

        // 4) 第二遍：CPU 终点 + 组装。
        var result: [LiveProcess] = []
        for p in partials {
            var task = proc_taskinfo()
            let trc = proc_pidinfo(p.pid, PROC_PIDTASKINFO, 0, &task, Int32(MemoryLayout<proc_taskinfo>.size))
            let cpu1 = trc > 0 ? (task.pti_total_user + task.pti_total_system) : p.cpu0
            let delta = cpu1 > p.cpu0 ? cpu1 - p.cpu0 : 0
            let cpuPercent = Double(delta) / Double(wallNs) * 100.0

            let kind = Self.classify(path: p.path, uid: p.uid)
            let isKillable = kind != .system
                && p.pid != ownPid
                && p.pid > 1
                && !Self.criticalNames.contains(p.comm)

            // 展示名：命令行首段 basename → 路径 basename → comm。
            let displayName: String
            if let first = p.args.first, !first.isEmpty {
                displayName = (first as NSString).lastPathComponent
            } else if !p.path.isEmpty {
                displayName = (p.path as NSString).lastPathComponent
            } else {
                displayName = p.comm
            }

            result.append(LiveProcess(
                pid: p.pid, name: displayName, comm: p.comm,
                executablePath: p.path, arguments: p.args,
                uid: p.uid, ppid: p.ppid,
                memoryBytes: p.mem, cpuPercent: cpuPercent,
                kind: kind, isKillable: isKillable,
                ports: portMap[p.pid] ?? []
            ))
        }
        // 按内存从高到低，一眼看到最占资源的。
        return result.sorted { $0.memoryBytes > $1.memoryBytes }
    }

    /// 轻量采样（内存守卫后台轮询用）：单遍 `proc_listpids` + `proc_pidinfo`，
    /// 不做 CPU 二次采样、不跑 lsof、不取命令行参数 —— 开销远小于 `snapshot()`，
    /// 每 30 秒跑一次也不会被察觉。分类与保护规则（uid 0 / 系统路径 / 关键进程 /
    /// 自身）与 `snapshot()` 完全一致，`isKillable` 语义不变。
    static func lightweightSample() -> [LiveProcess] {
        let capacity = 8192
        var pids = [pid_t](repeating: 0, count: capacity)
        let needed = proc_listpids(UInt32(PROC_ALL_PIDS), UInt32(0), &pids, Int32(MemoryLayout<pid_t>.stride * capacity))
        guard needed > 0 else { return [] }
        let count = min(Int(needed) / MemoryLayout<pid_t>.stride, capacity)

        let ownPid = ProcessInfo.processInfo.processIdentifier
        var result: [LiveProcess] = []
        result.reserveCapacity(count)

        for i in 0..<count {
            let pid = pids[i]
            guard pid > 0 else { continue }

            // BSD 信息缓冲按 snapshot() 同款 256 字节处理（64 字节会被内核判 ENOMEM）。
            var bsdBuf = [UInt8](repeating: 0, count: 256)
            let brc = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsdBuf, Int32(bsdBuf.count))

            var task = proc_taskinfo()
            let trc = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, Int32(MemoryLayout<proc_taskinfo>.size))
            let mem = trc > 0 ? Int64(task.pti_resident_size) : 0

            let path = Self.executablePath(for: pid)
            let uid: uid_t
            let ppid: pid_t
            if brc > 0 {
                let bsd = bsdBuf.withUnsafeBytes { $0.bindMemory(to: proc_bsdshortinfo.self).baseAddress!.pointee }
                uid = bsd.pbsi_uid
                ppid = pid_t(bsd.pbsi_ppid)
            } else {
                uid = 0
                ppid = 0
            }

            let comm = path.isEmpty ? "" : (path as NSString).lastPathComponent
            let kind = Self.classify(path: path, uid: uid)
            let isKillable = kind != .system
                && pid != ownPid
                && pid > 1
                && !Self.criticalNames.contains(comm)

            result.append(LiveProcess(
                pid: pid,
                name: comm.isEmpty ? "pid \(pid)" : comm,
                comm: comm,
                executablePath: path,
                arguments: [],
                uid: uid, ppid: ppid,
                memoryBytes: mem, cpuPercent: 0,
                kind: kind, isKillable: isKillable,
                ports: []
            ))
        }
        return result.sorted { $0.memoryBytes > $1.memoryBytes }
    }

    // MARK: - 辅助

    /// 扫描所有 TCP LISTEN 端口，返回 PID → [端口] 的映射。
    ///
    /// 使用 `lsof -iTCP -sTCP:LISTEN -n -P`：
    /// `-n` 不解析主机名、`-P` 不解析服务名（直接出端口号）、`-sTCP:LISTEN` 只看监听态。
    /// 不加 sudo：仅取当前用户可见的进程，避免误杀系统服务。
    ///
    /// 输出格式（标准表格）：
    /// ```
    /// COMMAND   PID   USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME
    /// node    18789   hwd   23u  IPv4 0x12345678      0t0  TCP *:18789 (LISTEN)
    /// ```
    static func scanPorts() -> [pid_t: [Int]] {
        let task = Process()
        task.launchPath = "/usr/sbin/lsof"
        task.arguments = ["-iTCP", "-sTCP:LISTEN", "-n", "-P"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        task.launch()

        let deadline = DispatchTime.now() + .seconds(5)
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async { task.waitUntilExit(); group.leave() }
        if group.wait(timeout: deadline) == .timedOut { task.terminate(); return [:] }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return [:] }

        var map: [pid_t: [Int]] = [:]
        let lines = output.split(separator: "\n")

        for line in lines {
            let l = String(line)
            // 跳过标题行
            if l.hasPrefix("COMMAND") { continue }
            // 按空白分割：COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME
            let cols = l.split(separator: " ", omittingEmptySubsequences: true)
            // 至少需要：COMMAND PID NAME（端口在 NAME 列，格式 *:PORT 或 IP:PORT）
            guard cols.count >= 9 else { continue }
            guard let pid = pid_t(cols[1]) else { continue }
            let name = String(cols[8])

            // NAME 格式：*:3000 或 127.0.0.1:8080 或 [::1]:3000 或 localhost:5432
            // 提取最后的 :PORT
            if let colon = name.lastIndex(of: ":"),
               let port = Int(name[name.index(after: colon)...]) {
                map[pid, default: []].append(port)
            }
        }
        return map
    }

    private static func classify(path: String, uid: uid_t) -> ProcessKind {
        if uid == 0 { return .system }
        if systemPrefixes.contains(where: { path.hasPrefix($0) }) { return .system }
        if path.contains(".app/Contents/MacOS") { return .app }
        return .background
    }

    private static func executablePath(for pid: pid_t) -> String {
        var buf = [CChar](repeating: 0, count: 4096)
        // PROC_PIDPATHINFO 在本 SDK 下返回值不可靠（rc 常为 0 但路径已写入），
        // 直接读缓冲区首个字符判断是否有内容。
        _ = proc_pidinfo(pid, PROC_PIDPATHINFO, 0, &buf, Int32(buf.count))
        let s = String(cString: buf)
        return s.isEmpty ? "" : s
    }

    private static func arguments(for pid: pid_t) -> [String] {
        // PROC_PIDARGS 返回以 NUL 分隔的 argv（末尾多一个 NUL）。
        let size = 4096
        var buf = [CChar](repeating: 0, count: size)
        _ = proc_pidinfo(pid, Self.PROC_PIDARGS, 0, &buf, Int32(size))
        let data = Data(bytes: buf, count: size)
        guard let str = String(data: data, encoding: .utf8) else { return [] }
        return str.split(separator: "\0")
            .map(String.init)
            .filter { !$0.isEmpty }
    }
}
