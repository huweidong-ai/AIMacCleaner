import Foundation

/// Agent 的命令行入口。
///
/// 把 `ai-mac-cleaner --agent` / `--skills` / `--skill` / `--ps` / `--review` 接到
/// 与 GUI 完全相同的 skill 层上。CLI 下不创建 `AgentBridge`，整条链不触碰
/// MainActor，用 `Task.detached` + 信号量在 `init()` 里同步退出 —— 和
/// `CLIScan` 里其它子命令的写法保持一致。
enum CLIAgent {

    /// `ai-mac-cleaner --skills`：打印 Agent 可调用的 skill 清单。
    static func printSkills() -> Int32 {
        print(SkillRegistry.cliListing)
        return 0
    }

    /// `ai-mac-cleaner --agent "<目标>" [--model <名称>]`：自然语言驱动的多轮 Agent。
    ///
    /// 纯 AI Agent：必须先在 GUI 的「问 AI」页（或 `defaults` 写入
    /// `expunge.aimodels`）配置好至少一个模型与 API Key，否则直接提示并退出。
    /// 可用 `--model` 按档的显示名 / 模型名 / 协议短名指定用哪个档，不写则用默认档。
    static func runAgent(goal: String, model: String? = nil) -> Int32 {
        guard !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            FileHandle.standardError.write(Data(AIMacCleanerApp.usage.utf8))
            return 2
        }
        let store = ModelConfigStore.current
        let config: AIModelConfig?
        if let model, !model.trimmingCharacters(in: .whitespaces).isEmpty {
            let key = model.trimmingCharacters(in: .whitespaces)
            config = store.profiles.first(where: {
                $0.name == key || $0.model == key || $0.provider.shortLabel == key
            }) ?? store.active
        } else {
            config = store.active
        }
        guard let config, config.isConfigured else {
            FileHandle.standardError.write(Data((AgentRuntime.configPrompt + "\n").utf8))
            return 3
        }
        let sem = DispatchSemaphore(value: 0)
        var code: Int32 = 0
        // 在 detached 之前读好：String 是 Sendable，闭包里就不必再碰存储层。
        // CLI 无 AppState，这里是唯一的记忆来源。
        let memory = MemoryPolicy.promptBlock(MemoryStore.shared.all())
        Task.detached {
            let runtime = AgentRuntime(config: config, bridge: nil, onStep: { step in
                Self.printStep(step)
            }, memory: memory)
            let run = await runtime.run(goal: goal)
            Self.printRun(run)
            code = run.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 1 : 0
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 120)
        return code
    }

    /// `ai-mac-cleaner --skill <名称> [--args '{...}']` / `--ps` / `--review`：
    /// 直接调一个注册过的 skill（白名单之外一律拒绝）。
    static func runSkill(name: String, args: SkillArgs) -> Int32 {
        guard let skill = SkillRegistry.resolve(name) else {
            FileHandle.standardError.write(Data(
                L10n.t("未知 skill：\(name)\n", "Unknown skill: \(name)\n").utf8))
            return 2
        }
        if let err = SkillRegistry.validate(skill.spec, args: args) {
            FileHandle.standardError.write(Data((err + "\n").utf8))
            return 2
        }
        let sem = DispatchSemaphore(value: 0)
        var code: Int32 = 0
        Task.detached {
            let result = await skill.invoke(args, session: AgentSession())
            print(result.summary)
            if !result.observation.isEmpty && result.observation != result.summary {
                print("")
                print(result.observation)
            }
            if result.awaitingApproval {
                print("")
                print(L10n.t("⚠ 这是一个计划，尚未执行任何删除。",
                             "⚠ This is a plan — nothing has been deleted yet."))
            }
            code = result.ok ? 0 : 1
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 120)
        return code
    }

    // MARK: - 输出

    private static func printStep(_ step: AgentStep) {
        let riskMark = step.risk == .destructive
            ? L10n.t("【预演】", "[preview] ") : ""
        let okMark = step.ok ? "▶" : "✗"
        print("\(okMark) \(riskMark)\(step.command)")
        print("  " + step.summary)
    }

    private static func printRun(_ run: AgentRun) {
        if run.needsConfig {
            print(run.answer)
            return
        }
        if !run.steps.isEmpty { print("") }
        print("──")
        print(L10n.t("回答：", "Answer:") + " " + run.answer)
        if let note = run.note { print("\n" + note) }
        if run.awaitingApproval {
            print("\n" + L10n.t(
                "⚠ 上面只是计划，没有任何删除发生。请到「应用」页核对清单后点确认，或自行运行 ai-mac-cleaner --uninstall <目标>。",
                "⚠ The above is only a plan. Nothing was deleted. Review the list in the Apps tab and confirm, or run ai-mac-cleaner --uninstall <target> yourself."))
        }
    }

    // MARK: - 参数解析

    /// 取出 `--flag` 后面紧跟的值（若不是另一个 flag 的话）。
    static func value(after flag: String, in args: [String]) -> String? {
        guard let idx = args.firstIndex(of: flag), idx + 1 < args.count else { return nil }
        return args[idx + 1]
    }

    /// 收集 `--flag` 之后直到下一个 `--` 开头的 token 的所有词，拼成一个字符串。
    /// 让 `ai-mac-cleaner --agent 卸载 Cursor` 也能工作，而不必加引号。
    static func collectGoal(after flag: String, in args: [String]) -> String {
        guard let idx = args.firstIndex(of: flag) else { return "" }
        let rest = args.dropFirst(idx + 1)
        let words = rest.prefix(while: { !$0.hasPrefix("--") && $0 != "-h" })
        return words.joined(separator: " ")
    }

    /// 把 `--args '{...}'` 解析成 SkillArgs。
    static func args(fromJSON json: String?) -> SkillArgs {
        guard let json, let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return SkillArgs() }
        var dict: [String: String] = [:]
        for (k, v) in obj { dict[k] = String(describing: v) }
        return SkillArgs(dict)
    }
}
