import Foundation

/// # Agent 运行时
///
/// 一个朴素但完整的 agent loop：
///
/// ```
/// 用户目标 → [大脑决策] → 调用 skill → 观测结果回喂 → [再决策] → … → 最终回答
/// ```
///
/// 与 v1.5 那版「问 AI」的区别在于**多轮**：模型可以先 `list_apps` 确认名字，
/// 再 `scan_app` 拿到清单，再 `review_plan` 挑出不该删的，最后才回答。
/// 每一轮它看到的都是上一轮真实的执行结果，而不是自己的猜测。
///
/// 这是一个**纯 AI Agent** 模块，必须靠真实模型驱动：
/// - 未配置模型（没开开关 / 没填 API Key）时直接提示用户去配置，不跑任何逻辑；
/// - 模型调用失败（网络不可达 / Key 错误）时如实报错，不会提供虚假的「假智能」回答。
/// - `LLMBrain`：真实模型（OpenAI / Anthropic 兼容端点）。

// MARK: - 一次调用

struct SkillCall {
    let name: String
    let args: SkillArgs
}

/// 一步执行记录，UI 和 CLI 都拿它做展示。
///
/// `Codable` 是为了跟着 `AIMessage` 一起落盘（「问 AI」的对话历史里带着
/// 「这一轮实际执行过哪些 skill」）。**运行逻辑一行没改。**
///
/// ⚠️ `id` 不参与序列化，每次解码重新生成 —— 它只是 `ForEach` 的渲染标识，
/// 不作跨启动的持久化关联。同 `AIMessage` 的约定。
struct AgentStep: Identifiable, Codable, Equatable {
    let id = UUID()
    let skill: String
    /// 等价的 AI Mac Cleaner CLI 命令，直接展示给用户 —— Agent 做了什么必须看得见。
    let command: String
    let summary: String
    let ok: Bool
    let risk: SkillRisk

    init(skill: String, command: String, summary: String, ok: Bool, risk: SkillRisk) {
        self.skill = skill
        self.command = command
        self.summary = summary
        self.ok = ok
        self.risk = risk
    }

    /// 故意不含 `id`：encode 不写、decode 不读，`let id = UUID()` 的默认值生效。
    private enum CodingKeys: String, CodingKey {
        case skill, command, summary, ok, risk
    }

    /// 全字段 `decodeIfPresent` + 默认值 —— 将来加字段不会让老历史被静默清空。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        skill = (try? c.decodeIfPresent(String.self, forKey: .skill)) ?? ""
        command = (try? c.decodeIfPresent(String.self, forKey: .command)) ?? ""
        summary = (try? c.decodeIfPresent(String.self, forKey: .summary)) ?? ""
        ok = (try? c.decodeIfPresent(Bool.self, forKey: .ok)) ?? false
        risk = (try? c.decodeIfPresent(SkillRisk.self, forKey: .risk)) ?? .readOnly
    }
}

/// 一次完整运行的产物。
struct AgentRun {
    var answer: String
    var steps: [AgentStep] = []
    var redirect: AgentTab? = nil
    var awaitingApproval: Bool = false
    /// 是否真的用上了模型（false = 模型调用失败，本轮没能跑通）。
    var usedModel: Bool = false
    /// 用户还没配置模型 —— 调用方应提示其先去配置，而不是假装能回答。
    var needsConfig: Bool = false
    /// 超轮数之类需要如实告诉用户的附注。
    var note: String? = nil
}

// MARK: - 大脑

enum BrainDecision {
    case call([SkillCall])
    case finish(String)
    /// 模型不可用（网络失败 / Key 错误），调用方应如实告知用户，而非假装能回答。
    case unavailable
}

protocol AgentBrain {
    /// - Parameters:
    ///   - goal: 用户这次说的话
    ///   - history: 之前的对话轮次
    ///   - transcript: 本次运行中已经执行过的 skill 及其观测
    func decide(goal: String,
                history: [(role: String, content: String)],
                transcript: [(call: SkillCall, result: SkillResult)]) async -> BrainDecision
}

