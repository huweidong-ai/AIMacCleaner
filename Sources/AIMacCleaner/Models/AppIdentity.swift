import Foundation

/// 已安装 app 的身份信息：一个 app 在磁盘上叫什么、在界面上叫什么、bundle id 是什么。
///
/// 存在的理由：用户搜「微信」时，磁盘上的目录叫 `WeChat.app`，「微信」三个字只出现在
/// `Contents/Resources/zh-Hans.lproj/InfoPlist.strings` 里。只比对文件名必然漏掉它。
struct AppIdentity: Identifiable, Hashable {
    var id: String { bundlePath }

    /// .app 的绝对路径
    let bundlePath: String
    /// 磁盘上的文件名（不含 .app 后缀），如 "WeChat"
    let fileName: String
    /// 界面显示名，优先本地化，如 "微信"
    let displayName: String
    /// bundle id，如 "com.tencent.xinWeChat"
    let bundleId: String?
    /// 版本号
    let version: String?
    /// 所有已知别名（小写去重）：文件名、各语言显示名、可执行文件名、bundle id 末段
    let aliases: Set<String>

    /// bundle id 的末段，如 com.tencent.xinWeChat → xinwechat。
    /// 末段是通用词（`com.aicleaner.app` → `app`）或过短时返回 nil —— 那种词
    /// 下发给扫描器会命中大量无关目录，见 `genericBundleSuffixes`。
    var bundleIdSuffix: String? {
        guard let suffix = bundleId?.split(separator: ".").last.map({ $0.lowercased() }),
              suffix.count >= 4,
              !AppIdentity.genericBundleSuffixes.contains(suffix)
        else { return nil }
        return suffix
    }

    /// 是否为 Chrome / Edge 通过「安装到磁盘」生成的 PWA 快捷方式 app。
    ///
    /// 这类 app 本质是个浏览器外壳（`app_mode_loader`），真正的偏好/登录态在
    /// `~/Library/Preferences/com.google.Chrome.app.<hash>.plist` 里。光删 .app
    /// 会留下无主残留，所以卸载时要当成「一个整体」连带清掉那份配置。
    ///
    /// 识别逻辑：先看 bundleId 前缀；很多 PWA（尤其企业/签名分发）会把 bundleId
    /// 改成 `com.citrolabs.ego.lite.app.<hash>` 之类，但安装目录仍是
    /// `Chrome Apps.localized` 或 `Edge Apps.localized`，所以用路径兜底。
    var isPWA: Bool {
        if let bid = bundleId?.lowercased() {
            if bid.hasPrefix("com.google.chrome.app.") ||
               bid.hasPrefix("com.microsoft.edgemac.app.") {
                return true
            }
        }
        let pathLower = bundlePath.lowercased()
        return pathLower.contains("/chrome apps.localized/") ||
               pathLower.contains("/edge apps.localized/")
    }

    /// bundle id 末段里不能当别名的通用词。这些词作为关键词下发会命中大量
    /// 无关目录（`app` 会匹配整个 `Application Support`：实测 556 项 / 34 GB，
    /// 含一个 458 MB 的无关 app 数据目录和一堆 com.apple.*）。foreignKeywords 防不住 ——
    /// 那些目录不属于任何已装 app。
    static let genericBundleSuffixes: Set<String> = [
        "app", "mac", "macos", "osx", "desktop", "client", "helper", "agent",
        "service", "tool", "utility", "framework", "bundle", "extension",
        "main", "core", "gui", "pro", "lite", "free", "beta"
    ]
}

/// 枚举已安装的 app，并读出它们的全部别名。
enum AppInventory {

    /// 一个搜索路径 + 它的递归深度。
    ///
    /// **深度必须逐目录设，不能一刀切。** 真机实测：
    /// - `~/Applications` 递归到 2 层才能看见 `Chrome Apps.localized/` 里的
    ///   9 个 Chrome PWA 快捷方式（平铺只看到 1 个），那些是真能卸载的东西。
    /// - `/Library/Application Support` 递归到 4 层只会翻出 Apple 自带的
    ///   Script Editor **模板**（`Cocoa-AppleScript Applet.app` 等 4 个）——
    ///   把模板列成「可卸载的 app」是倒退，所以它保持深度 1。
    struct SearchPath {
        let path: String
        /// 1 = 只看当前目录（平铺）。
        let maxDepth: Int
    }

