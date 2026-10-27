import Foundation

/// 只读类 skill：列 app、扫痕迹、扫残留、列进程、看历史。
/// 全部无副作用，Agent 可以自由调用。

// MARK: - list_apps

/// `ai-mac-cleaner --list`
struct ListAppsSkill: AgentSkill {
    let spec = SkillSpec(
        name: "list_apps",
        cli: "--list",
        summaryZh: "列出本机已安装的应用，可用关键词过滤。想确认某个 app 的准确名字时先调它。",
        summaryEn: "List installed apps, optionally filtered by keyword. Call this first to confirm an app's exact name.",
        args: [
            SkillArg(name: "keyword", required: false,
                     desc: L10n.t("过滤关键词，留空返回全部（截断展示）",
                                  "Filter keyword; empty returns everything (truncated)")),
            SkillArg(name: "limit", required: false,
                     desc: L10n.t("最多返回几条，默认 30", "Max entries to return, default 30"))
        ],
        risk: .readOnly
    )

    func invoke(_ args: SkillArgs, session: AgentSession) async -> SkillResult {
        let all = InventoryCache.shared.allApps()
        let keyword = args["keyword"]
        let hits = keyword.map { AppInventory.search($0, in: all) } ?? all
        let limit = max(1, args.int("limit", default: 30))

        guard !hits.isEmpty else {
            let msg = L10n.t("没有匹配「\(keyword ?? "")」的已安装应用。",
                             "No installed app matches “\(keyword ?? "")”.")
            return SkillResult(ok: true, summary: msg, observation: msg)
        }

        let shown = hits.prefix(limit)
        let lines = shown.map { app -> String in
            var s = app.displayName
            if app.displayName.lowercased() != app.fileName.lowercased() { s += " (\(app.fileName).app)" }
            if let v = app.version { s += " v\(v)" }
            if let b = app.bundleId { s += " [\(b)]" }
            return s
        }
        let more = hits.count > shown.count
            ? L10n.t("\n…还有 \(hits.count - shown.count) 个未列出", "\n…and \(hits.count - shown.count) more")
            : ""
        let summary = L10n.t("找到 \(hits.count) 个应用。", "Found \(hits.count) apps.")
        return SkillResult(ok: true, summary: summary,
                           observation: summary + "\n" + lines.joined(separator: "\n") + more)
    }
}

// MARK: - scan_app

/// `ai-mac-cleaner --scan <target>`
struct ScanAppSkill: AgentSkill {
    let spec = SkillSpec(
        name: "scan_app",
        cli: "--scan <target>",
        summaryZh: "扫描某个应用留在系统里的全部痕迹（程序本体、缓存、容器、启动项、包管理器条目…），不删任何东西。",
        summaryEn: "Scan everything an app left behind (bundle, caches, containers, launch agents, package entries…). Deletes nothing.",
        args: [
            SkillArg(name: "target", required: true,
                     desc: L10n.t("应用名或关键词，如 Cursor、微信、mimo",
                                  "App name or keyword, e.g. Cursor, WeChat, mimo"))
        ],
        risk: .readOnly
    )