// MARK: - 运行时

struct AgentRuntime {
    var config: AIModelConfig?
    /// GUI 宿主。CLI 下为 nil —— 此时整条链不触碰 MainActor，
    /// 可以安全地在 `main()` 里用信号量同步等待。
    var bridge: AgentBridge?
    /// CLI 的进度回调。`@Sendable`：它会在跨 MainActor 的 async 调用链里被回传，
    /// 闭包体只能是纯输出（打印），不捕获任何非 Sendable 状态。
    var onStep: (@Sendable (AgentStep) -> Void)?
    /// 最多几轮决策。4 轮足够「确认名字 → 扫描 → 分析 → 回答」，
    /// 再多只会让一次提问等上半分钟。
    var maxTurns: Int = 4
    /// 注入 system prompt 的长期记忆块（`MemoryPolicy.promptBlock` 的产物，可为空串）。
    ///
    /// 由调用方传入而不是在这里读 `MemoryStore`：GUI 侧 `AppState.memoryNotes`
    /// 才是那份数据的权威副本（用户刚删掉的一条，不该因为这里再读一次盘又活过来），
    /// 同时也让自检能拿固定字符串去断言拼装结果。
    var memory: String = ""

    func run(goal: String,
             history: [(role: String, content: String)] = [],
             session: AgentSession = AgentSession()) async -> AgentRun {

        let useModel = config?.isConfigured ?? false
        // 没配置模型：不跑任何逻辑，直接让用户去配置。这是「纯 AI Agent」的底线。
        guard useModel else {
            return AgentRun(answer: Self.configPrompt, usedModel: false, needsConfig: true)
        }

        let brain: AgentBrain = LLMBrain(config: config!, memory: memory)
        var run = AgentRun(answer: "", usedModel: true)
        var transcript: [(call: SkillCall, result: SkillResult)] = []

        for turn in 0..<maxTurns {
            let decision = await brain.decide(goal: goal, history: history, transcript: transcript)

            switch decision {
            case .finish(let text):
                run.answer = text
                return run

            case .unavailable:
                // 模型真的调不动了（网络 / Key 问题）。如实报错，不让它伪装成成功。
                run.answer = Self.modelError
                run.note = Self.modelErrorNote
                return run

            case .call(let calls):
                guard !calls.isEmpty else {
                    run.answer = Self.fallbackAnswer(transcript)
                    return run
                }
                for call in calls {
                    let (step, result) = await execute(call, session: session)
                    run.steps.append(step)
                    onStep?(step)
                    if let bridge { await bridge.finish(step) }
                    if let r = result {
                        transcript.append((call, r))
                        if let tab = r.redirect { run.redirect = tab }
                        if r.awaitingApproval { run.awaitingApproval = true }
                    } else {
                        transcript.append((call, SkillResult.failure(step.summary)))
                    }
                }
                // 最后一轮还在调工具，就不再给模型机会了，直接总结。
                if turn == maxTurns - 1 {
                    run.answer = Self.fallbackAnswer(transcript)
                    run.note = Self.turnLimitNote
                }
            }
        }
        if run.answer.isEmpty { run.answer = Self.fallbackAnswer(transcript) }
        return run
    }

    /// 执行一次 skill 调用：白名单校验 → 参数校验 → 执行 → 把副作用交给宿主。
    private func execute(_ call: SkillCall, session: AgentSession) async -> (AgentStep, SkillResult?) {
        guard let skill = SkillRegistry.resolve(call.name) else {
            let msg = L10n.t("拒绝执行：\(call.name) 不在 AI Mac Cleaner 的 skill 清单里。",
                             "Refused: \(call.name) is not in AI Mac Cleaner's skill list.")
            return (AgentStep(skill: call.name, command: "—", summary: msg, ok: false, risk: .readOnly), nil)
        }
        let spec = skill.spec
        let command = Self.cliDisplay(spec: spec, args: call.args)

        if let err = SkillRegistry.validate(spec, args: call.args) {
            return (AgentStep(skill: spec.name, command: command, summary: err, ok: false, risk: spec.risk), nil)
        }

        if let bridge { await bridge.willRun(spec: spec, command: command) }
        let result = await skill.invoke(call.args, session: session)
        if let bridge { await bridge.apply(result.effect) }

        return (AgentStep(skill: spec.name, command: command,
                          summary: result.summary, ok: result.ok, risk: spec.risk), result)
    }

