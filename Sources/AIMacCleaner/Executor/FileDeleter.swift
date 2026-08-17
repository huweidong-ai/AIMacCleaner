import Foundation

/// 安全删除文件/目录。带白名单检查，防止误删。
///
/// **默认移到废纸篓，不永久删除。** 这是本工具最重要的安全网：白名单和
/// foreignKeywords 都是启发式判断，总有判错的可能，废纸篓让每一次判错都可挽回。
/// tar.gz 备份只覆盖 userData 类，其余类别一旦永久删除就找不回来了。
enum FileDeleter {
    /// 删除方式。
    enum Disposition {
        /// 移到废纸篓（默认）。可在 Finder 里看到并拖回来。
        case trash
        /// 永久删除（不可恢复）。
        /// v1.5 起真实卸载路径也用：可安全删除的项（应用、缓存、日志、安装器）
        /// 直接彻底删除；只有「用户数据」类默认走废纸篓（可恢复）。
        /// 自检探针仍用 `.permanent`，以免每次 `--self-test` 都往用户废纸篓里塞垃圾。
        case permanent
    }

    struct Result {
        let path: String
        let success: Bool
        let message: String
        /// 移到废纸篓后的实际位置。永久删除或失败时为 nil。
        /// 调用方据此判断磁盘空间是否真的释放了。
        let trashedTo: String?
        /// true 表示删除失败是因为「没有权限」——通常是该路径由系统/安装器以 root
        /// 身份写入（如 `/Applications` 下的原生安装器 app），普通用户删不动。
        /// 此时可由 `PrivilegedDeleter` 以管理员身份兜底删除。
        let needsElevation: Bool

        init(path: String, success: Bool, message: String, trashedTo: String? = nil,
             needsElevation: Bool = false) {
            self.path = path
            self.success = success
            self.message = message
            self.trashedTo = trashedTo
            self.needsElevation = needsElevation
        }
    }

    /// 允许删除的路径前缀（只动用户级文件，绝不碰 /System、/usr、/private/var）
    static let allowedPrefixes: [String] = [
        "\(NSHomeDirectory())/Applications/",
        "\(NSHomeDirectory())/Library/Application Support/",
        "\(NSHomeDirectory())/Library/Preferences/",
        "\(NSHomeDirectory())/Library/Caches/",
        "\(NSHomeDirectory())/Library/Logs/",
        "\(NSHomeDirectory())/Library/Saved Application State/",
        "\(NSHomeDirectory())/Library/LaunchAgents/",
        // v1.1 的 ContainerScanner 会扫出这两处（微信 3.6 GB 就在这里），
        // 但白名单当时漏了它们 —— 结果 UI 报告「释放 3.6 GB」、
        // 执行阶段却静默跳过「路径不在白名单内」。v1.2 补上。
        "\(NSHomeDirectory())/Library/Containers/",
        "\(NSHomeDirectory())/Library/Group Containers/",
        // v1.3：LibraryDataScanner 从 5 个目录扩到 12 个，白名单必须同步扩 ——
        // 否则就是 v1.1 那个 bug 的原样重演（扫得出、报得出、执行阶段静默跳过）。
        // 加扫描目录时**必须**同时加这里，`--self-test` 里有对应断言。
        "\(NSHomeDirectory())/Library/HTTPStorages/",
        "\(NSHomeDirectory())/Library/Cookies/",
        "\(NSHomeDirectory())/Library/Services/",
        "\(NSHomeDirectory())/Library/WebKit/",
        "\(NSHomeDirectory())/Library/Application Scripts/",
        "\(NSHomeDirectory())/Library/Internet Plug-Ins/",
        "\(NSHomeDirectory())/Library/PreferencePanes/",
        "\(NSHomeDirectory())/.local/share/",
        "\(NSHomeDirectory())/.local/state/",
        "\(NSHomeDirectory())/.local/bin/",
        "\(NSHomeDirectory())/.cache/",
        "\(NSHomeDirectory())/.config/",
        "\(NSHomeDirectory())/Downloads/",
        "\(NSHomeDirectory())/Documents/",
        "\(NSHomeDirectory())/Desktop/",
        "\(NSHomeDirectory())/Pictures/",
        "\(NSHomeDirectory())/Music/",
        "\(NSHomeDirectory())/Movies/",
        "\(NSHomeDirectory())/.",          // 任意 dotfile
        "/Applications/",
        "/Library/LaunchAgents/",
        "/Library/LaunchDaemons/"
    ]

    /// 系统级禁止前缀
    static let forbiddenPrefixes: [String] = [
        "/System/", "/usr/", "/private/var/", "/private/etc/", "/private/tmp/",
        "/bin/", "/sbin/", "/etc/", "/var/"
    ]