    func invoke(_ args: SkillArgs, session: AgentSession) async -> SkillResult {
        guard let target = args["target"] else {
            return .failure(L10n.t("scan_app 需要 target 参数", "scan_app requires a target argument"))
        }

        let query = AppState.resolveQuery(from: target)
        var artifacts: [Artifact] = []
        for scanner in CLIScan.allScanners {
            artifacts.append(contentsOf: await scanner.scan(query: query))
        }
        var seen = Set<String>()
        artifacts = artifacts.filter { seen.insert($0.path).inserted }
        // 与「应用」页保持同一套默认：全选，把取舍权交给用户。
        for i in artifacts.indices { artifacts[i].selected = true }

        session.lastTarget = query.displayTarget
        session.lastArtifacts = artifacts
        // propose_paths 的校验网需要知道「除目标 app 外的其它活 app」，
        // 所以这里要把身份一起存下来。
        session.lastApp = query.app

        guard !artifacts.isEmpty else {
            let msg = L10n.t("没有找到 \(query.displayTarget) 的任何痕迹。",
                             "No traces found for \(query.displayTarget).")
            return SkillResult(ok: true, summary: msg, observation: msg,
                               effect: .appScan(target: query.displayTarget, app: query.app, artifacts: []),
                               redirect: .apps)
        }

        let plan = RemovalPlan(targetName: query.displayTarget, artifacts: artifacts)
        let summary = L10n.t(
            "\(query.displayTarget)：\(artifacts.count) 项痕迹，合计 \(SizeFormat.human(plan.scannedTotalSize))。",
            "\(query.displayTarget): \(artifacts.count) traces, \(SizeFormat.human(plan.scannedTotalSize)) total.")

        var obs = summary
        if let app = query.app {
            obs += "\n" + L10n.t("锁定应用：\(app.displayName) \(app.bundleId ?? "")",
                                 "Resolved app: \(app.displayName) \(app.bundleId ?? "")")
        }
        obs += "\n" + AgentFormat.categoryBreakdown(artifacts)
        obs += "\n" + AgentFormat.riskBreakdown(artifacts)
        obs += "\n" + AgentFormat.topPaths(artifacts, limit: 12)

        return SkillResult(ok: true, summary: summary, observation: obs,
                           effect: .appScan(target: query.displayTarget, app: query.app, artifacts: artifacts),
                           redirect: .apps)
    }
}

// MARK: - scan_leftovers

/// `ai-mac-cleaner --orphans`
struct ScanLeftoversSkill: AgentSkill {
    let spec = SkillSpec(
        name: "scan_leftovers",
        cli: "--orphans",
        summaryZh: "反向扫描：找已卸载应用留下的无主数据，以及已知 AI 编程工具的痕迹。结果是启发式的，默认全不勾选。",
        summaryEn: "Reverse scan for data left by uninstalled apps plus known AI coding-tool traces. Heuristic; nothing is checked by default.",
        args: [
            SkillArg(name: "kind", required: false,
                     desc: L10n.t("限定来源：orphan 只看无主残留，ai 只看 AI 工具，all 全要（默认）",
                                  "Limit source: orphan, ai, or all (default)"),
                     options: ["orphan", "ai", "all"])
        ],
        risk: .readOnly
    )

    func invoke(_ args: SkillArgs, session: AgentSession) async -> SkillResult {
        let kind = args.string("kind", default: "all").lowercased()
        var groups: [LeftoverGroup] = []
        if kind != "ai" {
            groups += await OrphanScanner.scanAll(liveIds: InventoryCache.shared.liveBundleIds())
        }
        if kind != "orphan" {
            groups += AIAgentScanner.scanAll()
        }
        session.lastLeftovers = groups

        guard !groups.isEmpty else {
            let msg = L10n.t("没有发现残留 —— 所有痕迹都能对应到已安装的应用。",
                             "No leftovers — every trace maps to an installed app.")
            return SkillResult(ok: true, summary: msg, observation: msg,
                               effect: .leftovers([]), redirect: .leftovers)
        }

        let total = groups.reduce(Int64(0)) { $0 + $1.totalSize }
        let count = groups.reduce(0) { $0 + $1.artifacts.count }
        let summary = L10n.t(
            "\(groups.count) 组残留，共 \(count) 项 / \(SizeFormat.human(total))。默认全不勾选，需逐项确认。",
            "\(groups.count) leftover groups, \(count) items / \(SizeFormat.human(total)). All unchecked — verify item by item.")

        let top = groups.sorted { $0.totalSize > $1.totalSize }.prefix(10)
            .map { "  \($0.owner) — \(SizeFormat.human($0.totalSize)) (\($0.artifacts.count))" }
            .joined(separator: "\n")
        let more = groups.count > 10
            ? L10n.t("\n  …还有 \(groups.count - 10) 组", "\n  …and \(groups.count - 10) more groups") : ""

        return SkillResult(ok: true, summary: summary,
                           observation: summary + "\n" + top + more,
                           effect: .leftovers(groups), redirect: .leftovers)
    }
}