    static let searchPaths: [SearchPath] = [
        SearchPath(path: "/Applications", maxDepth: 3),
        // Chrome/Edge 装 PWA 到 ~/Applications/Chrome Apps.localized/
        SearchPath(path: "\(NSHomeDirectory())/Applications", maxDepth: 2),
        SearchPath(path: "/System/Applications", maxDepth: 2),
        SearchPath(path: "/Applications/Utilities", maxDepth: 1),
        SearchPath(path: "/System/Applications/Utilities", maxDepth: 1),
        // 输入法装在这里。漏掉它会让 WeType 的容器
        // (com.tencent.inputmethod.wetype.FinderSync) 被判成孤儿。
        SearchPath(path: "/Library/Input Methods", maxDepth: 1),
        SearchPath(path: "\(NSHomeDirectory())/Library/Input Methods", maxDepth: 1),
        // 部分 app（尤其是带后台组件的）把辅助 app 放在这里。
        // **保持 1** —— 递归它只会翻出 Script Editor 模板，见上面的注释。
        SearchPath(path: "/Library/Application Support", maxDepth: 1),
        SearchPath(path: "/Library/PreferencePanes", maxDepth: 1),
        SearchPath(path: "\(NSHomeDirectory())/Library/PreferencePanes", maxDepth: 1)
    ]

    /// 列出 `dir` 下的 `.app`，递归到 `maxDepth` 层。
    ///
    /// 两个必须有的约束：
    /// - `.skipsPackageDescendants` + 命中后 `skipDescendants()`：绝不进入
    ///   bundle 内部，否则会把 app 自带的 XPC service / helper
    ///   （`…/Contents/Library/…/Helper.app`）列成独立 app。
    /// - `maxDepth` 兜底：`/Library/Application Support` 这类目录可能极深，
    ///   无界递归会让「读取已装 app」卡住。
    static func appBundles(in dir: String, maxDepth: Int) -> [URL] {
        let url = URL(fileURLWithPath: dir)
        guard let e = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var found: [URL] = []
        while let item = e.nextObject() as? URL {
            // enumerator.level：直接子项 = 1
            if e.level >= maxDepth { e.skipDescendants() }
            if item.pathExtension == "app" {
                found.append(item)
                e.skipDescendants()
            }
        }
        return found
    }

    /// 从 Info.plist / lproj 里提取名字的 key
    private static let nameKeys = ["CFBundleDisplayName", "CFBundleName", "CFBundleExecutable"]

