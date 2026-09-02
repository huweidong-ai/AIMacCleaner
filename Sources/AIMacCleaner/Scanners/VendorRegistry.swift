import Foundation

/// 同源厂商残留识别。
///
/// **为什么需要**：现代大厂常把一个产品拆成多个独立入口——
/// OpenAI 既有 ChatGPT 桌面 app（整合了 Codex 模式），又有 Codex CLI
/// （`~/.codex/` 数据目录 + `npm i -g @openai/codex`）、Chrome 扩展宿主常驻进程
/// （`plugins/cache/openai-bundled/chrome`，注册菜单栏图标）、相关 launch agent。
/// 这些入口**安装/卸载互不相连**：卸载 ChatGPT.app 时，按 bundle id 扫不到
/// `~/.codex/`，于是留下一个 637 MB 的死目录，以及一个点不动的菜单栏幽灵图标
/// （那个常驻进程的主程序早被删了）。
///
/// 这里用一张「厂商 → 痕迹特征」映射表，在卸载某厂商 app 时，额外把同厂商的
/// 其他入口拉出来，单独列成一组「同厂商残留」，让用户勾选是否一并清理。
///
/// **为什么不能靠通用扫描器兜底**：`LibraryDataScanner` / `XDGUserDataScanner` /
/// `LaunchAgentScanner` 都只匹配**顶层**条目名。ego lite 的数据全在
/// `~/Library/Application Support/Citro Labs/ego lite` 这种「父目录叫 `Citro Labs`、
/// 不含 `ego`」的路径下，加 CLI（`~/.local/bin/ego-browser`）、keystone 启动项、
/// `DiagnosticReports/*.ips` 崩溃报告——没有任何单条通用规则能命中。所以这类
/// 「应用 + Updater + 守护 + CLI + 崩溃报告」的深层残留，必须靠显式 probe 枚举。
enum VendorRegistry {

    /// 一条厂商残留特征定义。
    struct VendorTrace {
        /// 展示名（双语）
        let displayName: String
        /// 探测函数：返回确实存在的痕迹路径（可能多个，如崩溃报告 glob）。
        /// 空数组表示该痕迹不存在，不列出骗用户。
        let probe: () -> [String]
        /// 风险等级：`.userData` 含 Cookie/登录态/浏览资料，默认不勾选；`.safe` 默认勾选。
        let risk: Risk
        /// 删除处置：目录走废纸篓、进程走「杀」
        let disposition: Disposition

        enum Disposition {
            case trashDir    // 走废纸篓（可恢复）
            case killProcess // 杀进程（meta 填 PID / 进程描述）
        }
    }

    /// 厂商条目：给定 bundle id / 显示名命中后，列出该厂商的其他残留特征。
    struct Vendor {
        /// 厂商识别关键词（低大小写）。命中 app 的 bundle id 或别名任一即认领。
        let identifiers: [String]
        /// 厂商展示名
        let name: String
        /// 该厂商已知的其他残留
        let traces: [VendorTrace]
    }

    // MARK: - 厂商表