// MARK: - list_processes

/// `ai-mac-cleaner --ps`
struct ListProcessesSkill: AgentSkill {
    let spec = SkillSpec(
        name: "list_processes",
        cli: "--ps",
        summaryZh: "列出正在运行的进程（默认只看用户级后台进程，如 node / python / dev server）。只枚举，不结束任何进程。",
        summaryEn: "List running processes (user-level background ones like node / python / dev servers by default). Enumerates only; kills nothing.",
        args: [
            SkillArg(name: "filter", required: false,
                     desc: L10n.t("background 只看后台（默认）、user 含 GUI 应用、system 含系统进程",
                                  "background (default), user (adds GUI apps), or system (adds system processes)"),
                     options: ["background", "user", "system"]),
            SkillArg(name: "keyword", required: false,
                     desc: L10n.t("按进程名过滤，如 node", "Filter by process name, e.g. node")),
            SkillArg(name: "limit", required: false,
                     desc: L10n.t("最多返回几条，默认 15", "Max entries, default 15"))
        ],
        risk: .readOnly
    )

    func invoke(_ args: SkillArgs, session: AgentSession) async -> SkillResult {
        let all = ProcessLister.snapshot()
        let filter = args.string("filter", default: "background").lowercased()
        var list: [LiveProcess]
        switch filter {
        case "user":   list = all.filter { $0.kind != .system }
        case "system": list = all
        default:       list = all.filter { $0.kind == .background }
        }
        if let kw = args["keyword"]?.lowercased() {
            list = list.filter { $0.name.lowercased().contains(kw) || $0.comm.lowercased().contains(kw) }
        }
        list.sort { $0.memoryBytes > $1.memoryBytes }

        guard !list.isEmpty else {
            let msg = L10n.t("当前筛选条件下没有匹配的进程。", "No processes match the current filter.")
            return SkillResult(ok: true, summary: msg, observation: msg,
                               effect: .processes(all), redirect: .processes)
        }

        let limit = max(1, args.int("limit", default: 15))
        let mem = list.reduce(Int64(0)) { $0 + $1.memoryBytes }
        let killable = list.filter(\.isKillable).count
        let summary = L10n.t(
            "\(list.count) 个进程，占用内存 \(SizeFormat.human(mem))，其中 \(killable) 个可结束。",
            "\(list.count) processes using \(SizeFormat.human(mem)); \(killable) can be ended.")

        let rows = list.prefix(limit).map { p -> String in
            let lock = p.isKillable ? "" : L10n.t("（受保护）", " (protected)")
            return "  \(p.name)  pid=\(p.pid)  \(SizeFormat.human(p.memoryBytes))  cpu=\(String(format: "%.1f", p.cpuPercent))%\(lock)"
        }.joined(separator: "\n")

        var obs = summary + "\n" + rows
        obs += "\n" + L10n.t("结束进程需要用户在「进程」页勾选并确认；系统进程与 AI Mac Cleaner 自身不可结束。",
                             "Ending a process requires the user to select and confirm in the Processes tab; system processes and AI Mac Cleaner itself are protected.")
        return SkillResult(ok: true, summary: summary, observation: obs,
                           effect: .processes(all), redirect: .processes)
    }
}

// MARK: - check_installs

