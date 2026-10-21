import Foundation

/// 决策类 skill：分析清单、预演卸载。
///
/// 这两个是 Agent 能力的边界所在 —— 它们输出的是**判断和计划**，
/// 不是已发生的事实。真正落盘的删除只可能来自用户在界面上的确认。

// MARK: - review_plan

/// `ai-mac-cleaner --review <target>`
struct ReviewPlanSkill: AgentSkill {
    let spec = SkillSpec(
        name: "review_plan",
        cli: "--review <target>",
        summaryZh: "对当前清单做安全分析：挑出不该删的项（登录态、密钥、被其它应用共享的数据）并说明理由，自动取消其勾选。",
        summaryEn: "Safety-review the current list: flag items that should be kept (login state, keys, data shared with other apps), explain why, and uncheck them.",
        args: [
            SkillArg(name: "scope", required: false,
                     desc: L10n.t("apps 分析应用清单（默认），leftovers 分析残留清单",
                                  "apps (default) reviews the app list; leftovers reviews the leftovers list"),
                     options: ["apps", "leftovers"])
        ],
        risk: .mutating
    )

    func invoke(_ args: SkillArgs, session: AgentSession) async -> SkillResult {
        // 深链时由 UI 入口强制注入分析范围，避免模型把应用清单误判为残留。
        // 若 session 没注入（例如 CLI 直接调用），再退回到模型传入的 scope 参数。
        let scope = session.reviewScope?.rawValue ?? args.string("scope", default: "apps").lowercased()

        if scope == "leftovers" {
            // 优先分析用户已勾选的残留项；没有勾选时才按来源约束/全部判断。
            let selected = session.reviewableLeftovers
            let source = session.reviewLeftoverFilter
            let targetArtifacts: [Artifact]
            let scopeNote: String
            if !selected.isEmpty {
                targetArtifacts = selected
                scopeNote = L10n.t("已勾选的 \(selected.count) 项残留",
                                   "the \(selected.count) selected leftover items")
            } else {
                let groups = source.map { s in session.lastLeftovers.filter { $0.source == s } }
                              ?? session.lastLeftovers
                targetArtifacts = groups.flatMap(\.artifacts)
                scopeNote = {
                    guard let s = source else { return L10n.t("全部残留", "all leftovers") }
                    switch s {
                    case .orphan:   return L10n.t("无主残留", "orphaned leftovers")
                    case .aiTool:   return L10n.t("AI 编程工具残留", "AI coding-tool leftovers")
                    case .devCache: return L10n.t("开发工具缓存", "dev-tool caches")
                    }
                }()
            }
            guard !targetArtifacts.isEmpty else {
                return .failure(L10n.t("还没有残留清单，请先调用 scan_leftovers。",
                                       "No leftovers list yet — call scan_leftovers first."))
            }
            guard let cfg = ModelConfigStore.current.active, cfg.isConfigured else {
                return SkillResult(ok: false,
                    summary: L10n.t("AI 分析需要先在设置里配置模型。",
                                    "AI review needs a model configured in Settings first."),
                    observation: L10n.t("「问 AI」是纯 AI 模块，分析功能需要先填好 API Key（OpenAI / Anthropic 兼容）。",
                                        "Ask AI is a pure-AI module; review needs an API key (OpenAI- or Anthropic-compatible) set first."))
            }
            // 分析由真正的模型执行，不再用本地规则兜底。
            guard let safeReasons = await AIJury.reviewLeftovers(targetArtifacts, config: cfg) else {
                return SkillResult(ok: false,
                    summary: L10n.t("AI 分析调用失败，请检查 API Key / 网络。",
                                    "AI review call failed — check the API key / network."),
                    observation: L10n.t("模型没能返回有效结论，可稍后重试。",
                                        "The model didn't return a valid verdict; try again later."))
            }
            let verdicts = safeReasons.reduce(into: [UUID: AIVerdict]()) { $0[$1.key] = .safe(reason: $1.value) }
            let summary = L10n.t("分析完成（\(scopeNote)）：\(verdicts.count) 项判定为可安全删除，已自动勾选。",
                                 "Review done (\(scopeNote)): \(verdicts.count) items judged safe to remove and checked.")
            let detail = targetArtifacts.filter { verdicts[$0.id] != nil }.prefix(10)
                .map { "  ✓ \($0.path) — \(safeReasons[$0.id] ?? "")" }
                .joined(separator: "\n")
            return SkillResult(ok: true, summary: summary,
                               observation: summary + (detail.isEmpty ? "" : "\n" + detail),
                               effect: .reviewLeftovers(verdicts), redirect: .leftovers)
        }

        let artifacts = session.reviewableArtifacts
        guard !artifacts.isEmpty else {
            return .failure(L10n.t("当前没有待分析的清单，请先调用 scan_app。",
                                   "Nothing to review — call scan_app first."))
        }
        guard let cfg = ModelConfigStore.current.active, cfg.isConfigured else {
            return SkillResult(ok: false,
                summary: L10n.t("AI 分析需要先在设置里配置模型。",
                                "AI review needs a model configured in Settings first."),
                observation: L10n.t("「问 AI」是纯 AI 模块，分析功能需要先填好 API Key（OpenAI / Anthropic 兼容）。",
                                    "Ask AI is a pure-AI module; review needs an API key (OpenAI- or Anthropic-compatible) set first."))
        }
        // 分析由真正的模型执行，不再用本地规则兜底。
        guard let keepReasons = await AIJury.reviewApps(artifacts, config: cfg) else {
            return SkillResult(ok: false,
                summary: L10n.t("AI 分析调用失败，请检查 API Key / 网络。",
                                "AI review call failed — check the API key / network."),
                observation: L10n.t("模型没能返回有效结论，可稍后重试。",
                                    "The model didn't return a valid verdict; try again later."))
        }
        let kept = artifacts.filter { keepReasons[$0.id] != nil }
        let deletable = artifacts.filter { keepReasons[$0.id] == nil }
        let safeReason = L10n.t("AI 分析认为可安全删除", "AI analysis: safe to delete")
        var verdicts: [UUID: AIVerdict] = [:]
        for a in artifacts {
            if let reason = keepReasons[a.id] {
                verdicts[a.id] = .keep(reason: reason)
            } else {
                verdicts[a.id] = .safe(reason: safeReason)
            }
        }
        if kept.isEmpty {
            let msg = L10n.t("分析完成：\(artifacts.count) 项均可安全删除，没有发现需要保留的项目。仍建议自己扫一眼含用户数据的条目。",
                             "Review done: all \(artifacts.count) items are safe to delete; none stands out as must-keep. Still worth eyeballing the user-data items.")
            return SkillResult(ok: true, summary: msg, observation: msg,
                               effect: .reviewApps(verdicts), redirect: .apps)
        }
        // 明确分两类说清楚：建议保留的（已自动取消勾选）+ 可安全删除的（保持勾选），
        // 避免只列保留项让用户去反推哪些能删。
        let summary = L10n.t("分析完成：\(kept.count) 项建议保留（已自动取消勾选），其余 \(deletable.count) 项可安全删除。",
                             "Review done: \(kept.count) recommended to keep (auto-unchecked), the other \(deletable.count) are safe to delete.")
        let keepDetail = kept.prefix(12)
            .map { "  ✗ \($0.path) — \(keepReasons[$0.id] ?? "")" }
            .joined(separator: "\n")
        let delDetail = deletable.prefix(8)
            .map { "  ✓ \($0.path)" }
            .joined(separator: "\n")
        let obs = summary + "\n" + L10n.t("建议保留：", "Keep:") + "\n" + keepDetail
                  + (delDetail.isEmpty ? "" : "\n" + L10n.t("可安全删除：", "Safe to delete:") + "\n" + delDetail)
        return SkillResult(ok: true, summary: summary,
                           observation: obs,
                           effect: .reviewApps(verdicts), redirect: .apps)
    }
}

