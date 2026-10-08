import Foundation

/// 只读探针：让 Agent 能「翻目录 / 读内容」，而不只是「看清单」。
///
/// ## 为什么需要它
///
/// 内置扫描器全是「关键词命中即报」，命中不了就等于不存在。真实漏项长这样：
/// StoryFab 的 bundle id 是 `com.story-fab.desktop`，扫描器下发的关键词是
/// `com.story-fab.desktop` 和 `storyfab`（去连字符形式），而它真正的数据目录叫
/// **`story-fab`（带连字符）** —— 谁也匹配不上，于是那 12 KB 崩溃报告一直留着。
/// 靠一个**更宽的 token**（`story`）去枚举、再逐个验证归属，才能发现它。
/// `search` + `inspect` 就是把这两个动作固化成 skill，让 agent 自己走一遍。
///
/// ## 三条硬约束（不能因为「让模型更聪明」而放松）
///
/// 1. **只在白名单根目录里找**，且每个命中项再过一遍 `FileDeleter.isAllowed`。
/// 2. **只读，且只读很小的一点**：只取目录项 + 最多 512 字节做类型嗅探；
///    不整文件读，不跟随指向白名单外的符号链接。
/// 3. **不下结论**：这里只给「线索」。是否采纳要过 `AIScanProposer.judge`
///    那张校验网（系统名 / 保护根 / 活 app 反查 / 记忆豁免 / 必须真实存在）。
enum PathProbe {

    // MARK: - 可搜索的痕迹根目录

    struct Root {
        let path: String
        let category: ArtifactCategory
        /// 给模型看的用途说明，帮它判断该往哪找。
        let holds: String
    }