    /// 把 skill 调用还原成等价的 CLI 命令字符串（展示用）。
    static func cliDisplay(spec: SkillSpec, args: SkillArgs) -> String {
        var s = spec.cli
        var trailing: [String] = []
        for arg in spec.args {
            let token = "<\(arg.name)>"
            if s.contains(token) {
                s = s.replacingOccurrences(of: token, with: args[arg.name] ?? "?")
            } else if let v = args[arg.name] {
                trailing.append("--\(arg.name) \(v)")
            }
        }
        return (["expunge", s] + trailing).joined(separator: " ")
    }

    /// 模型没给出收尾发言时，用真实执行结果拼一个 —— 宁可干巴巴，
    /// 也不要凭空编一段「我已经帮你清理好了」。
    static func fallbackAnswer(_ transcript: [(call: SkillCall, result: SkillResult)]) -> String {
        guard !transcript.isEmpty else {
            return L10n.t("我没能理解这个请求。可以试试「卸载 Cursor」「扫一遍残留」「列出后台进程」。",
                          "I couldn't parse that. Try “uninstall Cursor”, “scan leftovers”, or “list background processes”.")
        }
        return transcript.map(\.result.summary).joined(separator: "\n")
    }

    /// 未配置模型时给用户的提示（GUI 会据此弹配置、CLI 会打印）。
    static var configPrompt: String {
        L10n.t("还没配置模型，「问 AI」用不了。请到 ⚙ 设置里填好 API Key（OpenAI / Anthropic 兼容都行），配置好后我就能接管了。",
               "No model is configured yet, so Ask AI can't run. Open Settings (⚙) and add an API key — OpenAI- or Anthropic-compatible both work — then I'm ready.")
    }

    /// 模型已配置但调用失败（网络 / Key 错误）时如实报错。
    static var modelError: String {
        L10n.t("模型调用失败。请检查 API Key 是否正确、网络是否可达，或到 ⚙ 重新配置模型。",
               "The model call failed. Check that your API key is correct and the network is reachable, or reconfigure the model in Settings (⚙).")
    }

    static var modelErrorNote: String? {
        L10n.t("（本轮未能用上模型。）", "(The model could not be reached this turn.)")
    }

    static var turnLimitNote: String {
        L10n.t("（达到单次对话的最大执行步数，先给出目前的结果。）",
               "(Hit the per-turn step limit — reporting what's done so far.)")
    }
}

// MARK: - 模型大脑

struct LLMBrain: AgentBrain {
    let config: AIModelConfig
    /// 长期记忆块，空串 = 用户没记过东西，提示词里一个字都不多加。
    var memory: String = ""

    func decide(goal: String,
                history: [(role: String, content: String)],
                transcript: [(call: SkillCall, result: SkillResult)]) async -> BrainDecision {
        var messages = history
        messages.append((role: "user", content: goal))
        if !transcript.isEmpty {
            messages.append((role: "assistant", content: Self.replayCalls(transcript)))
            messages.append((role: "user", content: Self.observationBlock(transcript)))
        }

        let reply: String
        do {
            reply = try await LLMClient.complete(config: config,
                                                 messages: messages,
                                                 system: Self.systemPrompt(memory: memory))
        } catch {
            return .unavailable
        }

        let (text, calls) = AgentProtocol.parse(reply)
        if calls.isEmpty {
            return .finish(text.isEmpty ? reply : text)
        }
        return .call(calls)
    }