// MARK: - plan_uninstall

/// `ai-mac-cleaner --uninstall <target> --dry-run`
///
/// 名字里的 `plan` 是承诺：这个 skill **永远只出计划**。
/// Agent 拿不到「真的删掉」这个动作 —— 那需要用户在确认弹窗上点一下，
/// 或者自己在终端里敲不带 `--dry-run` 的命令。
struct PlanUninstallSkill: AgentSkill {
    let spec = SkillSpec(
        name: "plan_uninstall",
        cli: "--uninstall <target> --dry-run",
        summaryZh: "为卸载某个应用生成执行计划：会删哪些、共多大、哪些进废纸篓。只预演，不删除。",
        summaryEn: "Draft an uninstall plan for an app: what would be removed, how large, what goes to the Trash. Preview only, nothing is deleted.",
        args: [
            SkillArg(name: "target", required: true,
                     desc: L10n.t("应用名或关键词", "App name or keyword")),
            SkillArg(name: "include_userdata", required: false,
                     desc: L10n.t("是否把用户数据（聊天记录、登录态等）也算进计划，默认 false",
                                  "Whether to include user data (chat history, login state…) in the plan; default false"))
        ],
        risk: .destructive
    )

    func invoke(_ args: SkillArgs, session: AgentSession) async -> SkillResult {
        guard let target = args["target"] else {
            return .failure(L10n.t("plan_uninstall 需要 target 参数", "plan_uninstall requires a target argument"))
        }
        let includeUserData = args.bool("include_userdata")

        // 同一目标刚扫过就直接复用 —— 扫描是这里最贵的一步，
        // 让模型「先扫再规划」不该付两遍钱。
        var artifacts: [Artifact]
        var resolvedName = target
        var matched: AppIdentity?
        if let last = session.lastTarget,
           last.lowercased() == target.lowercased() || target.lowercased().contains(last.lowercased()),
           !session.lastArtifacts.isEmpty {
            artifacts = session.lastArtifacts
            resolvedName = last
        } else {
            let query = AppState.resolveQuery(from: target)
            matched = query.app
            resolvedName = query.displayTarget
            var found: [Artifact] = []
            for scanner in CLIScan.allScanners {
                found.append(contentsOf: await scanner.scan(query: query))
            }
            var seen = Set<String>()
            found = found.filter { seen.insert($0.path).inserted }
            for i in found.indices { found[i].selected = true }
            artifacts = found
            session.lastTarget = resolvedName
            session.lastArtifacts = found
        }

        guard !artifacts.isEmpty else {
            let msg = L10n.t("没有找到 \(resolvedName) 的痕迹，无需卸载。",
                             "No traces found for \(resolvedName) — nothing to uninstall.")
            return SkillResult(ok: true, summary: msg, observation: msg)
        }

        // 计划口径与真实执行链一致：safe 直接删，userData 进废纸篓；
        // 不勾选用户数据时，那些项只是列出来供参考。
        let planned = artifacts.filter { includeUserData || $0.risk == .safe }
        let skipped = artifacts.filter { a in !planned.contains(where: { p in p.id == a.id }) }
        let plannedSize = planned.reduce(Int64(0)) { $0 + $1.size }
        let toTrash = planned.filter { $0.risk == .userData }
        let hardDelete = planned.filter { $0.risk != .userData }

        var summary = L10n.t(
            "卸载计划（预演，未执行）：\(resolvedName) 共 \(planned.count) 项 / \(SizeFormat.human(plannedSize))。",
            "Uninstall plan (preview, not executed): \(resolvedName), \(planned.count) items / \(SizeFormat.human(plannedSize)).")
        if !skipped.isEmpty {
            summary += L10n.t(" 另有 \(skipped.count) 项用户数据未列入（可要求包含）。",
                              " \(skipped.count) user-data items excluded (ask to include them).")
        }

        var obs = summary
        if let app = matched, let bid = app.bundleId {
            obs += "\n" + L10n.t("锁定应用：\(app.displayName) [\(bid)]", "Resolved app: \(app.displayName) [\(bid)]")
        }
        obs += "\n" + L10n.t(
            "直接删除 \(hardDelete.count) 项 / \(SizeFormat.human(hardDelete.reduce(0) { $0 + $1.size }))；" +
            "移入废纸篓 \(toTrash.count) 项 / \(SizeFormat.human(toTrash.reduce(0) { $0 + $1.size }))",
            "Delete outright: \(hardDelete.count) / \(SizeFormat.human(hardDelete.reduce(0) { $0 + $1.size })); " +
            "move to Trash: \(toTrash.count) / \(SizeFormat.human(toTrash.reduce(0) { $0 + $1.size }))")
        obs += "\n" + AgentFormat.topPaths(planned, limit: 10)
        if !skipped.isEmpty {
            obs += "\n" + L10n.t("未列入的用户数据：", "Excluded user data: ")
                + skipped.prefix(5).map { ($0.path as NSString).lastPathComponent }.joined(separator: ", ")
        }
        obs += "\n" + L10n.t(
            "【重要】这只是计划。你没有执行删除的权限 —— 请让用户到「应用」页核对清单后点确认，或自行运行 ai-mac-cleaner --uninstall \(resolvedName)。",
            "[IMPORTANT] This is only a plan. You cannot execute deletions — ask the user to review the list in the Apps tab and confirm, or run ai-mac-cleaner --uninstall \(resolvedName) themselves.")

        return SkillResult(ok: true, summary: summary, observation: obs,
                           effect: .appScan(target: resolvedName, app: matched, artifacts: artifacts),
                           redirect: .apps, awaitingApproval: true)
    }
}

