import Foundation

/// 调查类 skill：让 Agent 拥有「翻目录 / 读内容」的能力。
///
/// ## 为什么内置扫描器不够
///
/// 14 个内置扫描器全是「关键词命中即报」。漏项的形状恰恰是「关键词对不上」：
/// StoryFab 的 bundle id 是 `com.story-fab.desktop`，关键词下发的是
/// `com.story-fab.desktop` 与 `storyfab`（去连字符），而它的数据目录叫
/// **`story-fab`（带连字符）** —— 谁也匹配不上。
///
/// 破局办法不是「把prompt 写得更长」，而是给模型两只手：
/// `search_paths`（拿**宽 token** 去枚举，别只信 app 名）+ `inspect_path`
/// （打开看内容，用证据确认归属）。这正是人类排查这件事时的做法。
///
/// ## 安全边界（与其它 skill 完全一致）
///
/// - `list_trace_roots` / `search_paths` / `inspect_path` 是 **readOnly**：
///   只读元数据与极短文件头，不写、不删、不联网、不执行任何子进程。
/// - `search_paths` 只在 `FileDeleter` 白名单目录内枚举，命中的每条再过一遍白名单。
/// - `propose_paths` 是 **mutating**：只往当前清单里加候选，**永不代表授权删除**；
///   每条都要过 `AIScanProposer.judge` 校验网，且**永不默认勾选**。
///   删除仍然只发生在用户勾选 + 确认弹窗之后。

// MARK: - list_trace_roots

/// `ai-mac-cleaner --trace-roots`
struct ListTraceRootsSkill: AgentSkill {
    let spec = SkillSpec(
        name: "list_trace_roots",
        cli: "--trace-roots",
        summaryZh: "列出本机会被扫描的痕迹根目录（Application Support / Caches / WebKit / Cookies / LaunchAgents / XDG…），并说明每个目录通常装什么。不知道该往哪找时先调它。",
        summaryEn: "List the trace root directories that get scanned (Application Support, Caches, WebKit, Cookies, LaunchAgents, XDG…) and what each usually holds. Call this when you don't know where to look.",
        risk: .readOnly
    )

    func invoke(_ args: SkillArgs, session: AgentSession) async -> SkillResult {
        let roots = PathProbe.roots
        guard !roots.isEmpty else {
            let msg = L10n.t("没有可搜索的痕迹目录。", "No searchable trace roots.")
            return SkillResult(ok: true, summary: msg, observation: msg)
        }
        let rows = roots.map { r in
            let n = (try? FileManager.default.contentsOfDirectory(atPath: r.path).count) ?? 0
            return "  \(r.path)  [\(n) 项]  — \(r.holds)"
        }.joined(separator: "\n")
        let summary = L10n.t("共 \(roots.count) 个痕迹根目录可搜索。", "\(roots.count) trace roots are searchable.")
        return SkillResult(ok: true, summary: summary, observation: summary + "\n" + rows)
    }
}

// MARK: - search_paths

/// `ai-mac-cleaner --search <token>`
struct SearchPathsSkill: AgentSkill {
    let spec = SkillSpec(
        name: "search_paths",
        cli: "--search <token>",
        summaryZh: "用一个**宽泛**关键词在所有痕迹目录里枚举候选路径。两侧都会忽略 - _ . 空格，所以搜 story 能同时命中 story-fab / StoryFab / story_fab —— 内置扫描器正是在这种「形状对不上」上漏项的。只列第一层，不递归。",
        summaryEn: "Enumerate candidate paths across all trace roots using a BROAD keyword. Separators (- _ . space) are ignored on both sides, so searching \"story\" matches story-fab, StoryFab and story_fab alike — exactly the shape where the built-in scanners miss things. First level only, no recursion.",
        args: [
            SkillArg(name: "token", required: true,
                     desc: L10n.t("宽泛关键词，取名字的一部分即可，如 story / ccswitch /微信",
                                  "Broad keyword — a fragment of the name, e.g. story / ccswitch")),
            SkillArg(name: "limit", required: false,
                     desc: L10n.t("最多返回几条，默认 40", "Max entries, default 40"))
        ],
        risk: .readOnly
    )

