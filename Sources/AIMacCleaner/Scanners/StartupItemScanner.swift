import Foundation

/// 启动项管理：扫描三类会随登录 / 开机自启的条目，并支持禁用与移除。
///
/// - 用户级 LaunchAgent：`~/Library/LaunchAgents`（最常见，可自行管理）
/// - 系统级 LaunchAgent：`/Library/LaunchAgents`
/// - 系统级 LaunchDaemon：`/Library/LaunchDaemons`
/// - 登录项：通过 `sfltool dumpbtm` 尽力提取（仅展示，系统不开放稳定的禁用 API）
///
/// 用户级条目可直接「禁用（重命名 .plist → .plist.disabled）/ 启用 / 移到废纸篓」；
/// 系统级条目同样走文件操作，但写入 /Library 需要管理员权限，操作失败会如实回报。

enum StartupDomain: String, CaseIterable, Identifiable {
    case userAgent, systemAgent, systemDaemon, loginItem
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .userAgent:   return L10n.t("用户级 Agent", "User agent")
        case .systemAgent: return L10n.t("系统级 Agent", "System agent")
        case .systemDaemon:return L10n.t("系统级 Daemon", "System daemon")
        case .loginItem:   return L10n.t("登录项", "Login item")
        }
    }

    /// 是否支持在本 App 内直接禁用 / 移除（登录项系统不开放稳定 API，仅展示）。
    var manageable: Bool {
        switch self {
        case .userAgent, .systemAgent, .systemDaemon: return true
        case .loginItem: return false
        }
    }
}

struct StartupItem: Identifiable {
    let id = UUID()
    let label: String
    let path: String
    let domain: StartupDomain
    var isEnabled: Bool
    let program: String?
    let bundleId: String?
    var selected: Bool

    /// 程序名（取 Program 或 ProgramArguments 第一项），用于展示。
    var programName: String {
        if let p = program, !p.isEmpty { return (p as NSString).lastPathComponent }
        return label
    }
}

enum StartupItemScanner {

    static func scan() -> [StartupItem] {
        var items: [StartupItem] = []
        items += scanLaunchDir(NSHomeDirectory() + "/Library/LaunchAgents", domain: .userAgent)
        items += scanLaunchDir("/Library/LaunchAgents", domain: .systemAgent)
        items += scanLaunchDir("/Library/LaunchDaemons", domain: .systemDaemon)
        items += scanLoginItems()
        return items.sorted {
            $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending
        }
    }

    // MARK: - LaunchAgents / Daemons

    private static func scanLaunchDir(_ dir: String, domain: StartupDomain) -> [StartupItem] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: dir) else { return [] }
        var items: [StartupItem] = []
        for name in files where name.hasSuffix(".plist") || name.hasSuffix(".plist.disabled") {
            let path = (dir as NSString).appendingPathComponent(name)
            let isDisabledFile = name.hasSuffix(".disabled")
            let baseName = isDisabledFile
                ? String(name.dropLast(".disabled".count))
                : name
            let label = (baseName as NSString).deletingPathExtension

            var program: String?
            var bundleId: String?
            var plistDisabled = false
            if let dict = readPlist(path) {
                program = programFrom(dict)
                bundleId = dict["Label"] as? String
                if let d = dict["Disabled"] as? Bool { plistDisabled = d }
            }
            // 最终是否启用：文件名带 .disabled 优先（我们的禁用手段），否则看 plist 的 Disabled 键。
            let enabled = !isDisabledFile && !plistDisabled
            items.append(StartupItem(label: label, path: path, domain: domain,
                                    isEnabled: enabled, program: program,
                                    bundleId: bundleId, selected: false))
        }
        return items
    }

    private static func readPlist(_ path: String) -> [String: Any]? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        guard let plist = try? PropertyListSerialization.propertyList(
            from: data, options: [], format: nil) else { return nil }
        return plist as? [String: Any]
    }

    private static func programFrom(_ dict: [String: Any]) -> String? {
        if let p = dict["Program"] as? String, !p.isEmpty { return p }
        if let args = dict["ProgramArguments"] as? [String], let first = args.first {
            return first
        }
        return nil
    }

    // MARK: - 登录项（sfltool 尽力提取）

    private static func scanLoginItems() -> [StartupItem] {
        guard let output = runSfltool() else { return [] }
        // 只在「User Items:」小节内提取看起来像反向 DNS 的条目（bundle id）。
        let lines = output.components(separatedBy: "\n")
        var inUserSection = false
        var items: [StartupItem] = []
        let bundleIdPattern = #"[A-Za-z0-9-]+\.[A-Za-z0-9.-]{3,}"#
        guard let regex = try? NSRegularExpression(pattern: bundleIdPattern) else { return [] }
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.lowercased().hasPrefix("user items:") {
                inUserSection = true
                continue
            }
            if trimmed.lowercased().hasPrefix("system items:") || trimmed.hasPrefix("Services:") {
                inUserSection = false
                continue
            }
            guard inUserSection, !trimmed.isEmpty else { continue }
            // 取该行里第一个匹配的反向 DNS 串作为 bundle id。
            let range = NSRange(trimmed.startIndex..., in: trimmed)
            if let match = regex.firstMatch(in: trimmed, range: range),
               let r = Range(match.range, in: trimmed) {
                let bid = String(trimmed[r])
                // 跳过明显是路径 / LaunchAgent 的条目，避免与上方重复。
                if bid.contains("/") { continue }
                items.append(StartupItem(label: bid, path: "", domain: .loginItem,
                                        isEnabled: true, program: bid, bundleId: bid,
                                        selected: false))
            }
        }
        // 去重（同一 bundle 可能多行）。
        var seen = Set<String>()
        return items.filter { seen.insert($0.bundleId ?? $0.label).inserted }
    }

    private static func runSfltool() -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/sfltool")
        proc.arguments = ["dumpbtm"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }

    // MARK: - 操作

    /// 禁用 / 启用一个 LaunchAgent / Daemon：通过重命名 `.plist` ↔ `.plist.disabled` 持久化。
    /// 同时尽力 `launchctl load/unload` 当前会话。返回是否成功。
    @discardableResult
    static func setEnabled(_ item: StartupItem, enabled: Bool) -> Bool {
        guard item.domain.manageable else { return false }
        let fm = FileManager.default
        let current = item.path
        let target: String
        if enabled {
            // 去掉 .disabled 后缀。
            guard current.hasSuffix(".disabled") else { return true }
            target = String(current.dropLast(".disabled".count))
        } else {
            // 加上 .disabled 后缀。
            guard !current.hasSuffix(".disabled") else { return true }
            target = current + ".disabled"
        }
        do {
            try fm.moveItem(atPath: current, toPath: target)
        } catch {
            return false
        }
        // 尽力影响当前会话（非管理员 / 未加载时失败也不影响持久化效果）。
        let _ = runLaunchctl(item, enable: enabled)
        return true
    }

    /// 把启动项移到废纸篓。返回是否成功。
    @discardableResult
    static func remove(_ item: StartupItem) -> Bool {
        guard item.domain.manageable, !item.path.isEmpty else { return false }
        do {
            try FileManager.default.trashItem(at: URL(fileURLWithPath: item.path),
                                             resultingItemURL: nil)
            return true
        } catch {
            return false
        }
    }

    private static func runLaunchctl(_ item: StartupItem, enable: Bool) -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        let basePath = item.path.hasSuffix(".disabled")
            ? String(item.path.dropLast(".disabled".count))
            : item.path
        proc.arguments = enable ? ["load", basePath] : ["unload", basePath]
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            return proc.terminationStatus == 0
        } catch {
            return false
        }
    }
}
