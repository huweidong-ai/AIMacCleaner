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
    static let all: [AgentSkill] = [
        ListAppsSkill(),
        ScanAppSkill(),
        ScanLeftoversSkill(),
        ListProcessesSkill(),
        ReviewPlanSkill(),
        PlanUninstallSkill(),
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
        case "leftovers", "orphans":              return "scan_leftovers"
        case "ps", "processes", "list_process":   return "list_processes"
        case "review":                            return "review_plan"
        case "list", "apps":                      return "list_apps"
        case "history":                           return "show_history"
        case "plan", "dry_run", "dryrun":         return "plan_uninstall"
        default:                                  return nil
        }
    }

    /// 给模型的工具清单。加一个 skill，提示词自动跟着变 —— 这是把能力
    /// 抽象成 skill 层最直接的收益。
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
            out += "    CLI: expunge \(spec.cli)   [\(spec.risk.label)]\n"
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