// MARK: - plan_slim

/// `ai-mac-cleaner --reset <target> --dry-run`
///
/// 「瘦身 / 重置」的计划 skill：**app 本体保留**，只清它留在用户目录里的数据。
/// 与 `plan_uninstall` 的本质差异在筛选口径（复用 `SlimMode` 的语义，与 GUI 完全一致）：
/// - 两种档位都只留 `mode.eligibleCategories`（数据类），安装物 / 自启动 / 同厂商产品绝不进清单；
/// - `cache`（轻量瘦身）进一步剔除 `.userData`，不会掉登录；
/// - `full`（彻底重置）包含用户数据，逼近「刚装好第一次打开」，确认弹窗里有强警告。
struct PlanSlimSkill: AgentSkill {
    let spec = SkillSpec(
        name: "plan_slim",
        cli: "--reset <target> --dry-run",
        summaryZh: "为某个应用生成瘦身/重置计划：只清它留在用户目录里的数据，app 本体保留。mode=cache 只清缓存（不掉登录），mode=full 连配置/登录态一起清（等同新装）。只预演，不删除。",
        summaryEn: "Draft a slim/reset plan for an app: clears only the data it leaves in your home directory; the app itself stays. mode=cache clears rebuildable caches only (you stay signed in), mode=full also clears config/login state (like a fresh install). Preview only, nothing is deleted.",
        args: [
            SkillArg(name: "target", required: true,
                     desc: L10n.t("应用名或关键词", "App name or keyword")),
            SkillArg(name: "mode", required: false,
                     desc: L10n.t("cache=轻量瘦身（默认）；full=彻底重置", "cache=light slim (default); full=full reset"),
                     options: ["cache", "full"])
        ],
        risk: .destructive
    )

