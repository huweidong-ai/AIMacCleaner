import Foundation

// 孤儿分组的数据结构已并入 `LeftoverGroup`（见 Models/LeftoverSource.swift），
// 这里产出 `source == .orphan` 的分组，和 AI 工具残留共用「残留」页。

/// 反向扫描：找出「主 app 已经不在了、痕迹还留着」的目录。
///
/// 和其他 14 个扫描器方向相反 —— 它们接受一个 target 找痕迹，
/// 这个是遍历痕迹目录、反查有没有活着的 app 认领。
/// 存在的理由：用户没法搜一个自己已经忘掉的 app 名，所以那部分残留永远扫不到。
///
/// **判定策略是刻意保守的**（真机 dry-run 验证过）：
///  1. 优先判定 bundle-id 形状的目录（含 `.`），靠双向前缀匹配认领。
///  2. 纯名字目录（不含点，如 `TabNine`、`aiXcoder`、`yuque-desktop`、`阿里云盘`）
///     走兜底分支：过「共享厂商白名单」+「活 app 名称反查」（`isOrphanByName`）。
///     这样能揪出卸载后留下的纯单词目录，又不会把 `JetBrains`/`Google` 这类
///     被多个活 app 共用的厂商根目录误判成孤儿。
///  3. 过 `SystemOwned` 白名单。
///  4. 双向前缀匹配：容器名可能是活 app 的**后代**（`com.foo.bar.Ext` ← `com.foo.bar`）
///     也可能是**祖先**（`UBF8T346G9.com.microsoft.rdc` ← `com.microsoft.rdc.macos`）。
///  5. 结果全部 `.userData` 风险、默认不勾选 —— 启发式判定不该默认删。
enum OrphanScanner {

    struct DirSpec {
        let path: String
        let category: ArtifactCategory
        /// 只看 bundle-id 形状（含点）的条目？LaunchAgents 里的 plist 一律是 id 形状。
        let requiresDotted: Bool
        /// 去掉的文件后缀（Preferences/LaunchAgents 是 .plist）
        let stripSuffix: String?
        /// 只认目录？
        ///
        /// Containers / Application Support / Caches 里的 app 痕迹一定是目录；
        /// 散落的**文件**（`WPS_Office_7.3.0.7z`、`AAProfilePicture_xxx.png`、
        /// `com.ebus.lark.nf_ipc.sock`）是别的东西写下的临时产物，
        /// 名字里的「点」是扩展名而不是 bundle id 分段，按 app 反查必然无主。
        /// Preferences / LaunchAgents 相反 —— 那里的痕迹本身就是 .plist 文件。
        let requiresDirectory: Bool
    }