    /// 列出所有已安装 app。`includeSystem` 为 false 时跳过 /System（系统自带 app 不该被卸载）。
    static func allApps(includeSystem: Bool = false) -> [AppIdentity] {
        var results: [AppIdentity] = []
        var seenPaths = Set<String>()

        for spec in searchPaths {
            if !includeSystem && spec.path.hasPrefix("/System") { continue }
            for item in appBundles(in: spec.path, maxDepth: spec.maxDepth) {
                let path = item.standardizedFileURL.path
                guard seenPaths.insert(path).inserted else { continue }
                if let identity = identity(forBundleAt: item) {
                    results.append(identity)
                }
            }
        }
        return results.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    /// 读取单个 .app 的身份信息。
    static func identity(forBundleAt url: URL) -> AppIdentity? {
        let fileName = url.deletingPathExtension().lastPathComponent
        var aliases = Set<String>([fileName.lowercased()])

        let infoURL = url.appendingPathComponent("Contents/Info.plist")
        let info = NSDictionary(contentsOf: infoURL) as? [String: Any] ?? [:]

        // 基础名字
        for key in nameKeys {
            if let v = info[key] as? String, !v.isEmpty {
                aliases.insert(v.lowercased())
            }
        }

        let bundleId = info["CFBundleIdentifier"] as? String
        let version = (info["CFBundleShortVersionString"] as? String)
            ?? (info["CFBundleVersion"] as? String)

        // bundle id 整体和末段都算别名：搜 "xinWeChat" 或完整 id 都能命中
        if let bid = bundleId, !bid.isEmpty {
            aliases.insert(bid.lowercased())
            // 末段是通用词时**不能**收作别名。`com.aicleaner.app` 的末段是 "app"，
            // 下发给扫描器后 `~/Library/Application Support` 下几乎每个目录都会命中
            // （实测 556 项 / 34 GB，含一个 458 MB 的无关 app 数据目录和一堆 com.apple.*）。
            // foreignKeywords 防不住这个 —— 那些目录不属于任何已装 app。
            if let last = bid.split(separator: ".").last {
                let suffix = String(last).lowercased()
                if !AppIdentity.genericBundleSuffixes.contains(suffix) && suffix.count >= 4 {
                    aliases.insert(suffix)
                }
            }
        }

        // 关键一步：扫所有 *.lproj/InfoPlist.strings 拿本地化名。
        // 「微信」只存在于这里，Info.plist 里是 "WeChat"。
        let localizedNames = localizedDisplayNames(in: url)
        for n in localizedNames { aliases.insert(n.lowercased()) }

        // 显示名优先级：当前语言的本地化名 > CFBundleDisplayName > CFBundleName > 文件名
        let displayName = preferredLocalizedName(in: url)
            ?? (info["CFBundleDisplayName"] as? String)
            ?? (info["CFBundleName"] as? String)
            ?? fileName

        aliases.insert(displayName.lowercased())
        aliases = Set(aliases.filter { !$0.isEmpty })

        return AppIdentity(
            bundlePath: url.standardizedFileURL.path,
            fileName: fileName,
            displayName: displayName,
            bundleId: bundleId,
            version: version,
            aliases: aliases
        )
    }

    /// 收集所有语言的显示名。
    static func localizedDisplayNames(in bundleURL: URL) -> Set<String> {
        var names = Set<String>()
        let resources = bundleURL.appendingPathComponent("Contents/Resources")
        guard let subs = try? FileManager.default.contentsOfDirectory(atPath: resources.path) else {
            return names
        }
        for sub in subs where sub.hasSuffix(".lproj") {
            let strings = resources.appendingPathComponent(sub).appendingPathComponent("InfoPlist.strings")
            guard let dict = NSDictionary(contentsOf: strings) as? [String: Any] else { continue }
            for key in ["CFBundleDisplayName", "CFBundleName"] {
                if let v = dict[key] as? String, !v.isEmpty { names.insert(v) }
            }
        }
        return names
    }

    /// 取当前系统语言对应的显示名（中文系统下拿到「微信」）。
    private static func preferredLocalizedName(in bundleURL: URL) -> String? {
        let resources = bundleURL.appendingPathComponent("Contents/Resources")
        // 按用户偏好语言顺序找，zh-Hans 和 zh_CN 两种写法都要试
        var candidates: [String] = []
        for lang in Locale.preferredLanguages {
            let base = lang.replacingOccurrences(of: "-", with: "_")
            candidates.append(lang)                 // zh-Hans
            candidates.append(base)                 // zh_Hans
            if let primary = lang.split(separator: "-").first {
                candidates.append(String(primary))  // zh
            }
            if lang.hasPrefix("zh-Hans") || lang.hasPrefix("zh_Hans") {
                candidates.append("zh_CN")
                candidates.append("zh-Hans")
            }
            if lang.hasPrefix("zh-Hant") || lang.hasPrefix("zh_Hant") {
                candidates.append("zh_TW")
                candidates.append("zh-Hant")
            }
        }
        for cand in candidates {
            let strings = resources
                .appendingPathComponent("\(cand).lproj")
                .appendingPathComponent("InfoPlist.strings")
            guard let dict = NSDictionary(contentsOf: strings) as? [String: Any] else { continue }
            if let v = (dict["CFBundleDisplayName"] as? String) ?? (dict["CFBundleName"] as? String),
               !v.isEmpty {
                return v
            }
        }
        return nil
    }

    /// 按关键词搜索已安装 app，返回按相关度排序的结果。
    /// 「微信」→ WeChat.app 排在 wechatwebdevtools.app 前面（精确别名命中优于子串命中）。
    static func search(_ query: String, in apps: [AppIdentity]? = nil) -> [AppIdentity] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return [] }
        let pool = apps ?? allApps()