    /// 系统提示词。skill 清单由注册表生成 —— 新增 skill 时这里不用改。
    ///
    /// `memory` 是用户用 `/remember` 写下的长期记忆，**追加在末尾**而不是插在中间：
    /// 越靠后的指令对模型的约束越强，而记忆的定位就是「推翻默认判断」。
    static func systemPrompt(memory: String = "") -> String {
        let manifest = SkillRegistry.manifest
        let zhRule = "回答简洁、说人话，用中文。给出关键数字（项数、体积）和风险提示。"
        let enRule = "Be concise and human. Use English. Include key numbers (item count, size) and risks."

        let base = L10n.t("""
            你是 AI Mac Cleaner 的清理 Agent。AI Mac Cleaner 是一个 macOS 深度卸载工具，运行在用户本机。

            你只能通过下面这些 skill 干活，除此之外没有任何执行能力（没有 shell、不能读写任意文件、不能联网）：
            \(manifest)

            调用方式：在回复末尾附一个代码块，每行一个 JSON 调用。
            ```expunge
            {"skill": "scan_app", "args": {"target": "Cursor"}}
            ```
            调用后你会收到真实的执行结果，可以据此继续调用或直接回答。一轮里最多调 3 个 skill。

            工作原则：
            1. 需要事实就去调 skill，不要凭印象编造路径、体积或数量。
            2. 拿不准用户说的是哪个应用时，先 list_apps 确认。
            3. 用户问「哪个应用最大」「占用空间」时，不要反过来问用户要扫哪个——
               主动选几个常见大体积候选（Xcode、微信、Chrome、JetBrains IDE、Docker 等）
               直接 scan_app，然后比大小给出结论。
            4. 你没有删除权限。涉及卸载就用 plan_uninstall 出计划，然后请用户在界面上确认。
            5. 已经拿到足够信息就直接回答，不要重复调用同一个 skill。
            6. 用户让你分析「当前清单」时，清单已经通过会话注入（应用清单走 review_plan(scope: apps)，残留清单走 review_plan(scope: leftovers)）。
               直接调用 review_plan，不要再 scan_app / scan_leftovers。
            7. \(zhRule)
            """, """
            You are the cleanup agent for AI Mac Cleaner, a macOS deep-uninstall tool running on the user's own Mac.

            You can only act through the skills below. You have no other execution capability — no shell, no arbitrary file access, no network:
            \(manifest)

            To call a skill, append a fenced block at the end of your reply, one JSON call per line:
            ```expunge
            {"skill": "scan_app", "args": {"target": "Cursor"}}
            ```
            You will receive the real execution results and can then call again or answer directly. Max 3 skills per turn.

            Principles:
            1. Call a skill when you need a fact. Never invent paths, sizes, or counts.
            2. If you're unsure which app the user means, call list_apps first.
            3. When asked "which app is biggest" or about disk usage, don't ask the user to pick —
               proactively scan a few likely large candidates (Xcode, WeChat, Chrome, JetBrains IDEs, Docker, etc.)
               and compare their sizes.
            4. You cannot delete anything. For uninstalls, produce a plan with plan_uninstall and ask the user to confirm in the UI.
            5. Once you have enough information, answer — don't re-call the same skill.
            6. When the user asks you to review the "current list", the list is already injected into the session (apps via review_plan(scope: apps), leftovers via review_plan(scope: leftovers)).
               Call review_plan directly; do not scan_app or scan_leftovers again.
            7. \(enRule)
            """)
        let block = memory.trimmingCharacters(in: .whitespacesAndNewlines)
        return block.isEmpty ? base : base + "\n" + memory
    }