    static var searchDirs: [DirSpec] {
        let home = NSHomeDirectory()
        return [
            // 注意：这里**故意不含** ~/Library/Containers。
            // 真机 dry-run 显示它的孤儿产出为 0（容器名就是 bundle id，里面剩下的
            // 全是活 app 的扩展/XPC 容器），而递归它会触发 macOS 的
            // 「想访问其他 App 的数据」授权弹窗 —— 收益为零、代价是一个弹窗。
            // 按具体 app 扫容器由「扫描」页的 ContainerScanner 负责。
            //
            // Group Containers 保留：实测最大的一笔真孤儿（某清理工具 2.5 MB）
            // 就在这里，值得那次授权。
            DirSpec(path: "\(home)/Library/Group Containers",
                    category: .groupContainer, requiresDotted: true,
                    stripSuffix: nil, requiresDirectory: true),
            DirSpec(path: "\(home)/Library/Application Support",
                    category: .libraryData, requiresDotted: true,
                    stripSuffix: nil, requiresDirectory: true),
            DirSpec(path: "\(home)/Library/Caches",
                    category: .libraryData, requiresDotted: true,
                    stripSuffix: nil, requiresDirectory: true),
            // v1.3 新增。发现过程：MacSai 扫 17 个 Library 子目录、我们只扫 5 个，
            // 逐个核对后在 HTTPStorages 里找到一个早已卸载的 CLI 工具的残留 ——
            // 上一轮 `--orphans` 还报告「未发现孤儿」，
            // 因为这个目录根本没在扫描范围里。
            //
            // 这三个都用 bundle id 当目录名（`com.example.some-tool`、
            // `vendor.SomeApp`），正好符合 requiresDotted + requiresDirectory
            // 的判定前提。Application Scripts 里混着大量 UUID 目录和
            // `$(AppIdentifierPrefix)` 字面量，靠 requiresDotted 挡掉。
            DirSpec(path: "\(home)/Library/HTTPStorages",
                    category: .libraryData, requiresDotted: true,
                    stripSuffix: nil, requiresDirectory: true),
            DirSpec(path: "\(home)/Library/WebKit",
                    category: .libraryData, requiresDotted: true,
                    stripSuffix: nil, requiresDirectory: true),
            DirSpec(path: "\(home)/Library/Application Scripts",
                    category: .libraryData, requiresDotted: true,
                    stripSuffix: nil, requiresDirectory: true),
            DirSpec(path: "\(home)/Library/Preferences",
                    category: .libraryData, requiresDotted: true,
                    stripSuffix: ".plist", requiresDirectory: false),
            DirSpec(path: "\(home)/Library/LaunchAgents",
                    category: .launchAgent, requiresDotted: true,
                    stripSuffix: ".plist", requiresDirectory: false),
            DirSpec(path: "/Library/LaunchAgents",
                    category: .launchAgent, requiresDotted: true,
                    stripSuffix: ".plist", requiresDirectory: false),
            DirSpec(path: "/Library/LaunchDaemons",
                    category: .launchAgent, requiresDotted: true,
                    stripSuffix: ".plist", requiresDirectory: false),

            // P0-2：扩展反向扫描范围，与 Pearcleaner `Locations` 对齐的系统级残留目录。
            // 这些都是「app 装过、卸载后留下的散落痕迹」的高发地。
            // 注意：`/usr/local` 与 `/private/tmp` 刻意不加 —— 前者被 Homebrew 全量占用、
            // 递归扫会大规模误报兼危险；后者易失且被其他进程占用。Pearcleaner 对这两处
            // 也是按具体子路径精确扫，而非递归整个目录。
            DirSpec(path: "\(home)/Library/Saved Application State",
                    category: .libraryData, requiresDotted: true, stripSuffix: nil, requiresDirectory: true),
            DirSpec(path: "\(home)/Library/Logs",
                    category: .libraryData, requiresDotted: true, stripSuffix: nil, requiresDirectory: true),
            DirSpec(path: "\(home)/Library/Metadata",
                    category: .libraryData, requiresDotted: true, stripSuffix: nil, requiresDirectory: true),
            DirSpec(path: "/Library/Application Support",
                    category: .libraryData, requiresDotted: true, stripSuffix: nil, requiresDirectory: true),
            DirSpec(path: "/Library/Caches",
                    category: .libraryData, requiresDotted: true, stripSuffix: nil, requiresDirectory: true),
            DirSpec(path: "/Library/Logs",
                    category: .libraryData, requiresDotted: true, stripSuffix: nil, requiresDirectory: true),
            DirSpec(path: "/Library/PrivilegedHelperTools",
                    category: .libraryData, requiresDotted: true, stripSuffix: nil, requiresDirectory: false),
            DirSpec(path: "/Library/Preferences",
                    category: .libraryData, requiresDotted: true, stripSuffix: ".plist", requiresDirectory: false)
        ]
    }