/// `ai-mac-cleaner --check-installs <target>`
///
/// 为什么要有：内置扫描器认的是「目录名像不像这个 app」，而**安装渠道不在它的字典里**。
/// 一个东西是 `brew install` 装的（Cellar / Caskroom / brew services）、是 `npm -g` 装的、
/// 还是注册了 launchd 启动项 —— 只有主动去问对应的包管理器才知道。
/// 没有这条 skill，模型只能按名字猜路径，用户「我可能是 brew 装的」这种关键线索就用不上。
/// 全部只读枚举，不动任何东西。
struct CheckInstallsSkill: AgentSkill {
    let spec = SkillSpec(
        name: "check_installs",
        cli: "--check-installs <target>",
        summaryZh: "查某个东西在本机的安装渠道：Homebrew（formula/cask/服务）、launchd 启动项、npm / pipx 全局包。判断「是不是 brew 装的」先调它。",
        summaryEn: "Check how something is installed on this machine: Homebrew (formula/cask/services), launchd agents, npm / pipx globals. Call this to find out whether it came from brew.",
        args: [
            SkillArg(name: "target", required: true,
                     desc: L10n.t("应用名或关键词，如 openclaw、Cursor", "App name or keyword, e.g. openclaw, Cursor"))
        ],
        risk: .readOnly
    )

    func invoke(_ args: SkillArgs, session: AgentSession) async -> SkillResult {
        guard let target = args["target"] else {
            return .failure(L10n.t("check_installs 需要 target 参数", "check_installs requires a target argument"))
        }
        let tokens = Self.keywords(from: target)
        guard !tokens.isEmpty else {
            return .failure(L10n.t("target 里没有可用于匹配的关键词", "No usable keyword in target"))
        }

        var sections: [String] = []
        var channels: [String] = []

        // ── Homebrew ──
        let brew = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
        if let brew {
            var brewLines: [String] = []
            // env 包一层：brew 老版本在 list 时也可能触发 auto-update，禁掉避免卡 30s。
            for (label, listArgs) in [("formula", ["list", "--formula", "--quiet"]),
                                      ("cask",    ["list", "--cask", "--quiet"])] {
                if let out = Shell.run("/usr/bin/env", ["HOMEBREW_NO_AUTO_UPDATE=1", brew] + listArgs) {
                    let hits = Self.matches(in: out, tokens: tokens)
                    for h in hits { brewLines.append("  brew \(label): \(h)") }
                }
            }
            if let out = Shell.run("/usr/bin/env", ["HOMEBREW_NO_AUTO_UPDATE=1", brew, "services", "list"]) {
                // 首行是表头（Name Status User File），跳过。
                let hits = out.split(separator: "\n").dropFirst()
                    .filter { line in tokens.contains { line.lowercased().contains($0) } }
                for h in hits { brewLines.append("  brew service: \(h)") }
            }
            if brewLines.isEmpty {
                sections.append(L10n.t("Homebrew：formula / cask / services 里都没有匹配「\(target)」的条目。",
                                       "Homebrew: no formula / cask / service matches “\(target)”."))
            } else {
                channels.append("Homebrew")
                sections.append(L10n.t("Homebrew：", "Homebrew:") + "\n" + brewLines.joined(separator: "\n"))
            }
        } else {
            sections.append(L10n.t("Homebrew：本机未安装。", "Homebrew: not installed."))
        }

        // ── launchd ──
        var launchdLines: [String] = []
        if let out = Shell.run("/bin/launchctl", ["list"]) {
            for h in Self.matches(in: out, tokens: tokens) { launchdLines.append("  launchctl: \(h)") }
        }
        let fm = FileManager.default
        let launchDirs = [(fm.homeDirectoryForCurrentUser.path + "/Library/LaunchAgents"),
                          "/Library/LaunchAgents", "/Library/LaunchDaemons"]
        for dir in launchDirs {
            guard let names = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for name in names where tokens.contains(where: { name.lowercased().contains($0) }) {
                launchdLines.append("  \(dir)/\(name)")
            }
        }
        if launchdLines.isEmpty {
            sections.append(L10n.t("launchd：没有匹配的启动项。", "launchd: no matching agents/daemons."))
        } else {
            channels.append("launchd")
            sections.append(L10n.t("launchd（这些 plist 本身也是卸载时要删的，可提交 propose_paths）：",
                                   "launchd (these plists are uninstall targets too; submit them via propose_paths):")
                            + "\n" + launchdLines.joined(separator: "\n"))
        }

        // ── npm / pipx ──
        for (channel, bin, cmdArgs) in [("npm", "npm", ["ls", "-g", "--depth=0"]),
                                        ("pipx", "pipx", ["list", "--short"])] {
            let path = ["/opt/homebrew/bin/\(bin)", "/usr/local/bin/\(bin)"]
                .first { fm.isExecutableFile(atPath: $0) }
            guard let path else {
                sections.append(L10n.t("\(channel)：本机未安装。", "\(channel): not installed."))
                continue
            }
            guard let out = Shell.run(path, cmdArgs), !out.isEmpty else {
                sections.append(L10n.t("\(channel)：没有匹配的包。", "\(channel): no matching packages."))
                continue
            }
            let hits = Self.matches(in: out, tokens: tokens)
            if hits.isEmpty {
                sections.append(L10n.t("\(channel)：没有匹配的包。", "\(channel): no matching packages."))
            } else {
                channels.append(channel)
                sections.append("\(channel):\n" + hits.map { "  \($0)" }.joined(separator: "\n"))
            }
        }

        let head = channels.isEmpty
            ? L10n.t("「\(target)」不是通过 brew / npm / pipx / launchd 管理的（或关键词没匹配上）。它更可能是手动安装、浏览器 PWA 或独立 app。",
                     "“\(target)” isn't managed by brew / npm / pipx / launchd (or no keyword matched). It's likely manual, a browser PWA, or a standalone app.")
            : L10n.t("「\(target)」由以下渠道管理：\(channels.joined(separator: "、"))。",
                     "“\(target)” is managed by: \(channels.joined(separator: ", ")).")

        return SkillResult(ok: true, summary: head,
                           observation: head + "\n" + sections.joined(separator: "\n"))
    }