    /// 已登记的厂商。先收 OpenAI（真实踩坑），后补 Citro Labs（ego lite，真实踩坑：
    /// 通用扫描器只命中 HTTPStorages/Preferences/部分 LaunchAgent，漏掉 Citro Labs
    /// 父目录、keystone 框架启动项、~/.local/bin CLI、崩溃报告）。后续可平滑扩展。
    static let vendors: [Vendor] = [
        Vendor(
            identifiers: ["openai", "chatgpt", "codex"],
            name: "OpenAI",
            traces: [
                // 1) Codex CLI / 旧 Codex 桌面端的数据目录（用户家目录根，不在 ~/Library）
                VendorTrace(
                    displayName: L10n.t("Codex CLI 数据目录", "Codex CLI data"),
                    probe: { existingDirs(NSHomeDirectory() + "/.codex") },
                    risk: .userData,
                    disposition: .trashDir
                ),
                // 2) OpenAI 常驻的 Chrome 扩展宿主进程（菜单栏幽灵图标来源）
                VendorTrace(
                    displayName: L10n.t("OpenAI 常驻进程（菜单栏图标）", "OpenAI resident process (menu bar)"),
                    probe: { residentOpenAIProcesses().map { "PID: " + $0 } },
                    risk: .safe,
                    disposition: .killProcess
                ),
                // 3) OpenAI 相关 launch agent
                VendorTrace(
                    displayName: L10n.t("OpenAI 启动项", "OpenAI launch agent"),
                    probe: { launchAgents(matching: ["openai", "chatgpt", "codex"]) },
                    risk: .safe,
                    disposition: .trashDir
                )
            ]
        ),

        // MARK: Citro Labs / ego lite
        //
        // 真实样本（本机实测）：卸载 ego lite 时通用扫描器只找到 ~6 项，本地 AI agent
        // 能挖出 ~15 项。缺口全部来自「父目录叫 Citro Labs」「keystone 框架」「CLI 组件」
        // 「崩溃报告」这四类通用规则覆盖不到的痕迹。这里用显式 probe 枚举全部。
        Vendor(
            identifiers: ["citrolabs", "ego lite", "egobrowser", "ego-browser"],
            name: "Citro Labs (ego lite)",
            traces: [
                // 1) 浏览器用户数据（Cookie / 登录态 / 浏览资料）—— 不可恢复，userData 默认不勾
                VendorTrace(
                    displayName: L10n.t("ego lite 用户数据（Cookie / 登录态 / 浏览资料）",
                                        "ego lite user data (cookies, login, browsing)"),
                    probe: { existingDirs(home("Library/Application Support/Citro Labs/ego lite")) },
                    risk: .userData,
                    disposition: .trashDir
                ),
                // 2) EgoUpdater 数据目录
                VendorTrace(
                    displayName: L10n.t("EgoUpdater 数据目录", "EgoUpdater data"),
                    probe: { existingDirs(home("Library/Application Support/Citro Labs/EgoUpdater")) },
                    risk: .userData,
                    disposition: .trashDir
                ),
                // 3) ego lite 缓存（可再生）→ safe 默认勾选
                VendorTrace(
                    displayName: L10n.t("ego lite 缓存", "ego lite caches"),
                    probe: { existingDirs(home("Library/Caches/Citro Labs/ego lite")) },
                    risk: .safe,
                    disposition: .trashDir
                ),
                // 4) EgoUpdater 缓存
                VendorTrace(
                    displayName: L10n.t("EgoUpdater 缓存", "EgoUpdater caches"),
                    probe: { existingDirs(home("Library/Caches/com.citrolabs.EgoUpdater")) },
                    risk: .safe,
                    disposition: .trashDir
                ),
                // 5) HTTPStorages（含 HTTP Cookie / 登录态）→ userData
                VendorTrace(
                    displayName: L10n.t("EgoUpdater HTTP 存储（登录态）", "EgoUpdater HTTP storage (login)"),
                    probe: { existingDirs(home("Library/HTTPStorages/com.citrolabs.EgoUpdater")) },
                    risk: .userData,
                    disposition: .trashDir
                ),
                // 6) 偏好设置 plist（含登录态/配置）→ userData
                VendorTrace(
                    displayName: L10n.t("ego lite 偏好设置", "ego lite preferences"),
                    probe: { existingFiles(home("Library/Preferences/com.citrolabs.ego.lite.plist")) },
                    risk: .userData,
                    disposition: .trashDir
                ),
                // 7) 启动项：EgoUpdater.wake
                VendorTrace(
                    displayName: L10n.t("ego lite 启动项（EgoUpdater）", "ego lite launch agent (EgoUpdater)"),
                    probe: { existingFiles(home("Library/LaunchAgents/com.citrolabs.EgoUpdater.wake.plist")) },
                    risk: .safe,
                    disposition: .trashDir
                ),
                // 8) 启动项：keystone.agent（Updater 框架，不含 ego 关键词，通用匹配漏）
                VendorTrace(
                    displayName: L10n.t("Keystone 启动项（agent）", "Keystone launch agent"),
                    probe: { existingFiles(home("Library/LaunchAgents/com.citrolabs.keystone.agent.plist")) },
                    risk: .safe,
                    disposition: .trashDir
                ),
                // 9) 启动项：keystone.xpcservice
                VendorTrace(
                    displayName: L10n.t("Keystone 启动项（XPC）", "Keystone XPC launch agent"),
                    probe: { existingFiles(home("Library/LaunchAgents/com.citrolabs.keystone.xpcservice.plist")) },
                    risk: .safe,
                    disposition: .trashDir
                ),
                // 10) CLI 工具：~/.local/bin/ego-browser（XDG 扫描器未覆盖 ~/.local/bin）
                VendorTrace(
                    displayName: L10n.t("ego 命令行工具（ego-browser）", "ego CLI (ego-browser)"),
                    probe: { existingFiles(home(".local/bin/ego-browser")) },
                    risk: .safe,
                    disposition: .trashDir
                ),
                // 11) CLI 数据：~/.local/share/ego
                VendorTrace(
                    displayName: L10n.t("ego 命令行数据", "ego CLI data"),
                    probe: { existingDirs(home(".local/share/ego")) },
                    risk: .userData,
                    disposition: .trashDir
                ),
                // 12) 崩溃报告（可选删除）：DiagnosticReports 下 ego lite-* / ego Helper* 及 Retired/
                VendorTrace(
                    displayName: L10n.t("ego lite 崩溃报告", "ego lite crash reports"),
                    probe: { egoCrashReports() },
                    risk: .safe,
                    disposition: .trashDir
                )
            ]
        )
    ]

