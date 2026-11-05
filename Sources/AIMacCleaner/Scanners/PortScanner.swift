import Foundation

/// 端口查看器：列出当前正在监听的 TCP 端口，显示占用进程与路径，
/// 便于排查「谁占了 8080 / 某个服务起不来」。
///
/// 数据来自 `lsof -iTCP -sTCP:LISTEN -P -n -l`。UDP 监听不在此列（无连接态，
/// 噪声大），符合「系统体检」定位冲突端口的诉求。

struct ListeningPort: Identifiable {
    let id = UUID()
    let port: Int
    let proto: String          // "TCP" / "UDP"
    let pid: pid_t
    let command: String        // 进程命令名（首段）
    let address: String        // 监听地址：* / 127.0.0.1 / ::1 …
    let user: String
    var selected: Bool

    /// 进程可执行路径（按 pid 在 PortScanner.programPathCache 中缓存，列表展示时取用）。
    var programPath: String? { PortScanner.programPathCache[pid] }
}

enum PortScanner {

    /// 按 pid 缓存可执行路径，列表展示时复用，避免逐行再查。
    static var programPathCache: [pid_t: String] = [:]

    static func scan() -> [ListeningPort] {
        programPathCache.removeAll()
        guard let raw = runLsof() else { return [] }
        var ports: [ListeningPort] = []
        let lines = raw.components(separatedBy: "\n")
        for line in lines.dropFirst() {  // 跳过表头
            guard let p = parse(line) else { continue }
            ports.append(p)
        }
        return ports.sorted {
            $0.port != $1.port ? $0.port < $1.port : $0.command < $1.command
        }
    }

    private static func runLsof() -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        proc.arguments = ["-iTCP", "-sTCP:LISTEN", "-P", "-n", "-l"]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        do {
            try proc.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }

    private static func parse(_ line: String) -> ListeningPort? {
        let f = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard f.count >= 9 else { return nil }
        let command = f[0]
        guard let pid = pid_t(f[1]) else { return nil }
        let user = f[2]
        // 找到协议标记（TCP / UDP），其后紧跟 addr:port。
        guard let idx = f.firstIndex(where: { $0 == "TCP" || $0 == "UDP" }),
              idx + 1 < f.count else { return nil }
        let proto = f[idx]
        let addrPort = f[idx + 1]
        // addrPort 形如 127.0.0.1:8080 / *:3000 / [::1]:8080 / *:8080->...
        let cleaned = addrPort.components(separatedBy: "->").first ?? addrPort
        guard let colon = cleaned.lastIndex(of: ":") else { return nil }
        let portStr = String(cleaned[cleaned.index(after: colon)...])
        guard let port = Int(portStr) else { return nil }
        let address = String(cleaned[..<colon])
        if programPathCache[pid] == nil {
            programPathCache[pid] = executablePath(for: pid)
        }
        return ListeningPort(port: port, proto: proto, pid: pid, command: command,
                            address: address, user: user, selected: false)
    }

    /// 查进程可执行路径（用于「在访达中显示」与识别真身）。
    private static func executablePath(for pid: pid_t) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/ps")
        proc.arguments = ["-o", "comm=", "-p", "\(pid)"]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        do {
            try proc.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            let s = (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return s.isEmpty ? nil : s
        } catch {
            return nil
        }
    }
}