    /// 可搜索的根目录。基线直接复用 `OrphanScanner.searchDirs`（那份清单是
    /// 逐个目录实测筛过的），再补两处它没覆盖但对「登录态/ 重置」很关键的：
    /// `Cookies`（登录态所在）和 XDG 三个目录（对齐 `SlimMode` 的 `xdgUserData`）。
    ///
    /// **刻意不含 `~/Library/Containers`**，与 `OrphanScanner` 的判断一致：
    /// 递归别人的沙箱容器会触发 macOS「想访问其他 App 的数据」的授权弹窗，
    /// 收益为零、代价是一次弹窗。按具体 app 扫它由 `ContainerScanner` 负责。
    static var roots: [Root] {
        let fromOrphan = OrphanScanner.searchDirs.map { spec in
            Root(path: spec.path, category: spec.category, holds: Self.holdsHint(spec.path))
        }
        let home = NSHomeDirectory()
        let extra: [Root] = [
            Root(path: "\(home)/Library/Cookies", category: .libraryData,
                 holds: L10n.t("Cookie，登录态所在", "cookies / login state")),
            Root(path: "\(home)/.local/share", category: .xdgUserData,
                 holds: L10n.t("XDG 用户数据", "XDG user data")),
            Root(path: "\(home)/.config", category: .xdgUserData,
                 holds: L10n.t("XDG 配置", "XDG config")),
            Root(path: "\(home)/.cache", category: .xdgUserData,
                 holds: L10n.t("XDG 缓存", "XDG cache"))
        ]
        return (fromOrphan + extra).filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private static func holdsHint(_ path: String) -> String {
        let n = (path as NSString).lastPathComponent
        if n.contains("Group Containers") { return L10n.t("App Group 共享容器", "shared app-group container") }
        if n.contains("Application Support") { return L10n.t("配置与本地数据", "config and local data") }
        if n.contains("Caches") { return L10n.t("缓存", "caches") }
        if n.contains("HTTPStorages") { return L10n.t("网络会话", "network sessions") }
        if n.contains("WebKit") { return L10n.t("WebView 数据", "WebView data") }
        if n.contains("Preferences") { return L10n.t("偏好设置", "preferences") }
        if n.contains("LaunchAgents") || n.contains("LaunchDaemons") {
            return L10n.t("开机启动项", "launch agents") }
        if n.contains("Logs") { return L10n.t("日志", "logs") }
        if n.contains("Saved Application State") {
            return L10n.t("窗口状态恢复", "saved window state") }
        if n.contains("Application Scripts") { return L10n.t("app 自带脚本", "app scripts") }
        if n.contains("PrivilegedHelperTools") { return L10n.t("特权助手工具", "privileged helper tools") }
        return L10n.t("应用痕迹", "app traces")
    }

    // MARK: - 按宽 token 枚举

    struct Hit {
        let path: String
        let name: String
        let isDirectory: Bool
        let size: Int64
        let category: ArtifactCategory
        /// 命中它的那个根目录（模型据此判断「这类东西通常是什么」）。
        let root: String
        /// 是否已经在当前清单里——避免把已经报过的东西再提交一遍。
        let alreadyKnown: Bool
    }

    /// 在所有根目录里按**宽 token** 浅层枚举（只列第一层，不递归）。
    ///
    /// 只列第一层是刻意的：这一层几乎全是「目录名 = bundle id / app 名」的形态，
    /// 正是漏项的所在；再往下递归收益骤降，却会触发 TCC 授权弹窗。
    ///
    /// - Parameters:
    ///   - token: 宽泛关键词。**两侧都会去掉 `- _ . 空格` 再比较**，
    ///     所以 `story` 能同时命中 `story-fab` / `StoryFab` / `story_fab`
    ///     ——这正是内置扫描器漏掉 StoryFab 的那个形状。
    ///   - known: 当前清单已有的路径，用来标 `alreadyKnown`。
    static func search(token: String, known: Set<String> = [], limit: Int = 40) -> [Hit] {
        let needle = normalize(token)
        guard needle.count >= 2 else { return [] }
        let fm = FileManager.default
        var out: [Hit] = []

        for root in roots {
            guard let items = try? fm.contentsOfDirectory(
                at: URL(fileURLWithPath: root.path),
                includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for item in items {
                let name = item.lastPathComponent
                guard normalize(name).contains(needle) else { continue }
                let path = item.path
                // 双保险：根目录已在白名单，这里再逐条确认一次。
                guard FileDeleter.isAllowed(path) else { continue }

                let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
                let isDir = values?.isDirectory ?? false
                let size = isDir ? Self.directorySize(item) : Int64(values?.fileSize ?? 0)
                out.append(Hit(path: path, name: name, isDirectory: isDir, size: size,
                               category: root.category, root: root.path,
                               alreadyKnown: known.contains(path)))
                if out.count >= limit { return out.sorted { $0.size > $1.size } }
            }
        }
        return out.sorted { $0.size > $1.size }
    }

    /// 归一化：小写 + 去掉常见分隔符。用于「形状不同但本质同名」的匹配。
    ///
    /// 这是本文件最关键的一行：内置扫描器按 `storyfab` 匹配 `story-fab` 会失败，
    /// 归一化之后 `story` 能同时命中 `story-fab` / `Story_Fab` / `story.fab`。
    static func normalize(_ s: String) -> String {
        s.lowercased().filter { !"-_ .".contains($0) }
    }

    // MARK: - 检查单个路径

    struct Info {
        let path: String
        let exists: Bool
        let isDirectory: Bool
        let size: Int64
        let childCount: Int
        /// 内容类型嗅探结果：崩溃报告 / 数据库 / 配置 / 日志 / 代码 / 二进制 …
        let kind: String
        /// 子项名（最多 10 个），让模型看清这是个什么目录。
        let children: [String]
        /// 归属线索：这个路径看起来属于谁 / 是否被别的活 app 认领。
        let ownerHint: String
        /// 是否被某个**已安装** app 认领。若是，则不该当作目标 app 的残留。
        let claimedByLiveApp: String?
    }

    /// 读取一个路径的归属线索。**只读**：目录项 + 最多 512 字节文件头。
    ///
    /// 不做任何判断（尤其不判断「该不该删」）——结论交给调用方的校验网，
    /// 避免探针自己变成一个「凭直觉删东西」的入口。
    ///
    /// - Parameter target: 目标 app。**必须排除**它在活 app 反查里的身份：
    ///   它当然「拥有」自己的数据目录，而那正是我们要找的东西（StoryFab 的
    ///   `Application Support/story-fab` 会被「StoryFab 认领」）。不排除的话，
    ///   agent 会把最该上报的那一项当成「别人的」丢掉。
        static func inspect(_ rawPath: String, excluding target: AppIdentity? = nil) -> Info {
        let fm = FileManager.default
        let path = (rawPath as NSString).expandingTildeInPath
        let std = (path as NSString).standardizingPath
        let exists = fm.fileExists(atPath: std)
        var isDir = false
        var size: Int64 = 0
        var children: [String] = []
        var childCount = 0

        if exists {
            var isDirFlag = ObjCBool(false)
            if fm.fileExists(atPath: std, isDirectory: &isDirFlag) { isDir = isDirFlag.boolValue }
            size = isDir ? directorySize(URL(fileURLWithPath: std)) : fileSize(std)
            if isDir {
                if let items = try? fm.contentsOfDirectory(atPath: std) {
                    childCount = items.count
                    children = Array(items.sorted().prefix(10))
                }
            }
        }

        let claimed = liveAppClaiming(std, excluding: target)
        let hint = ownerHint(path: std, isDirectory: isDir, claimed: claimed)
        return Info(path: std, exists: exists, isDirectory: isDir, size: size,
                    childCount: childCount, kind: sniff(std, isDirectory: isDir),
                    children: children, ownerHint: hint, claimedByLiveApp: claimed)
    }

    /// 文件类型嗅探。**只看扩展名 + 极短文件头**，不整文件读。
    private static func sniff(_ path: String, isDirectory: Bool) -> String {
        if isDirectory {
            let lower = path.lowercased()
            if lower.contains("/crashes") || lower.hasSuffix("/crash") {
                return L10n.t("崩溃报告目录", "crash-report directory") }
            if lower.contains("/logs") || lower.contains("/log") { return L10n.t("日志目录", "log directory") }
            return L10n.t("目录", "directory")
        }
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "plist": return "plist 配置"
        case "json":  return "JSON"
        case "sqlite", "db", "sqlite3": return "SQLite 数据库"
        case "log":   return "日志"
        case "cookie", "binarycookies": return L10n.t("Cookie（登录态）", "cookies (login state)")
        case "sock":  return L10n.t("套接字", "socket")
        case "png", "jpg", "jpeg", "gif", "webp": return "图片"
        default: break
        }
        // 二进制不看内容，只报个大概；文本类读一小段头部帮助模型判断。
        guard let head = readHead(path, 512), let text = String(data: head, encoding: .utf8) else {
            return L10n.t("二进制或未知类型", "binary or unknown")
        }
        let t = text.lowercased()
        if t.contains("crash") || t.contains("backtrace") || t.contains("exception") {
            return L10n.t("崩溃报告（文本）", "crash report (text)")
        }
        if t.contains("{") || t.contains("[") { return "JSON/结构化文本" }
        return L10n.t("文本", "text")
    }

    /// 这个路径看起来属于哪个**已安装** app（用活 app 的 bundle id / 名字反查）。
    ///
    /// 命中即意味着「别把它当成目标 app 的残留」——这是防误删最强的一条线索，
    /// 也是 agent 调查时最容易自己骗自己的地方（模型分不清
    /// `Application Support/Google/Chrome` 属于谁，已装 app 清单知道）。
    ///
    /// **目标 app 必须整体排除**（`excluding`）：它当然「拥有」自己的数据目录，
    /// 而那正是我们要找的东西。做法与 `AIScanProposer.Context.build` 同源 ——
    /// 按 app 逐个重建「别人」的 id / 名字集合，而不是用「全机活 app」的全局集合：
    /// 后者**包含目标自身**，会把 `Application Support/story-fab` 判成
    /// 「StoryFab 认领」，于是 agent 把最该上报的一项当成别人的东西丢掉。
    private static func liveAppClaiming(_ path: String, excluding target: AppIdentity?) -> String? {
        let raw = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        guard !raw.isEmpty else { return nil }
        let lower = raw.lowercased()

        let all = InventoryCache.shared.allApps()
        var ids: Set<String> = []
        var names: Set<String> = []
        for a in all where a.bundlePath != target?.bundlePath {
            names.formUnion(a.aliases)
            names.insert(a.fileName.lowercased())
            names.insert(a.displayName.lowercased())
            names.insert(a.fileName.lowercased().replacingOccurrences(of: " ", with: ""))
            names.insert(a.displayName.lowercased().replacingOccurrences(of: " ", with: ""))
            if let suffix = a.bundleIdSuffix { names.insert(suffix) }
            if let bid = a.bundleId { ids.insert(bid.lowercased()) }
            // 包内嵌套 helper（Electron / Tauri 的一堆 .helper）也要算成「活着的」，
            // 否则目标 app 自己的 helper 容器会显得无主。
            ids.formUnion(AppInventory.nestedBundleIds(
                in: URL(fileURLWithPath: a.bundlePath).standardizedFileURL))
        }
        names = names.filter { !$0.isEmpty }

        if lower.contains("."), OrphanScanner.isClaimed(lower, live: ids) { return lower }
        let stripped = OrphanScanner.stripPrefixes(lower)
        if ids.contains(stripped) { return stripped }
        // 名字匹配与 AIScanProposer 同规则：短词（≤3 字符）不参与双向子串，
        // 否则 "ai"、"code" 这类会到处误伤。
        if names.contains(lower) { return lower }
        for other in names where other.count >= 4 {
            if lower.contains(other) || other.contains(lower) { return lower }
        }
        return nil
    }

    private static func ownerHint(path: String, isDirectory: Bool, claimed: String?) -> String {
        var parts: [String] = []
        if let c = claimed {
            parts.append(L10n.t("被已安装应用认领：\(c) —— 不应作为残留删除",
                                "Claimed by an installed app: \(c) — not leftover for this target"))
        } else {
            parts.append(L10n.t("没有已安装应用认领它（可能确实是残留，也可能归属别的未装软件）",
                                "No installed app claims it (may be a real leftover, or owned by something not installed)"))
        }
        if SystemOwned.isSystemOwned((path as NSString).lastPathComponent) {
            parts.append(L10n.t("名字像系统/框架自有数据", "name looks system/framework-owned"))
        }
        parts.append(isDirectory ? L10n.t("是目录", "is a directory") : L10n.t("是文件", "is a file"))
        return parts.joined(separator: "；")
    }

    // MARK: - 小工具

    private static func readHead(_ path: String, _ bytes: Int) -> Data? {
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }
        return (try? fh.read(upToCount: bytes)) ?? nil
    }

    private static func fileSize(_ path: String) -> Int64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
    }

    private static func directorySize(_ url: URL) -> Int64 {
        (try? url.directorySize()) ?? 0
    }
}