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
}
