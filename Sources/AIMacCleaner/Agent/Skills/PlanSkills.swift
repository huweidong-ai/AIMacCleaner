import Foundation

/// 决策类 skill：复核清单、预演卸载。
///
/// 这两个是 Agent 能力的边界所在 —— 它们输出的是**判断和计划**，
/// 不是已发生的事实。真正落盘的删除只可能来自用户在界面上的确认。

// MARK: - review_plan

/// `ai-mac-cleaner --review <target>`
struct ReviewPlanSkill: AgentSkill {
    let spec = SkillSpec(
        name: "review_plan",
        cli: "--review <target>",
        summaryZh: "对当前清单做安全复核：挑出不该删的项（登录态、密钥、被其它应用共享的数据）并说明理由，自动取消其勾选。",
        summaryEn: "Safety-review the current list: flag items that should be kept (login state, keys, data shared with other apps), explain why, and uncheck them.",
        args: [
            SkillArg(name: "scope", required: false,
                     desc: L10n.t("apps 复核应用清单（默认），leftovers 复核残留清单",
                                  "apps (default) reviews the app list; leftovers reviews the leftovers list"),
                     options: ["apps", "leftovers"])
        ],
        risk: .mutating
    )

    func invoke(_ args: SkillArgs, session: AgentSession) async -> SkillResult {
        let scope = args.string("scope", default: "apps").lowercased()

        if scope == "leftovers" {
            // 优先复核用户已勾选的残留项；没有勾选时才按来源约束/全部判断。
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
                    summary: L10n.t("AI 复核需要先在设置里配置模型。",
                                    "AI review needs a model configured in Settings first."),
                    observation: L10n.t("「问 AI」是纯 AI 模块，复核功能需要先填好 API Key（OpenAI / Anthropic 兼容）。",
                                        "Ask AI is a pure-AI module; review needs an API key (OpenAI- or Anthropic-compatible) set first."))
            }
            // 复核由真正的模型执行，不再用本地规则兜底。
            guard let verdicts = await AIJury.reviewLeftovers(targetArtifacts, config: cfg) else {
                return SkillResult(ok: false,
                    summary: L10n.t("AI 复核调用失败，请检查 API Key / 网络。",
                                    "AI review call failed — check the API key / network."),
                    observation: L10n.t("模型没能返回有效结论，可稍后重试。",
                                        "The model didn't return a valid verdict; try again later."))
            }
            let summary = L10n.t("复核完成（\(scopeNote)）：\(verdicts.count) 项判定为可安全删除，已自动勾选。",
                                 "Review done (\(scopeNote)): \(verdicts.count) items judged safe to remove and checked.")
            let detail = targetArtifacts.filter { verdicts[$0.id] != nil }.prefix(10)
                .map { "  ✓ \($0.path) — \(verdicts[$0.id] ?? "")" }
                .joined(separator: "\n")
            return SkillResult(ok: true, summary: summary,
                               observation: summary + (detail.isEmpty ? "" : "\n" + detail),
                               effect: .reviewLeftovers, redirect: .leftovers)
        }

        let artifacts = session.reviewableArtifacts
        guard !artifacts.isEmpty else {
            return .failure(L10n.t("当前没有待复核的清单，请先调用 scan_app。",
                                   "Nothing to review — call scan_app first."))
        }
        guard let cfg = ModelConfigStore.current.active, cfg.isConfigured else {
            return SkillResult(ok: false,
                summary: L10n.t("AI 复核需要先在设置里配置模型。",
                                "AI review needs a model configured in Settings first."),
                observation: L10n.t("「问 AI」是纯 AI 模块，复核功能需要先填好 API Key（OpenAI / Anthropic 兼容）。",
                                    "Ask AI is a pure-AI module; review needs an API key (OpenAI- or Anthropic-compatible) set first."))
        }
        // 复核由真正的模型执行，不再用本地规则兜底。
        guard let verdicts = await AIJury.reviewApps(artifacts, config: cfg) else {
            return SkillResult(ok: false,
                summary: L10n.t("AI 复核调用失败，请检查 API Key / 网络。",
                                "AI review call failed — check the API key / network."),
                observation: L10n.t("模型没能返回有效结论，可稍后重试。",
                                    "The model didn't return a valid verdict; try again later."))
        }
        guard !verdicts.isEmpty else {
            let msg = L10n.t("复核完成：这份清单里没有发现明显不该删的项。仍建议自己扫一眼含用户数据的条目。",
                             "Review done: nothing in this list stands out as must-keep. Still worth eyeballing the user-data items.")
            return SkillResult(ok: true, summary: msg, observation: msg,
                               effect: .reviewApps, redirect: .apps)
        }
        let summary = L10n.t("复核完成：\(verdicts.count) 项建议保留，已自动取消勾选。",
                             "Review done: \(verdicts.count) items recommended to keep and now unchecked.")
        let detail = artifacts.filter { verdicts[$0.id] != nil }.prefix(12)
            .map { "  ✗ \($0.path) — \(verdicts[$0.id] ?? "")" }
            .joined(separator: "\n")
        return SkillResult(ok: true, summary: summary,
                           observation: summary + "\n" + detail,
                           effect: .reviewApps, redirect: .apps)
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