    /// 从目标名提取匹配关键词：按非字母数字切词、去重、丢掉 <3 字符的碎词；
    /// 多词的再拼一个无分隔符形式（OpenClaw Control → openclawcontrol），
    /// 兜住 plist / 包名里连写的情况。
    static func keywords(from target: String) -> [String] {
        var tokens = target.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .filter { $0.count >= 3 }
            .map(String.init)
        if tokens.count > 1 {
            tokens.append(tokens.joined())
        }
        return Array(Set(tokens))
    }

    /// 从一段命令输出里挑出含任一关键词的行。
    static func matches(in output: String, tokens: [String]) -> [String] {
        output.split(separator: "\n")
            .filter { line in tokens.contains { line.lowercased().contains($0) } }
            .map(String.init)
    }
}

// MARK: - show_history

/// `ai-mac-cleaner --history`
struct ShowHistorySkill: AgentSkill {
    let spec = SkillSpec(
        name: "show_history",
        cli: "--history",
        summaryZh: "查看以往的卸载记录（目标、时间、成功/失败项数、释放量）。",
        summaryEn: "Show past uninstall records (target, time, success/failure counts, space freed).",
        args: [
            SkillArg(name: "limit", required: false,
                     desc: L10n.t("最多返回几条，默认 10", "Max entries, default 10"))
        ],
        risk: .readOnly
    )

    func invoke(_ args: SkillArgs, session: AgentSession) async -> SkillResult {
        let records = HistoryStore.listAll()
        guard !records.isEmpty else {
            let msg = L10n.t("还没有卸载历史。", "No uninstall history yet.")
            return SkillResult(ok: true, summary: msg, observation: msg)
        }
        let limit = max(1, args.int("limit", default: 10))
        let rows = records.prefix(limit).map { r -> String in
            let when = r.startedAt.formatted(date: .abbreviated, time: .shortened)
            let size = (r.trashedBytes ?? 0) > 0
                ? L10n.t("废纸篓 \(SizeFormat.human(r.trashedBytes ?? 0))", "trashed \(SizeFormat.human(r.trashedBytes ?? 0))")
                : L10n.t("释放 \(SizeFormat.human(r.freedBytes))", "freed \(SizeFormat.human(r.freedBytes))")
            return "  \(r.targetName) — \(when) — " +
                L10n.t("成功 \(r.deletedCount) / 失败 \(r.failedCount) — \(size)",
                       "\(r.deletedCount) ok / \(r.failedCount) failed — \(size)")
        }.joined(separator: "\n")
        let summary = L10n.t("共 \(records.count) 条卸载记录。", "\(records.count) uninstall records.")
        return SkillResult(ok: true, summary: summary, observation: summary + "\n" + rows)
    }
}