    static func delete(_ path: String, disposition: Disposition = .trash) -> Result {
        // 规范化路径
        let expanded = (path as NSString).expandingTildeInPath
        let standardized = (expanded as NSString).standardizingPath
        guard !standardized.isEmpty else {
            return Result(path: path, success: false, message: "路径为空")
        }

        // 白名单检查
        guard isAllowed(standardized) else {
            return Result(path: standardized, success: false, message: "路径不在白名单内，已跳过")
        }

        // 二次确认：禁止前缀
        for prefix in forbiddenPrefixes where standardized.hasPrefix(prefix) {
            return Result(path: standardized, success: false, message: "禁止触碰系统路径")
        }

        // 保护：不能删除家目录根
        let home = NSHomeDirectory()
        if standardized == home || standardized == home + "/" {
            return Result(path: standardized, success: false, message: "禁止删除家目录根")
        }

        let fm = FileManager.default
        if !fm.fileExists(atPath: standardized) {
            return Result(path: standardized, success: true, message: "已不存在")
        }

        switch disposition {
        case .permanent:
            do {
                try fm.removeItem(atPath: standardized)
                return Result(path: standardized, success: true, message: "已永久删除")
            } catch {
                // NSFileWriteNoPermissionError(513)：路径由 root 拥有（系统安装器装的
                // app 常见），普通用户删不动。标记 needsElevation，UI 可给出「以管理员
                // 身份删除」的兜底入口。
                let code = (error as NSError).code
                return Result(path: standardized, success: false,
                              message: "删除失败: \(error.localizedDescription)",
                              needsElevation: code == NSFileWriteNoPermissionError)
            }

        case .trash:
            // trashItem 需要 URL，结果位置写回 resultingItemURL。
            // **失败时绝不回退到 removeItem** —— 那等于把「东西还在废纸篓里」
            // 这个安全承诺变成谎言。让用户看到失败原因，自己决定下一步。
            var resulting: NSURL?
            do {
                try fm.trashItem(at: URL(fileURLWithPath: standardized), resultingItemURL: &resulting)
                return Result(path: standardized, success: true, message: "已移到废纸篓",
                              trashedTo: (resulting as URL?)?.path)
            } catch {
                // ~/Library/Containers 由 containermanagerd 独占管理，**父目录不可写**，
                // 所以容器目录本身怎么都移不走 —— 实测报错原文是「don't have permission
                // to access "Containers"」，拦的是父目录。这一点连「完全磁盘访问权限」
                // 也解决不了（实测已授权仍失败），它是 SIP 支持的保护。
                //
                // 但**容器内部的数据是能删的**（实测可删）。用户在意的是里面那几 GB，
                // 不是那个空壳目录。所以降级：清空内容，保留壳。
                if isContainerPath(standardized) {
                    return emptyContainer(standardized)
                }
                return Result(path: standardized, success: false,
                              message: "移到废纸篓失败: \(error.localizedDescription)",
                              needsElevation: (error as NSError).code == NSFileWriteNoPermissionError)
            }
        }
    }

    /// 是否是 containermanagerd 管辖的容器目录（其父目录不可写）。
    static func isContainerPath(_ path: String) -> Bool {
        let home = NSHomeDirectory()
        for base in ["\(home)/Library/Containers/", "\(home)/Library/Group Containers/"] {
            guard path.hasPrefix(base) else { continue }
            // 只认容器**本身**（base 的直接子项）。容器内部的子路径不算 ——
            // 那些能正常移到废纸篓，不该走降级分支。
            let rest = path.dropFirst(base.count)
            if !rest.isEmpty && !rest.contains("/") { return true }
        }
        return false
    }

    /// 清空容器内容但保留容器目录本身。
    ///
    /// 内部条目逐个移到废纸篓（仍然可恢复）。刻意跳过
    /// `.com.apple.containermanagerd.metadata.plist` —— 那是 containermanagerd
    /// 的账本，删了它容器会变成系统眼中的损坏状态。
    private static func emptyContainer(_ path: String) -> Result {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: path) else {
            return Result(path: path, success: false,
                          message: "容器受系统保护，且无法读取内容")
        }
        let payload = items.filter { $0 != ".com.apple.containermanagerd.metadata.plist" }
        if payload.isEmpty {
            // 只剩系统账本，里面本来就没有用户数据。报成功但说清真相：
            // 目录还在。绝不能只说「已清理」——那是假报成功。
            return Result(path: path, success: true,
                          message: "内容已空，容器空壳由系统保留（无法删除，也不占空间）")
        }
        var trashed = 0
        var lastError: String?
        var firstTrashLocation: String?
        for item in payload {
            var out: NSURL?
            do {
                try fm.trashItem(at: URL(fileURLWithPath: "\(path)/\(item)"), resultingItemURL: &out)
                trashed += 1
                if firstTrashLocation == nil { firstTrashLocation = (out as URL?)?.path }
            } catch {
                lastError = error.localizedDescription
            }
        }
        if trashed == 0 {
            return Result(path: path, success: false,
                          message: "移到废纸篓失败: \(lastError ?? "容器受系统保护")")
        }
        // 部分成功也要说清楚，不能一律报成功。
        if trashed < payload.count {
            return Result(path: path, success: false,
                          message: "仅清理了 \(trashed)/\(payload.count) 项内容: \(lastError ?? "")",
                          trashedTo: firstTrashLocation)
        }
        return Result(path: path, success: true,
                      message: "内容已移到废纸篓（容器空壳由系统保留）",
                      trashedTo: firstTrashLocation)
    }

    /// 路径是否在允许删除的白名单内（含家目录根特例）。
    /// `internal` 以便 `PrivilegedDeleter` 复用同一套白名单，避免提权删除绕过安全网。
    static func isAllowed(_ path: String) -> Bool {
        let home = NSHomeDirectory()
        if path == home { return true }
        return allowedPrefixes.contains { path.hasPrefix($0) }
    }
}