    /// 把已执行的调用回放成 assistant 消息，让模型知道「这是我上一步做的」。
    private static func replayCalls(_ transcript: [(call: SkillCall, result: SkillResult)]) -> String {
        let lines = transcript.map { entry -> String in
            let args = entry.call.args.inlineDescription
            return "{\"skill\": \"\(entry.call.name)\"\(args.isEmpty ? "" : ", \"args\": {\(args)}")}"
        }
        return "```expunge\n" + lines.joined(separator: "\n") + "\n```"
    }

    /// 观测结果。每条截断，避免几百项扫描结果把上下文挤爆。
    private static func observationBlock(_ transcript: [(call: SkillCall, result: SkillResult)]) -> String {
        let blocks = transcript.map { entry -> String in
            let body = String(entry.result.observation.prefix(1600))
            return "### \(entry.call.name)\n\(body)"
        }
        return L10n.t("以下是 skill 的真实执行结果，请基于它继续：\n\n",
                      "Here are the real skill results — continue based on them:\n\n")
            + blocks.joined(separator: "\n\n")
    }
}

// MARK: - 指令解析

/// 模型回复 ↔ skill 调用之间的翻译层。
enum AgentProtocol {

    /// 从回复里抽出 ```` ```expunge ```` 块，解析成调用，并返回去掉该块的正文。
    static func parse(_ raw: String) -> (text: String, calls: [SkillCall]) {
        let pattern = "```expunge\\s*\\n([\\s\\S]*?)```"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: raw, range: NSRange(raw.startIndex..<raw.endIndex, in: raw)),
              let blockRange = Range(match.range(at: 1), in: raw)
        else {
            return (raw.trimmingCharacters(in: .whitespacesAndNewlines), [])
        }
        let calls = String(raw[blockRange])
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .compactMap { parseLine($0) }
            .prefix(3)   // 一轮最多 3 个，防止模型一口气排一长串

        var cleaned = raw
        if let fullRange = Range(match.range, in: raw) { cleaned.removeSubrange(fullRange) }
        return (cleaned.trimmingCharacters(in: .whitespacesAndNewlines), Array(calls))
    }

    /// 解析一行调用。优先 JSON；失败则按裸文本处理 —— 小模型经常
    /// 写成 `scan Cursor` 而不是标准 JSON，为这点小事让整轮失败不值得。
    static func parseLine(_ line: String) -> SkillCall? {
        if let call = parseJSON(line) { return call }
        return parseBare(line)
    }

    private static func parseJSON(_ line: String) -> SkillCall? {
        guard line.hasPrefix("{"),
              let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        guard let name = (obj["skill"] ?? obj["name"] ?? obj["tool"]) as? String else { return nil }
        var args: [String: String] = [:]
        if let dict = obj["args"] as? [String: Any] {
            for (k, v) in dict { args[k] = stringify(v) }
        }
        return SkillCall(name: name, args: SkillArgs(args))
    }

    /// `scan_app target=Cursor` / `scan Cursor` / `ps`
    private static func parseBare(_ line: String) -> SkillCall? {
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        guard let head = parts.first,
              let skill = SkillRegistry.resolve(head)
        else { return nil }
        let spec = skill.spec
        guard parts.count > 1 else { return SkillCall(name: spec.name, args: SkillArgs()) }

        let rest = parts[1].trimmingCharacters(in: .whitespaces)
        if rest.contains("=") {
            var args: [String: String] = [:]
            for pair in rest.split(separator: " ") {
                let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
                if kv.count == 2 { args[kv[0]] = kv[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) }
            }
            return SkillCall(name: spec.name, args: SkillArgs(args))
        }
        // 没写参数名：塞给第一个必填参数（scan_app 的 target 就是这么来的）
        if let first = spec.args.first(where: \.required) {
            return SkillCall(name: spec.name, args: SkillArgs([first.name: rest]))
        }
        return SkillCall(name: spec.name, args: SkillArgs())
    }

    private static func stringify(_ v: Any) -> String {
        switch v {
        case let s as String: return s
        case let b as Bool:   return b ? "true" : "false"
        case let n as Int:    return String(n)
        case let d as Double: return String(d)
        default:              return "\(v)"
        }
    }
}