// MARK: - 观测文本格式化

/// 把扫描结果压成模型读得懂、又不会撑爆上下文的短文本。
enum AgentFormat {
    static func categoryBreakdown(_ artifacts: [Artifact]) -> String {
        let grouped = Dictionary(grouping: artifacts, by: \.category)
        let rows = grouped
            .map { (cat, items) in (cat, items.count, items.reduce(Int64(0)) { $0 + $1.size }) }
            .sorted { $0.2 > $1.2 }
            .map { "  \($0.0.rawValue): \($0.1) 项 / \(SizeFormat.human($0.2))" }
        return L10n.t("按类别：\n", "By category:\n") + rows.joined(separator: "\n")
    }

    static func riskBreakdown(_ artifacts: [Artifact]) -> String {
        let safe = artifacts.filter { $0.risk == .safe }
        let user = artifacts.filter { $0.risk == .userData }
        let unknown = artifacts.filter { $0.risk == .uncertain }
        return L10n.t(
            "按风险：可安全删除 \(safe.count) 项 / \(SizeFormat.human(safe.reduce(0) { $0 + $1.size }))；" +
            "含用户数据 \(user.count) 项 / \(SizeFormat.human(user.reduce(0) { $0 + $1.size }))；" +
            "无法判断 \(unknown.count) 项",
            "By risk: safe \(safe.count) / \(SizeFormat.human(safe.reduce(0) { $0 + $1.size })); " +
            "user-data \(user.count) / \(SizeFormat.human(user.reduce(0) { $0 + $1.size })); " +
            "uncertain \(unknown.count)")
    }

    static func topPaths(_ artifacts: [Artifact], limit: Int) -> String {
        let top = artifacts.sorted { $0.size > $1.size }.prefix(limit)
        let rows = top.map { "  [\($0.risk.label)] \($0.path) (\(SizeFormat.human($0.size)))" }
        let more = artifacts.count > top.count
            ? L10n.t("\n  …还有 \(artifacts.count - top.count) 项", "\n  …and \(artifacts.count - top.count) more")
            : ""
        return L10n.t("最大的几项：\n", "Largest items:\n") + rows.joined(separator: "\n") + more
    }

    /// 把清单压成适合塞进用户提示词的短列表，让模型「看得见」当前清单，
    /// 避免它因为不知道具体路径而重复扫描或反问用户。
    ///
    /// - Parameter pathLength: 单条路径最大字符数，超过则从中间截断。
    static func promptList(_ artifacts: [Artifact], limit: Int = 30, pathLength: Int = 80) -> String {
        guard !artifacts.isEmpty else { return L10n.t("（当前清单为空）", "(the current list is empty)") }
        let totalSize = artifacts.reduce(Int64(0)) { $0 + $1.size }
        var lines: [String] = []
        for (idx, a) in artifacts.prefix(limit).enumerated() {
            let path = a.path.count > pathLength
                ? String(a.path.prefix(pathLength / 2)) + "…" + String(a.path.suffix(pathLength / 2))
                : a.path
            lines.append("  \(idx + 1). [\(a.category.rawValue)] \(path) — \(SizeFormat.human(a.size)) — \(a.risk.label)")
        }
        let header = L10n.t("当前清单（共 \(artifacts.count) 项 / \(SizeFormat.human(totalSize))）：",
                            "Current list (\(artifacts.count) items / \(SizeFormat.human(totalSize))):")
        let more = artifacts.count > limit
            ? L10n.t("\n  …还有 \(artifacts.count - limit) 项未列出", "\n  …and \(artifacts.count - limit) more not listed")
            : ""
        return header + "\n" + lines.joined(separator: "\n") + more
    }
}