    /// 扫描全盘孤儿痕迹，按推断归属者聚合。
    ///
    /// `keepPaths` = 用户通过 `/remember` 记下的豁免路径。传 nil 走
    /// `MemoryStore` 现读（GUI 与 CLI 都自动生效），传空集 = 关掉豁免（自检用）。
    /// 这是本扫描器**唯一**由用户直接控制的判定，其余全是启发式。
    static func scanAll(liveIds: Set<String>? = nil,
                        liveNames: Set<String>? = nil,
                        keepPaths: Set<String>? = nil) async -> [LeftoverGroup] {
        let live = liveIds ?? AppInventory.liveBundleIds()
        let names = liveNames ?? AppInventory.liveNameAliases()
        // 读一次就够。别挪进循环 —— 那是一次读盘 + 一次解码。
        let exempt = keepPaths ?? MemoryStore.shared.keepPaths()
        var groups: [String: LeftoverGroup] = [:]

        for spec in searchDirs {
            let url = URL(fileURLWithPath: spec.path)
            guard let contents = try? FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for item in contents {
                var name = item.lastPathComponent
                if let suffix = spec.stripSuffix, name.hasSuffix(suffix) {
                    name = String(name.dropLast(suffix.count))
                }

                let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                // 该目录下的 app 痕迹必须是目录时，跳过散落文件
                if spec.requiresDirectory && !isDir { continue }

                // 同 ContainerScanner：容器空壳删不掉又消不掉，报出来只会
                // 让用户在「删除 → 成功 → 还在」之间打转。
                if spec.category == .groupContainer || spec.category == .container {
                    if ContainerScanner.isEmptyShell(item) { continue }
                }

                let orphan: Bool
                if spec.category == .launchAgent {
                    // launch agent 有比名字匹配强得多的信号：它自己写明了要跑哪个程序。
                    // 程序不在了就是死的 —— 不管名字长什么样。
                    // 真机案例：`ai.lark-channel-bridge.bot.claude` 名字对不上任何 app，
                    // 但它引用的 /opt/homebrew/bin/lark-channel-bridge 确实没了（真孤儿）；
                    // 而 `homebrew.mxcl.redis` 同样对不上 app，但 redis-server 还在（不是孤儿）。
                    orphan = isDeadLaunchAgent(item)
                } else {
                    orphan = isOrphan(name, live: live, liveNames: names, requiresDotted: spec.requiresDotted)
                }
                guard orphan else { continue }

                // 用户说过「这个别动」就真的不再报它。放在 orphan 判定**之后**：
                // 豁免名单通常只有几条，而这里已经把候选收敛到极少数，
                // 顺带省掉下面那次 `directorySize()`（递归读盘，是本函数最贵的一步）。
                if MemoryPolicy.isExempt(item.path, keepPaths: exempt) { continue }

                let size: Int64 = isDir
                    ? ((try? item.directorySize()) ?? 0)
                    : Int64((try? item.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)

                let owner = inferOwner(name)
                let artifact = Artifact(
                    category: spec.category,
                    path: item.path,
                    size: size,
                    // 孤儿判定是启发式的，一律按用户数据对待、默认不勾选
                    risk: .userData,
                    meta: "孤儿痕迹 · 无对应已装 app",
                    selected: false
                )
                if groups[owner] != nil {
                    groups[owner]!.artifacts.append(artifact)
                } else {
                    groups[owner] = LeftoverGroup(owner: owner, source: .orphan, artifacts: [artifact])
                }
            }
        }

        return groups.values
            .sorted { $0.totalSize != $1.totalSize ? $0.totalSize > $1.totalSize : $0.owner < $1.owner }
    }

    // MARK: - 判定

    /// launch agent 引用的程序还在吗？
    ///
    /// 比名字匹配可靠得多：plist 自己写明了 `Program` / `ProgramArguments`。
    /// 注意要检查**所有**绝对路径参数，不能只看第一个 ——
    /// `ai.lark-channel-bridge` 的第 0 个参数是 node（在），
    /// 真正没了的是第 1 个参数那个脚本。
    static func isDeadLaunchAgent(_ plistURL: URL) -> Bool {
        guard let dict = NSDictionary(contentsOf: plistURL) as? [String: Any] else {
            return false   // 读不出来就不猜
        }

        var absolutePaths: [String] = []
        if let program = dict["Program"] as? String, program.hasPrefix("/") {
            absolutePaths.append(program)
        }
        if let args = dict["ProgramArguments"] as? [String] {
            absolutePaths.append(contentsOf: args.filter { $0.hasPrefix("/") })
        }
        // 没有任何绝对路径可判 → 不猜，交给保守路径（不判孤儿）
        guard !absolutePaths.isEmpty else { return false }

        // 任意一个被引用的绝对路径消失，这个 agent 就跑不起来了
        return absolutePaths.contains { !FileManager.default.fileExists(atPath: $0) }
    }

    /// 这个目录名是孤儿吗？
    static func isOrphan(_ rawName: String, live: Set<String>,
                         liveNames: Set<String> = [],
                         requiresDotted: Bool = true) -> Bool {
        let name = rawName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return false }

        // 噪声 / 系统数据一律不判
        if SystemOwned.isSystemOwned(name) { return false }

        let normalized = stripPrefixes(name).lowercased()
        guard !normalized.isEmpty else { return false }

        // 剥完前缀后再查一次白名单：group.com.apple.mail → com.apple.mail
        if SystemOwned.isSystemOwned(normalized) { return false }

        // 只判 bundle-id 形状。纯名字目录默认不判（见类型注释），
        // 但用「共享厂商白名单 + 活 app 名称反查」兜底，能揪出卸载后留下的
        // 纯单词目录（如 TabNine / aiXcoder / yuque-desktop / 阿里云盘）。
        if requiresDotted && !normalized.contains(".") {
            return isOrphanByName(normalized, liveNames: liveNames)
        }

        // 至少要有两段，避免把 "lv"、"ve" 这种残缺名当成 id
        guard normalized.split(separator: ".").count >= 2 else { return false }

        return !isClaimed(normalized, live: live)
    }