    func invoke(_ args: SkillArgs, session: AgentSession) async -> SkillResult {
        guard let token = args["token"], PathProbe.normalize(token).count >= 2 else {
            return .failure(L10n.t("search_paths 需要一个至少 2 个字符的宽泛 token",
                                   "search_paths needs a broad token of at least 2 characters"))
        }
        let limit = max(1, min(args.int("limit", default: 40), 120))
        let known = Set(session.reviewableArtifacts.map(\.path))
        let hits = PathProbe.search(token: token, known: known, limit: limit)

        guard !hits.isEmpty else {
            let msg = L10n.t("没有匹配「\(token)」的痕迹。换个更宽的 token 再试（如厂商名或 bundle id 的一段）。",
                             "Nothing matched “\(token)”. Try a broader token (a vendor name or part of the bundle id).")
            return SkillResult(ok: true, summary: msg, observation: msg)
        }

        let fresh = hits.filter { !$0.alreadyKnown }
        let rows = hits.map { h -> String in
            let mark = h.alreadyKnown
                ? L10n.t("（已在清单里）", "(already in the list)")
                : L10n.t("（清单里没有）", "(NOT in the list)")
            return "  [\(h.category.rawValue)] \(h.path)  (\(h.isDirectory ? "dir" : "file"), \(SizeFormat.human(h.size)))\(mark)"
        }.joined(separator: "\n")
        let summary = L10n.t(
            "「\(token)」命中 \(hits.count) 项，其中 \(fresh.count) 项不在当前清单里。用 inspect_path 逐个确认归属后再 propose_paths。",
            "“\(token)” matched \(hits.count) entries, \(fresh.count) of which are NOT in the current list. Verify each with inspect_path, then propose_paths.")
        let hint = "\n" + L10n.t(
            "注意：搜「story」这种宽 token 会捞到无关项（如 com.apple.*、其它软件的 story 功能），这是正常的 —— 归属要靠 inspect_path 确认，不要凭名字猜。",
            "Note: a broad token also matches unrelated entries (com.apple.*, other apps' \"story\" features). That's expected — confirm ownership with inspect_path instead of guessing from names.")
        return SkillResult(ok: true, summary: summary,
                           observation: summary + "\n" + rows + hint)
    }
}

// MARK: - inspect_path

/// `ai-mac-cleaner --inspect <path>`
struct InspectPathSkill: AgentSkill {
    let spec = SkillSpec(
        name: "inspect_path",
        cli: "--inspect <path>",
        summaryZh: "打开一个路径看它到底是什么：大小、内容类型（崩溃报告 / 数据库 / 配置 / 日志）、子项名，以及**是否被某个已安装应用认领**。归属判断的硬证据来自这里——技术栈、文件内容比名字可靠得多。",
        summaryEn: "Open a path and see what it actually is: size, content kind (crash report, database, config, log), child names, and whether an installed app claims it. Ownership evidence lives here — stack traces and file content are far more reliable than names.",
        args: [
            SkillArg(name: "path", required: true,
                     desc: L10n.t("绝对路径，必须在可扫描的白名单目录内",
                                  "Absolute path, must be inside a scannable allow-listed root"))
        ],
        risk: .readOnly
    )

    func invoke(_ args: SkillArgs, session: AgentSession) async -> SkillResult {
        guard let path = args["path"] else {
            return .failure(L10n.t("inspect_path 需要 path 参数", "inspect_path requires a path argument"))
        }
        guard FileDeleter.isAllowed(path) else {
            return .failure(L10n.t("这个路径不在可检查的白名单内，已拒绝。",
                                   "That path is outside the inspectable allow-list — refused."))
        }
        // 排除目标 app 自身：否则它的数据目录会被判成「被已装应用认领」，
        // agent 就会把最该上报的那一项当成别人的东西丢掉（StoryFab 的
        // Application Support/story-fab 就是这么被误判的）。
        let info = PathProbe.inspect(path, excluding: session.lastApp)
        guard info.exists else {
            return SkillResult(ok: false, summary: L10n.t("路径不存在：\(info.path)", "Path does not exist: \(info.path)"),
                               observation: "ERROR: 不存在 / not found")
        }

        var obs = L10n.t("路径：\(info.path)", "Path: \(info.path)") + "\n"
        obs += L10n.t("类型：\(info.kind)", "Kind: \(info.kind)") + "\n"
        obs += L10n.t("大小：\(SizeFormat.human(info.size))",
                      "Size: \(SizeFormat.human(info.size))") + "\n"
        if info.isDirectory {
            obs += L10n.t("子项：\(info.childCount) 个", "Children: \(info.childCount)") + "\n"
            if !info.children.isEmpty { obs += "  " + info.children.joined(separator: ", ") + "\n" }
        }
        obs += L10n.t("归属线索：\(info.ownerHint)", "Ownership: \(info.ownerHint)") + "\n"
        if let c = info.claimedByLiveApp {
            obs += L10n.t("⚠️ 已被已安装应用「\(c)」认领 —— 绝不能作为目标 app 的残留删除。",
                          "⚠️ Claimed by installed app “\(c)” — must never be deleted as this target's leftover.") + "\n"
        }
        let summary = L10n.t("\(info.kind) · \(SizeFormat.human(info.size))",
                             "\(info.kind) · \(SizeFormat.human(info.size))")
        return SkillResult(ok: true, summary: summary, observation: obs)
    }
}

// MARK: - propose_paths