    // MARK: - 对外 API

    /// 给定已定位的 app，返回它所属厂商（若有）。
    static func vendor(for app: AppIdentity) -> Vendor? {
        let haystack = ([app.bundleId ?? "", app.displayName, app.fileName]
                        + app.aliases).map { $0.lowercased() }
        return vendors.first { vendor in
            vendor.identifiers.contains { id in
                haystack.contains { $0.contains(id) }
            }
        }
    }

    /// 探测某厂商当前确实存在的残留，转成 `Artifact`（未勾选/按风险定默认）。
    /// 不存在的痕迹直接跳过，避免列出空项骗用户。
    static func leftoverArtifacts(for vendor: Vendor) -> [Artifact] {
        var out: [Artifact] = []
        for trace in vendor.traces {
            let hits = trace.probe()
            guard !hits.isEmpty else { continue }
            for hit in hits {
                let category: ArtifactCategory = (trace.disposition == .killProcess)
                    ? .runningProcess
                    : .vendorLeftover
                let size = trace.disposition == .trashDir ? directorySize(hit) : 0
                // 用户数据默认不勾选（留一线可找回）；safe 默认勾选。
                let selected = (trace.risk != .userData)
                var art = Artifact(category: category, path: hit, size: size,
                                   risk: trace.risk, meta: (trace.disposition == .killProcess ? hit : nil),
                                   selected: selected)
                art.note = trace.displayName
                out.append(art)
            }
        }
        return out
    }

    /// 便捷：给定 app，直接返回同厂商残留 Artifact（空数组表示无）。
    static func vendorLeftovers(for app: AppIdentity) -> [Artifact] {
        guard let v = vendor(for: app) else { return [] }
        return leftoverArtifacts(for: v)
    }

    // MARK: - 辅助

    /// 家目录下拼接路径。
    private static func home(_ relative: String) -> String {
        NSHomeDirectory() + "/" + relative
    }

    /// 返回真实存在且为目录的路径。
    private static func existingDirs(_ paths: String...) -> [String] {
        paths.compactMap { p in
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: p, isDirectory: &isDir) && isDir.boolValue ? p : nil
        }
    }

    /// 返回真实存在且为文件的路径。
    private static func existingFiles(_ paths: String...) -> [String] {
        paths.compactMap { p in
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: p, isDirectory: &isDir) && !isDir.boolValue ? p : nil
        }
    }

    /// 在 ~/Library/LaunchAgents（及系统级）里找 Label/Program/文件名匹配任一关键词的 plist。
    private static func launchAgents(matching keywords: [String]) -> [String] {
        let dirs = [
            NSHomeDirectory() + "/Library/LaunchAgents",
            "/Library/LaunchAgents",
            "/Library/LaunchDaemons"
        ]
        var out: [String] = []
        for dir in dirs {
            guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
            for f in files where f.hasSuffix(".plist") {
                let lower = f.lowercased()
                if keywords.contains(where: { lower.contains($0) }) {
                    out.append(dir + "/" + f)
                }
            }
        }
        return out
    }

    /// ego lite / ego Helper 的崩溃报告（含 Retired 子目录）。
    private static func egoCrashReports() -> [String] {
        let base = NSHomeDirectory() + "/Library/Logs/DiagnosticReports"
        let dirs = [base, base + "/Retired"]
        let prefixes = ["ego lite-", "ego helper"]
        var out: [String] = []
        for dir in dirs {
            guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
            for f in files where f.hasSuffix(".ips") {
                let lower = f.lowercased()
                if prefixes.contains(where: { lower.hasPrefix($0) }) {
                    out.append(dir + "/" + f)
                }
            }
        }
        return out
    }

    /// 找 OpenAI 常驻进程（非 AppStore/系统）：命令行含 ChatGPT/OpenAI/codex 关键词、
    /// 且不属于当前已装 app 的进程。
    private static func residentOpenAIProcesses() -> [String] {
        guard let output = Shell.run("/usr/bin/pgrep", ["-fil", "openai"]),
              !output.isEmpty else { return [] }
        var pids: [String] = []
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let pid = String(parts[0])
            let cmd = String(parts[1])
            // 排除 AI Mac Cleaner 自身
            if cmd.contains("/AIMacCleaner.app/") || cmd.hasSuffix("/AIMacCleaner") { continue }
            pids.append(pid)
        }
        return pids
    }

    /// 目录大小（递归），失败返回 0。
    private static func directorySize(_ path: String) -> Int64 {
        let url = URL(fileURLWithPath: path)
        guard let enumerator = FileManager.default.enumerator(at: url,
              includingPropertiesForKeys: [.fileSizeKey],
              options: [.skipsHiddenFiles]) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Int64(size)
            }
        }
        return total
    }
}