    func invoke(_ args: SkillArgs, session: AgentSession) async -> SkillResult {
        guard let target = args["target"] else {
            return .failure(L10n.t("plan_slim 需要 target 参数", "plan_slim requires a target argument"))
        }
        let mode: SlimMode = args.string("mode", default: "cache").lowercased() == "full" ? .fullReset : .cacheOnly

        // 解析 + 扫描与 plan_uninstall 同一套：复用会话缓存，扫描只付一次钱。
        var artifacts: [Artifact]
        var resolvedName = target
        var matched: AppIdentity?
        if let last = session.lastTarget,
           last.lowercased() == target.lowercased() || target.lowercased().contains(last.lowercased()),
           !session.lastArtifacts.isEmpty {
            artifacts = session.lastArtifacts
            resolvedName = last
        } else {
            let query = AppState.resolveQuery(from: target)
            matched = query.app
            resolvedName = query.displayTarget
            var found: [Artifact] = []
            for scanner in CLIScan.allScanners {
                found.append(contentsOf: await scanner.scan(query: query))
            }
            var seen = Set<String>()
            found = found.filter { seen.insert($0.path).inserted }
            artifacts = found
            session.lastTarget = resolvedName
            session.lastArtifacts = found
        }
        guard let app = matched else {
            let msg = L10n.t(
                "没有找到名为 \(resolvedName) 的已安装应用，无法瘦身。瘦身只对还装着的 app 有意义；要清残留请用卸载。",
                "No installed app named \(resolvedName) — cannot slim. Slimming only applies to installed apps; use uninstall for leftovers.")
            return SkillResult(ok: true, summary: msg, observation: msg)
        }

        // 筛选口径与 GUI 的 `slim(app:mode:)` 完全一致（见 SlimMode 的逐条注释）。
        var planned = artifacts.filter { mode.eligibleCategories.contains($0.category) }
        if !mode.includesUserData {
            planned = planned.filter { $0.risk != .userData }
        }
        guard !planned.isEmpty else {
            let msg = L10n.t(
                "\(app.displayName) 在这一档下没有可清理的数据项。",
                "Nothing to clear for \(app.displayName) at this level.")
            return SkillResult(ok: true, summary: msg, observation: msg)
        }
        // 勾选口径由 GUI 落地时套用（applySlimPlan），这里保持扫描原样即可。

        let plannedSize = planned.reduce(Int64(0)) { $0 + $1.size }
        let verb = mode == .cacheOnly
            ? L10n.t("瘦身计划", "Slim plan")
            : L10n.t("重置计划", "Reset plan")
        var summary = L10n.t(
            "\(verb)（预演，未执行）：\(app.displayName) 共 \(planned.count) 项 / \(SizeFormat.human(plannedSize))，app 本体保留。",
            "\(verb) (preview, not executed): \(app.displayName), \(planned.count) items / \(SizeFormat.human(plannedSize)). The app itself stays.")
        if mode == .fullReset {
            summary += L10n.t(" 含登录态/配置，执行后会退出登录。",
                              " Includes login state/config; executing signs you out.")
        }

        var obs = summary
        if let bid = app.bundleId {
            obs += "\n" + L10n.t("锁定应用：\(app.displayName) [\(bid)]", "Resolved app: \(app.displayName) [\(bid)]")
        }
        obs += "\n" + AgentFormat.topPaths(planned, limit: 10)
        obs += "\n" + L10n.t(
            "【重要】这只是计划。你没有执行删除的权限 —— 请让用户到「应用」页核对清单后点确认。",
            "[IMPORTANT] This is only a plan. You cannot execute deletions — ask the user to review the list in the Apps tab and confirm.")

        return SkillResult(ok: true, summary: summary, observation: obs,
                           effect: .slimPlan(target: app.displayName, app: app, mode: mode, artifacts: planned),
                           redirect: .apps, awaitingApproval: true)
    }
}