/// `ai-mac-cleaner --propose <path[,path…]>`
///
/// 把调查到的候选交给校验网。**这是唯一能把路径带进清单的入口**，
/// 因此模型无法绕过校验——它只能「提名」，不能「入库」。
struct ProposePathsSkill: AgentSkill {
    let spec = SkillSpec(
        name: "propose_paths",
        cli: "--propose <path>",
        summaryZh: "把调查到的候选路径提交进清单。每条都会过本地校验网（系统路径黑名单 / 白名单 / 保护根 / 活 app 反查 / 你的 /remember 豁免 / 必须真实存在），不过就丢弃。入库项一律不勾选——删不删由你决定。",
        summaryEn: "Submit candidate paths into the list. Each one passes local validation (system block-list, allow-list, protected roots, live-app reverse lookup, your /remember exemptions, must exist) and is dropped if it fails. Entries are never checked by default — you decide.",
        args: [
            SkillArg(name: "path", required: true,
                     desc: L10n.t("候选绝对路径，多个用英文逗号分隔。只提交你用 inspect_path 确认过归属的",
                                  "Candidate absolute paths, comma-separated. Only submit ones you verified with inspect_path"))
        ],
        risk: .mutating
    )

    func invoke(_ args: SkillArgs, session: AgentSession) async -> SkillResult {
        guard let raw = args["path"] else {
            return .failure(L10n.t("propose_paths 需要 path 参数", "propose_paths requires a path argument"))
        }
        guard let app = session.lastApp else {
            return .failure(L10n.t(
                "先调 scan_app 锁定目标应用，再提交候选路径（校验网需要知道「除目标外的其它活 app」）。",
                "Call scan_app first to lock the target app, then submit candidates (validation needs to know the other live apps)."))
        }

        let candidates = raw.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        guard !candidates.isEmpty else {
            return .failure(L10n.t("没有解析到任何候选路径", "No candidate paths parsed"))
        }

        let context = AIScanProposer.Context.build(app: app)
        let known = Set(session.reviewableArtifacts.map(\.path))
        var accepted: [Artifact] = []
        var rejected: [String] = []

        for c in candidates {
            let std = (c as NSString).expandingTildeInPath
            if let reason = AIScanProposer.rejectionReason(std, known: known, context: context) {
                rejected.append("\(std) — \(Self.reasonText(reason))")
                continue
            }
            guard case .accept(let path) = AIScanProposer.judge(std, known: known, context: context),
                  !accepted.contains(where: { $0.path == path }) else { continue }
            var a = AIScanProposer.makeArtifact(path: path,
                                                reason: L10n.t("Agent 调查发现", "found by the agent's investigation"))
            a.source = ArtifactSource.aiProposer
            accepted.append(a)
        }

        // 收尾：整批都没过时不要动清单（避免把用户已有的清单清空）。
        if !accepted.isEmpty {
            session.proposedArtifacts.append(contentsOf: accepted)
        }

        let target = session.lastTarget ?? app.displayName
        var summary = L10n.t("提交 \(candidates.count) 条候选，采纳 \(accepted.count) 条。",
                             "Submitted \(candidates.count) candidate(s), \(accepted.count) accepted.")
        if !rejected.isEmpty {
            summary += " " + L10n.t("丢弃 \(rejected.count) 条。", "\(rejected.count) dropped.")
        }
        var obs = summary + "\n"
        if !accepted.isEmpty {
            obs += L10n.t("已采纳（入库且不勾选）：", "Accepted (added, unchecked):") + "\n"
            obs += accepted.map { "  \($0.path)  (\(SizeFormat.human($0.size)))" }.joined(separator: "\n") + "\n"
        }
        if !rejected.isEmpty {
            obs += L10n.t("被校验网丢弃：", "Rejected by validation:") + "\n"
            obs += rejected.map { "  \($0)" }.joined(separator: "\n") + "\n"
        }
        obs += L10n.t("这些只是候选，删除仍需用户在界面上勾选并确认。",
                      "These are candidates only; removal still needs the user to select and confirm in the UI.")

        return SkillResult(ok: true, summary: summary, observation: obs,
                           effect: accepted.isEmpty ? .none
                               : .proposedArtifacts(target: target, artifacts: accepted),
                           redirect: nil)
    }

    /// 把 `AIScanProposer.Rejection` 翻成人话，让模型知道自己错在哪、下次该怎么改。
    private static func reasonText(_ r: AIScanProposer.Rejection) -> String {
        switch r {
        case .empty:          return L10n.t("路径为空", "empty path")
        case .wildcard:       return L10n.t("含通配符", "contains a wildcard")
        case .relative:       return L10n.t("不是绝对路径", "not an absolute path")
        case .forbidden:      return L10n.t("属于系统路径，禁止触碰", "system path — forbidden")
        case .notAllowed:     return L10n.t("不在可删除白名单内", "outside the allow-list")
        case .protectedRoot:  return L10n.t("是容器级大目录本身", "a protected umbrella directory")
        case .insideAppBundle:return L10n.t("在 app 包内部（随app 一起处理）", "inside the app bundle")
        case .systemOwned:    return L10n.t("名字属于系统/框架自有", "system/framework-owned name")
        case .claimedByOtherApp: return L10n.t("被别的已安装应用认领", "claimed by another installed app")
        case .userExempt:     return L10n.t("你用 /remember 豁免过", "exempted via /remember")
        case .alreadyKnown:   return L10n.t("已经在清单里了", "already in the list")
        case .missing:        return L10n.t("路径不存在", "path does not exist")
        }
    }
}