        var scored: [(AppIdentity, Int)] = []
        for app in pool {
            if let s = MatchScore.score(query: q, aliases: app.aliases) {
                scored.append((app, s))
            }
        }
        // 分数高的在前；同分按显示名字典序，保证输出稳定
        return scored
            .sorted {
                $0.1 != $1.1 ? $0.1 > $1.1
                    : $0.0.displayName.localizedCaseInsensitiveCompare($1.0.displayName) == .orderedAscending
            }
            .map(\.0)
    }

    // MARK: - 活 bundle id 全集（孤儿判定用）

    /// 一个 .app 内部**所有**嵌套的 bundle id，含 XPC service、扩展、helper、框架。
    ///
    /// 这是孤儿扫描不能出错的地方：真机上顶层只有 28 个 bundle id，
    /// 递归后有 880 个。只比顶层会把 `com.tencent.xinWeChat.WeChatMacShare`、
    /// `com.kingsoft.wpsoffice.mac.FinderSync`、`org.localsend.localsendApp.ShareExtension`
    /// 这类**活着的** app 数据判成孤儿 —— 实测 18 个容器里误判 12 个。
    static func nestedBundleIds(in bundleURL: URL) -> Set<String> {
        var ids = Set<String>()
        guard let walker = FileManager.default.enumerator(
            at: bundleURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return ids }

        for case let url as URL in walker where url.lastPathComponent == "Info.plist" {
            guard let dict = NSDictionary(contentsOf: url) as? [String: Any],
                  let bid = dict["CFBundleIdentifier"] as? String,
                  !bid.isEmpty else { continue }
            ids.insert(bid.lowercased())
        }
        return ids
    }

    /// 全机器「活着的」bundle id 全集（含所有嵌套组件）。
    ///
    /// 扫描范围比 `allApps()` 宽：包含 /System 下的系统 app，因为判断
    /// 「某个容器是否有主人」时，系统 app 也算主人。
    static func liveBundleIds() -> Set<String> {
        var ids = Set<String>()
        for app in allApps(includeSystem: true) {
            if let bid = app.bundleId?.lowercased() { ids.insert(bid) }
            ids.formUnion(nestedBundleIds(in: URL(fileURLWithPath: app.bundlePath)))
        }
        return ids
    }

    /// 活 app 的「名字类」别名全集，用于名字形状目录的认领判断。
    static func liveNameAliases() -> Set<String> {
        var names = Set<String>()
        for app in allApps(includeSystem: true) {
            names.formUnion(app.aliases)
            // 去空格紧凑写法
            for n in [app.fileName.lowercased(), app.displayName.lowercased()] {
                names.insert(n.replacingOccurrences(of: " ", with: ""))
            }
            if let suffix = app.bundleIdSuffix { names.insert(suffix) }
        }
        return names.filter { !$0.isEmpty }
    }
}

/// 别名匹配打分。分数越高越相关。
enum MatchScore {
    static let exact       = 100
    static let prefix      = 70
    static let wordPrefix  = 50
    static let substring   = 30

    /// 返回 nil 表示不匹配。
    static func score(query: String, aliases: Set<String>) -> Int? {
        var best: Int? = nil
        for alias in aliases {
            guard let s = score(query: query, alias: alias) else { continue }
            if best == nil || s > best! { best = s }
        }
        return best
    }

    static func score(query: String, alias: String) -> Int? {
        if alias == query { return exact }
        if alias.hasPrefix(query) { return prefix }
        // 「微信」应该能命中「微信开发者工具」，但得分低于精确的「微信」
        if isWordPrefix(query: query, in: alias) { return wordPrefix }
        if alias.contains(query) { return substring }
        return nil
    }

    /// query 是否出现在 alias 的某个「词」开头（按空格/连字符/下划线切词）。
    private static func isWordPrefix(query: String, in alias: String) -> Bool {
        let separators = CharacterSet(charactersIn: " -_.")
        for part in alias.components(separatedBy: separators) where !part.isEmpty {
            if part.hasPrefix(query) { return true }
        }
        return false
    }
}