    /// 纯名字目录（不含点）是否为孤儿。
    ///
    /// 设计取舍：bundle-id 形状靠前缀匹配就够稳，但纯名字目录（JetBrains、Google）
    /// 和活 app 名往往不是一个词，盲目按名字匹配会把**正在用的 app 数据**判成孤儿。
    /// 这里用两道闸：
    ///  1. 共享厂商根目录（jetbrains/google/microsoft/...）一律不判 —— 宁可漏报，
    ///     因为这类目录常被同厂商多个活 app 共用。
    ///  2. 任何活 app 的显示名 / 别名 / bundle 末段包含这个名字（或其去后缀形态）
    ///     就不判。名字数据来自 `AppInventory.liveNameAliases()`。
    ///
    /// 真机案例：TabNine(243M) / aiXcoder(64M) / yuque-desktop(224M) / 阿里云盘(320K)
    /// 都是卸载后留下的纯名字目录，此前因不含点被完全跳过。
    private static func isOrphanByName(_ normalized: String, liveNames: Set<String>) -> Bool {
        guard !SystemOwned.isSystemOwned(normalized) else { return false }
        // 没有活 app 名字数据时不判纯名字目录：无法区分「已卸 app 残留」与
        // 「装着但目录名对不上 app 名的活 app 数据」，宁可漏报。真实扫描里
        // liveNames 来自 AppInventory.liveNameAliases()，非空才启用反查。
        guard !liveNames.isEmpty else { return false }

        // 闸 1：共享厂商根目录
        if let head = normalized.split(separator: ".").first.map(String.init),
           sharedVendorRoots.contains(head) {
            return false
        }

        // 去常见后缀再比，避免 yuque-desktop vs Yuque 匹配不上
        let base = normalized
            .replacingOccurrences(of: "-desktop", with: "")
            .replacingOccurrences(of: "-app", with: "")
            .replacingOccurrences(of: "-mac", with: "")
            .replacingOccurrences(of: "-osx", with: "")
        // P0-3：再去尾部版本号（"appname-1.2.3" / "appname-2024"），否则带版本的
        // 残留目录名匹配不上活 app 显示名。
        let baseNoVer = Self.stripTrailingVersion(base)

        // 闸 2：活 app 认领（精确 + 去后缀 + 去版本），认领了就不是孤儿
        if liveNames.contains(normalized)
            || (base != normalized && liveNames.contains(base))
            || (baseNoVer != base && liveNames.contains(baseNoVer)) {
            return false
        }
        // 双向子串兜底：目录名是 app 名的子串，或反过来。
        // 只在较长一侧 ≥4 时才当作认领信号，免得 "code" 这类短词到处匹配。
        for n in liveNames {
            if (n.contains(normalized) || normalized.contains(n)) && max(n.count, normalized.count) >= 4 {
                return false
            }
            if (n.contains(baseNoVer) || baseNoVer.contains(n)) && max(n.count, baseNoVer.count) >= 4 {
                return false
            }
        }
        return true
    }

    /// 已知「共享厂商」根目录名。这些目录常被同厂商多个活 app 共用，
    /// 即使没有任何一个 app 显式认领，也不该判成孤儿（宁可漏报）。
    private static let sharedVendorRoots: Set<String> = [
        "jetbrains", "google", "microsoft", "apple", "mozilla", "adobe",
        "oracle", "intuit", "atlassian", "github", "gitlab", "docker",
        "spotify", "slack", "notion", "figma", "zoom", "unity", "unity3d",
        "valve", "steam", "epic", "blizzard", "logitech", "razer",
        "sublimehq", "vim", "node", "nvm", "homebrew", "macports", "python",
        "android", "samsung", "huawei", "xiaomi", "tencent", "baidu",
        "alibaba", "aliyun", "bytedance", "netease", "kingsoft", "ibm",
        "salesforce", "dropbox", "evernote", "mongodb", "postgres", "mysql"
    ]

