import Foundation

/// Skill 注册表 —— Agent 能做的事情的**唯一清单**。
///
/// 它同时是三样东西的来源：
/// - 模型看到的工具清单（`manifest`，自动生成，加 skill 不用改 prompt）
/// - `ai-mac-cleaner --skills` 打印的人类可读清单
/// - 运行时的白名单：`resolve` 找不到的名字一律拒绝执行
///
/// **白名单是安全边界**。Agent 唯一能触发的外部动作就是这张表里的 skill，
/// 而每个 skill 背后都是 AI Mac Cleaner 自己的 CLI 能力 —— 没有通用 shell、
/// 没有任意文件读写、没有网络请求。模型编出 `rm -rf ~` 这种指令时，
/// 它连一个能承接的入口都找不到。
enum SkillRegistry {

    /// 注册顺序 = 清单展示顺序，按「先看后想再做」排。
    ///
    /// 调查三件套（`list_trace_roots` → `search_paths` → `inspect_path`）
    /// 紧跟在 `scan_app` 之后：内置扫描器「命中即报、漏了就是漏了」，
    /// 模型想真正**发现**漏项，就得先扫一遍、再自己翻目录核对。
    /// `propose_paths` 紧随其后——它是唯一能把路径带进清单的入口。
    static let all: [AgentSkill] = [
        DescribeSkillSkill(),
        ListAppsSkill(),
        ScanAppSkill(),
        CheckInstallsSkill(),
        ListTraceRootsSkill(),
        SearchPathsSkill(),
        InspectPathSkill(),
        ProposePathsSkill(),
        ScanLeftoversSkill(),
        ListProcessesSkill(),
        ReviewPlanSkill(),
        PlanUninstallSkill(),
        PlanSlimSkill(),
        ShowHistorySkill()
    ]

    static var specs: [SkillSpec] { all.map(\.spec) }

    static var names: [String] { specs.map(\.name) }

    /// 按名字取 skill。**这就是白名单** —— 返回 nil 即拒绝执行。
    static func resolve(_ name: String) -> AgentSkill? {
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return all.first { $0.spec.name == key } ?? all.first { alias(for: key) == $0.spec.name }
    }

    /// 口语别名 → 正式 skill 名。
    ///
    /// 存在的原因有两个：一是模型偶尔会把工具名写成自然的动词（"scan"、"ps"）；
    /// 二是 v1.5 的旧提示词就用的这套短词，留着它旧会话不会突然失灵。
    private static func alias(for key: String) -> String? {
        switch key {
        case "scan", "uninstall", "clean":        return "scan_app"
        case "installs", "brew":                  return "check_installs"
        case "leftovers", "orphans":              return "scan_leftovers"
        case "ps", "processes", "list_process":   return "list_processes"
        case "review":                            return "review_plan"
        case "list", "apps":                      return "list_apps"
        case "history":                           return "show_history"
        case "plan", "dry_run", "dryrun":         return "plan_uninstall"
        case "slim", "reset":                     return "plan_slim"
        default:                                  return nil
        }
    }

    /// 给模型的**紧凑工具目录**：只有名字 + 一句话摘要，没有参数明细。
    ///
    /// 为什么不全量注入 manifest：那 13 个 skill 的参数说明每轮都原样重发，
    /// 是 agent 固定 token 开销的大头（OpenClaw 的做法也一样：只给 metadata，
    /// 完整指令按需 read）。模型要调用哪个，先用 `describe_skill` 取它的参数声明。
    static var briefCatalog: String {
        specs.map { "- \($0.name)：\($0.summary)" }.joined(separator: "\n")
    }

    /// 完整工具清单（仍供 CLI / 排障用；提示词不再直接使用）。
    static var manifest: String {
        specs.map(\.manifestLine).joined(separator: "\n")
    }

    /// `ai-mac-cleaner --skills` 的输出。
    static var cliListing: String {
        var out = L10n.t("AI Mac Cleaner Agent 可调用的 skill（共 \(all.count) 个）：\n",
                         "Skills available to the AI Mac Cleaner agent (\(all.count) total):\n")
        for spec in specs {
            let sig = spec.args.map { $0.required ? "<\($0.name)>" : "[\($0.name)]" }.joined(separator: " ")
            out += "\n  \(spec.name) \(sig)\n"
            out += "    \(spec.summary)\n"
            out += "    CLI: \(AgentRuntime.cliBinaryName) \(spec.cli)   [\(spec.risk.label)]\n"
            for a in spec.args {
                let mark = a.required ? "*" : " "
                var line = "      \(mark) \(a.name)"
                if !a.options.isEmpty { line += " (\(a.options.joined(separator: "|")))" }
                out += line + " — \(a.desc)\n"
            }
        }
        out += "\n" + L10n.t(
            "调用方式：ai-mac-cleaner --skill <name> [--args '{\"k\":\"v\"}']，或 ai-mac-cleaner --agent \"用一句话说你想干嘛\"。\n" +
            "所有 skill 都不会删除文件：删除只发生在你确认之后。\n",
            "Usage: ai-mac-cleaner --skill <name> [--args '{\"k\":\"v\"}'], or ai-mac-cleaner --agent \"say what you want in one line\".\n" +
            "No skill deletes anything: removal happens only after you confirm.\n")
        return out
    }

    /// 校验一次调用的参数，返回错误说明（nil 表示通过）。
    static func validate(_ spec: SkillSpec, args: SkillArgs) -> String? {
        for arg in spec.args {
            if let err = arg.validate(args[arg.name]) { return err }
        }
        return nil
    }
}

/// 元 skill：按名字返回另一个 skill 的完整参数声明。
///
/// 这是「skill 按需加载」的关键拼图：system prompt 里只放一行行的名字 + 摘要，
/// 模型确定要用哪个工具时，调一次 describe_skill 拿到参数说明，再发起真正的调用。
/// 它和其他 skill 一样走白名单与同一条 CLI 通道 —— 没有给模型开任何新执行能力。
struct DescribeSkillSkill: AgentSkill {
    let spec = SkillSpec(
        name: "describe_skill",
        cli: "--skill <name>",
        summaryZh: "查某个 skill 的完整参数说明。调用不熟悉的 skill 前先用它确认参数，避免瞎猜。",
        summaryEn: "Get full parameter details for a skill. Use it before calling an unfamiliar skill.",
        args: [
            SkillArg(name: "name", required: true,
                     desc: L10n.t("skill 名称，必须与工具目录里的名字完全一致", "Exact skill name from the catalog"))
        ],
        risk: .readOnly
    )

    func invoke(_ args: SkillArgs, session: AgentSession) async -> SkillResult {
        guard let name = args["name"], let target = SkillRegistry.resolve(name) else {
            return .failure(L10n.t("找不到这个 skill：\(args["name"] ?? "")",
                                   "Unknown skill: \(args["name"] ?? "")"))
        }
        let s = target.spec
        let sig = s.args.map { $0.required ? "<\($0.name)>" : "[\($0.name)]" }.joined(separator: " ")
        var detail = "\(s.name) \(sig)\n\(s.summary)\nCLI: \(AgentRuntime.cliBinaryName) \(s.cli)"
        for a in s.args {
            let mark = a.required ? L10n.t("必填", "required") : L10n.t("可选", "optional")
            let options = a.options.isEmpty ? "" : " [\(a.options.joined(separator: "|"))]"
            detail += "\n- \(a.name) (\(mark)\(options)): \(a.desc)"
        }
        return SkillResult(ok: true,
                           summary: L10n.t("已取得 \(s.name) 的参数说明", "Loaded details for \(s.name)"),
                           observation: detail)
    }
}