    /// 有活着的 app 认领这个名字吗？双向前缀都算。
    static func isClaimed(_ normalized: String, live: Set<String>) -> Bool {
        if live.contains(normalized) { return true }
        // P0-3：剥掉 helper/agent/daemon 等尾部后缀后，按「基础 bundle id」再认领一次。
        // 这能兜住 com.example.app.helper（活 app 是 com.example.app）这类被 ./-/_ 之外
        // 分隔、或尾部后缀拆不出来的认领关系 —— 是 Pearcleaner/Lemon baseBundleId 的等效实现。
        let nb = Self.baseBundleId(normalized)
        if live.contains(nb) { return true }
        for liveId in live {
            let lb = Self.baseBundleId(liveId)
            if nb == lb { return true }
            if nb.hasPrefix("\(lb).") || nb.hasPrefix("\(lb)-") || nb.hasPrefix("\(lb)_") { return true }
            if lb.hasPrefix("\(nb).") || lb.hasPrefix("\(nb)-") || lb.hasPrefix("\(nb)_") { return true }
        }
        for liveId in live {
            // 后代：目录是 com.foo.bar.Extension，活 app 是 com.foo.bar
            if normalized.hasPrefix("\(liveId).") || normalized.hasPrefix("\(liveId)-") {
                return true
            }
            // 祖先：目录是 com.microsoft.rdc，活 app 是 com.microsoft.rdc.macos
            if liveId.hasPrefix("\(normalized).") {
                return true
            }
            // 同源变体：目录是 com.foo.bar_stats / com.foo.bar_backup，活 app 是 com.foo.bar。
            // 真机案例：AlDente 装着，但它的 com.apphousekitchen.aldente-pro_stats.sqlite3
            // 会被判成孤儿（`_stats` 不是 `.` 或 `-` 分隔）。
            if normalized.hasPrefix("\(liveId)_") { return true }
            // 反向同源：目录是 com.foo.bar，活 app 是 com.foo.bar_something
            if liveId.hasPrefix("\(normalized)_") { return true }
        }
        // 前两段相同就算同一家 app 的东西。
        // 真机案例：jetbrains.pycharm.3a396865 —— PyCharm 装着（com.jetbrains.pycharm），
        // 但偏好文件少了 com. 前缀，逐段比对匹配不上。
        if isClaimedByVendorPrefix(normalized, live: live) { return true }
        // 最后一道：同厂商还有活 app 就不判孤儿（宁可漏报）
        return hasLiveSibling(normalized, live: live)
    }

    /// 按「厂商 + 产品」两段做宽松认领，容忍 com. 前缀缺失和后缀哈希。
    private static func isClaimedByVendorPrefix(_ normalized: String, live: Set<String>) -> Bool {
        let segs = normalized.split(separator: ".").map(String.init)
        guard segs.count >= 2 else { return false }
        // 去掉可能缺失的 com./org./io. 等顶级段后，取前两段作为指纹
        let fingerprint = fingerprints(of: segs)
        guard !fingerprint.isEmpty else { return false }

        for liveId in live {
            let liveSegs = liveId.split(separator: ".").map(String.init)
            guard liveSegs.count >= 2 else { continue }
            let liveFp = fingerprints(of: liveSegs)
            if !liveFp.isDisjoint(with: fingerprint) { return true }
        }
        return false
    }

    /// 生成「厂商.产品」指纹集合。`jetbrains.pycharm.3a396865` 和
    /// `com.jetbrains.pycharm` 都会产出 `jetbrains.pycharm`。
    private static func fingerprints(of segs: [String]) -> Set<String> {
        var out = Set<String>()
        // 原样前两段
        out.insert(segs.prefix(2).joined(separator: "."))
        // 跳过顶级域段后的前两段
        if let first = segs.first, tlds.contains(first), segs.count >= 3 {
            out.insert(segs.dropFirst().prefix(2).joined(separator: "."))
        }
        // 只有两段且首段是 tld 时不产生指纹（避免 com.foo 与 org.foo 混淆）
        return out.filter { $0.contains(".") }
    }

    private static let tlds: Set<String> = [
        "com", "org", "io", "net", "cn", "co", "me", "ai", "app", "dev"
    ]

    /// 提取厂商段：`com.jetbrains.pycharm` → `jetbrains`，`jetbrains.webstorm.x` → `jetbrains`。
    static func vendorSegment(of normalized: String) -> String? {
        let segs = normalized.split(separator: ".").map(String.init)
        guard !segs.isEmpty else { return nil }
        if let first = segs.first, tlds.contains(first) {
            return segs.count >= 2 ? segs[1] : nil
        }
        return segs[0]
    }

    /// 同厂商的活 app 存在吗？
    ///
    /// 存在的理由（真机案例）：JetBrains 家的 IntelliJ / PyCharm 装着，
    /// 但 `~/Library/Preferences` 下还有一堆 `jetbrains.jetprofile.asset`（共享授权）、
    /// `jetbrains.pexceleditor.*`（IDE 插件偏好）—— 它们是**装着的 IDE 在用的**，
    /// 逐段比对匹配不上就会被判成孤儿。
    /// 同理 `com.tencent.bugly`（微信内嵌的崩溃上报 SDK）。
    ///
    /// 代价：同厂商的**真**孤儿会被漏报（如 WebStorm 卸载后残留的 122 字节偏好）。
    /// 这是刻意的取舍 —— 宁可漏报，不可误删活 app 的数据。
    static func hasLiveSibling(_ normalized: String, live: Set<String>) -> Bool {
        guard let vendor = vendorSegment(of: normalized), vendor.count >= 4 else { return false }
        for liveId in live {
            if vendorSegment(of: liveId) == vendor { return true }
        }
        return false
    }

    /// 剥掉 10 位 teamid 前缀和 group./groups. 前缀。
    /// `5A4RE8SF68.com.tencent.xinWeChat` → `com.tencent.xinWeChat`
    static func stripPrefixes(_ name: String) -> String {
        var result = name
        // teamid 是 10 位大写字母+数字
        let parts = result.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        if parts.count == 2, isTeamId(String(parts[0])) {
            result = String(parts[1])
        }
        for p in ["group.", "groups."] where result.lowercased().hasPrefix(p) {
            result = String(result.dropFirst(p.count))
            break
        }
        return result
    }

    static func isTeamId(_ s: String) -> Bool {
        guard s.count == 10 else { return false }
        return s.allSatisfy { $0.isUppercase && $0.isLetter || $0.isNumber }
    }

    /// 尾部「辅助组件」后缀 token。这些常出现在 bundle id 末段，
    /// 但本质是主 app 的延伸（helper/agent/daemon/xpc/service/extension/...），
    /// 不应被当作独立的认领主体。
    private static let helperSuffixes: Set<String> = [
        "helper", "agent", "daemon", "xpc", "service", "services", "extension", "extensions",
        "backend", "launcher", "loginhelper", "loginitem", "login-item", "crashhandler",
        "crashreporter", "updater", "renderer", "worker", "gpu", "nf", "ipc", "sdk", "core",
        "browserhelper", "helper-launcher", "helpermanager", "menu", "menuextra", "appex"
    ]

    /// 剥掉尾部连续的辅助组件后缀，得到「基础 bundle id」。
    /// `com.example.app.helper` → `com.example.app`；至少保留 vendor.product 两段。
    /// 这是 Pearcleaner / Lemon 共用的 `baseBundleId` 思路的等效实现。
    static func baseBundleId(_ id: String) -> String {
        var segs = id.split(separator: ".").map(String.init)
        while segs.count > 2, helperSuffixes.contains(segs.last!.lowercased()) {
            segs.removeLast()
        }
        return segs.joined(separator: ".")
    }

    /// 去掉尾部版本号段：`appname-1.2.3` / `appname-2024` → `appname`。
    /// 仅当末段是纯数字 / 数字点数字 / 4 位年份时才剥，避免误伤正常名字。
    static func stripTrailingVersion(_ s: String) -> String {
        let segs = s.split(separator: "-").map(String.init)
        guard segs.count > 1, let last = segs.last else { return s }
        let isNum = last.allSatisfy { $0.isNumber }
        let isYear = last.count == 4 && isNum
        let isSemver = last.contains(".") && last.split(separator: ".").allSatisfy { $0.allSatisfy { $0.isNumber } }
        guard isNum || isYear || isSemver else { return s }
        return segs.dropLast().joined(separator: "-")
    }

    /// 从目录名推断归属者：取 bundle id 的前三段作为聚合键，
    /// 这样 com.vendor.SomeCleaner 的多个目录会归到一组。
    static func inferOwner(_ name: String) -> String {
        let stripped = stripPrefixes(name)
        let segs = stripped.split(separator: ".")
        if segs.count >= 3 {
            return segs.prefix(3).joined(separator: ".")
        }
        return stripped
    }
}
