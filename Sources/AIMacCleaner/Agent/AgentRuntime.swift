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
    /// 本次运行累积的深度思考内容（可能为空 —— 模型未必有推理内容）。
    /// 只用于**展示**：不进下一轮 history，也不参与任何判定。
    var reasoning: String = ""
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
    /// 模型不可用。带一句**具体**的说明（如「余额不足，去充值」），
    /// 为 nil 时调用方用通用的 `modelError`。
    case unavailable(String?)
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

// MARK: - 运行期事件（流式）

/// agent 运行过程中对外抛出的实时事件。
///
/// 为什么要单独一套事件而不是直接改 `AgentRun`：CLI 与自检走的是「一次拿全量」的
/// 路径（`run(goal:)` 原样保留），GUI 才需要逐帧刷新。两套并存，接口不互相破坏。
enum AgentEvent {
    /// 本轮开始思考（新一轮决策）。
    case turnStarted(Int)
    /// 深度思考增量。
    case reasoningDelta(String)
    /// 正文增量。
    case textDelta(String)
    /// 一个 skill 开始执行。
    case toolStarted(skill: String, command: String)
    /// 一个 skill 执行完毕。
    case toolFinished(AgentStep)
    /// 整体收尾。
    case finished(AgentRun)
}

/// 累积流式「深度思考」增量的容器。
///
/// 为什么需要它：增量是**直接转发给界面**的，`AgentRuntime` 手上没有副本，
/// 于是 `AgentRun.reasoning` 一直是空的 —— 用户眼看着思考内容流出来，
/// 消息一落盘那块却凭空消失了。用 actor 而不是普通 var，是因为它要跨
/// 流式回调的并发边界被读写。
actor ReasoningSink {
    private var buffer = ""
    func add(_ chunk: String) { buffer += chunk }
    func text() -> String { buffer }
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
    /// 最多几轮决策。**6** 是按「调查一个 app」的真实链路定的：
/// scan_app → search_paths → inspect_path（可能多次）→ propose_paths → 汇总结论。
/// 曾经设 4，于是经常在「工具全跑完、结论还没出口」时被迫收尾——
/// 用户看到一堆步骤却没有答案，体验上比失败还差。
    /// 再多也没意义：单次提问等太久不划算，而且步骤都在界面上可见。
    var maxTurns: Int = 6
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

            case .unavailable(let detail):
                // 模型真的调不动了（网络 / Key / 余额 / 上游）。如实报错，不让它伪装成成功。
                // 带detail 时用它自己的说法（余额不足 → 去充值），别把用户引去查 Key。
                run.answer = detail ?? Self.modelError
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

    /// **流式**运行：逐帧抛事件，GUI 用它实时刷新「深度思考」与正文。
    ///
    /// 与 `run(goal:)` 的关系是「同一套逻辑、两种出口」：决策、工具调用、白名单、
    /// 轮数上限全部共用，区别只有正文与思考是**边收边发**。
    /// 因此不存在「流式版跑出来结论不一样」这种风险。
    func runStream(goal: String,
                   history: [(role: String, content: String)] = [],
                   session: AgentSession = AgentSession(),
                   onEvent: @escaping @Sendable (AgentEvent) async -> Void) async -> AgentRun {

        let useModel = config?.isConfigured ?? false
        guard useModel else {
            let run = AgentRun(answer: Self.configPrompt, usedModel: false, needsConfig: true)
            await onEvent(.finished(run))
            return run
        }

        // 思考增量一边转发给界面、一边自己攒一份：`run.reasoning` 得带着它回给调用方，
        // 否则消息一落盘，「深度思考」块就凭空消失（流式过程中看得见、收尾后没了）。
        let sink = ReasoningSink()
        let brain: AgentBrain = StreamingLLMBrain(
            config: config!, memory: memory,
            onEvent: { event in
                if case .reasoningDelta(let chunk) = event { await sink.add(chunk) }
                await onEvent(event)
            })
        var run = AgentRun(answer: "", usedModel: true)
        var transcript: [(call: SkillCall, result: SkillResult)] = []

        for turn in 0..<maxTurns {
            await onEvent(.turnStarted(turn + 1))
            let decision = await brain.decide(goal: goal, history: history, transcript: transcript)

            switch decision {
            case .finish(let text):
                run.answer = text
                run.reasoning = await sink.text()
                await onEvent(.finished(run))
                return run

            case .unavailable:
                run.answer = Self.modelError
                run.note = Self.modelErrorNote
                run.reasoning = await sink.text()
                await onEvent(.finished(run))
                return run

            case .call(let calls):
                guard !calls.isEmpty else {
                    run.answer = Self.fallbackAnswer(transcript)
                    run.reasoning = await sink.text()
                    await onEvent(.finished(run))
                    return run
                }
                for call in calls {
                    if let skill = SkillRegistry.resolve(call.name) {
                        await onEvent(.toolStarted(
                            skill: skill.spec.name,
                            command: Self.cliDisplay(spec: skill.spec, args: call.args)))
                    }
                    let (step, result) = await execute(call, session: session)
                    run.steps.append(step)
                    onStep?(step)
                    if let bridge { await bridge.finish(step) }
                    await onEvent(.toolFinished(step))
                    if let r = result {
                        transcript.append((call, r))
                        if let tab = r.redirect { run.redirect = tab }
                        if r.awaitingApproval { run.awaitingApproval = true }
                    } else {
                        transcript.append((call, SkillResult.failure(step.summary)))
                    }
                }
                if turn == maxTurns - 1 {
                    run.answer = Self.fallbackAnswer(transcript)
                    run.note = Self.turnLimitNote
                }
            }
        }
        if run.answer.isEmpty { run.answer = Self.fallbackAnswer(transcript) }
        run.reasoning = await sink.text()
        await onEvent(.finished(run))
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
    ///
    /// 必须**明说这是「执行记录」而不是「结论」**：直接把各步 summary 拼起来当回答，
    /// 用户会以为那就是它的最终判断（比如把「扫到 12 项」读成「建议删 12 项」）。
    static func fallbackAnswer(_ transcript: [(call: SkillCall, result: SkillResult)]) -> String {
        guard !transcript.isEmpty else {
            return L10n.t("我没能理解这个请求。可以试试「卸载 Cursor」「扫一遍残留」「列出后台进程」。",
                          "I couldn't parse that. Try “uninstall Cursor”, “scan leftovers”, or “list background processes”.")
        }
        let lines = transcript.map { entry in
            "  \(entry.call.name)：\(entry.result.summary)"
        }.joined(separator: "\n")
        return L10n.t("""
            我执行了下面这些操作，但没能给出最终结论（通常是步数用完或最后一轮调用失败）。
            以上是**真实执行记录**，不是结论——请点开上方的步骤查看细节，或换个说法再问一次。
            \(lines)
            """, """
            I ran the steps below but couldn't produce a final conclusion (usually the step budget ran out
            or the last model call failed). These are **actual execution records**, not conclusions — open the
            steps above for details, or rephrase your request.
            \(lines)
            """)
    }

    /// 把底层错误翻译成「用户该做什么」。
    ///
    /// 「永久失效」的错误带着自己的说明走（余额不足 → 去充值），因为这类问题
    /// 重试无意义、而且 API Key 本身没问题——泛泛地说「检查 API Key」会把人引到错的地方。
    static func diagnose(_ error: Error?) -> String? {
        guard let error, let le = error as? LLMError, le.isPermanent else { return nil }
        return le.errorDescription
    }

    /// 未配置模型时给用户的提示（GUI 会据此弹配置、CLI 会打印）。
    static var configPrompt: String {
        L10n.t("还没配置模型，「问 AI」用不了。请到 ⚙ 设置里填好 API Key（OpenAI / Anthropic 兼容都行），配置好后我就能接管了。",
               "No model is configured yet, so Ask AI can't run. Open Settings (⚙) and add an API key — OpenAI- or Anthropic-compatible both work — then I'm ready.")
    }

    /// 模型已配置但调用失败时如实报错。
    ///
    /// 措辞刻意列全了三种可能：真机见过「网关把请求转给了另一个上游而那次失败」，
    /// 那种情况下 API Key 完全正常，只提示「检查 API Key」会把人引到错的地方。
    static var modelError: String {
        L10n.t("模型调用失败。可能是 API Key 不正确、网络不可达，或模型网关把请求转给了另一个上游而那次调用失败（这种是偶发的，重试通常能过）。请重试；若反复失败，到 ⚙ 换一个模型档，或联系网关方确认上游可用性。",
               "The model call failed. Possible causes: a wrong API key, an unreachable network, or the gateway routing the request to another upstream and that call failing (the latter is intermittent and often passes on retry). Please retry; if it keeps failing, switch to another model profile in Settings (⚙) or ask your gateway provider whether that upstream is available.")
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
            reply = try await LLMClient.completeResilient(config: config,
                                                 messages: messages,
                                                 system: Self.systemPrompt(memory: memory))
        } catch {
            // 失败原因一律吞掉换成「模型不可用」，对用户是对的（他不需要看栈），
            // 但对排查是灾难——曾经因此分不清「Key 错了」和「端点地址拼错了」。
            // 设 AIMAG_DEBUG=1 就能看到真实错误，与 AIScanProposer 的做法一致。
            if ProcessInfo.processInfo.environment["AIMAG_DEBUG"] != nil {
                let msg = (error as? LLMError)?.errorDescription ?? "\(error)"
                // String(reflecting:) 才带得出 DecodingError 的 codingPath ——
                // 只看 localizedDescription 只会得到「missing」这种毫无线索的话。
                FileHandle.standardError.write(Data(
                    "AIMAG: LLM call failed — \(msg)\nAIMAG: raw — \(String(reflecting: error))\n".utf8))
            }
            // 「永久失效」的错误带着它自己的说明走（余额不足 → 去充值），
            // 别把用户引去查一个根本没问题的 API Key。
            if let le = error as? LLMError, le.isPermanent {
                return .unavailable(le.errorDescription)
            }
            return .unavailable(nil)
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
            7. **scan_app 找不到 ≠ 存在。** 内置扫描器靠关键词命中，而目录名未必等于 app 名
               （StoryFab 的数据目录叫 story-fab，bundle id 是 com.story-fab.desktop，两边都对不上关键词）。
               所以判断「这个 app 还有什么没被扫到」时，用宽 token 去 search_paths，再用 inspect_path 逐个确认归属——
               这是你唯一能发现漏项的途径。**归属要靠内容证据**（技术栈、文件类型、子项名），不要凭名字猜。
               确认属于目标 app 的，再用 propose_paths 提交；入库项一律不勾选，删不删由用户决定。
               ⚠️ 调查某个具体 app 时**必须先 scan_app**：只有它能给出 bundle id、
               并为校验网提供「除该 app 外的其它活 app」。跳过它，propose_paths 会直接拒绝。
            8. \(zhRule)
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
            7. **scan_app finding nothing ≠ nothing exists.** The built-in scanners match on keywords, and a
               directory name need not match the app name (StoryFab's data dir is `story-fab` while its
               bundle id is `com.story-fab.desktop` — neither matches its keywords). So when asked what else
               an app left behind, search with a BROAD token via search_paths, then confirm each hit with
               inspect_path — that is your only way to discover misses. **Judge ownership by content evidence**
               (stack traces, file kinds, child names), never by name alone. Submit what you confirmed via
               propose_paths; entries are never checked by default and the user decides what to delete.
               ⚠️ When investigating a specific app you MUST call scan_app first: it is the only way to get the
               bundle id and the "other live apps" context that validation needs. propose_paths is refused without it.
            8. \(enRule)
            """)
        let block = memory.trimmingCharacters(in: .whitespacesAndNewlines)
        return block.isEmpty ? base : base + "\n" + memory
    }

    /// 把已执行的调用回放成 assistant 消息，让模型知道「这是我上一步做的」。
    static func replayCalls(_ transcript: [(call: SkillCall, result: SkillResult)]) -> String {
        let lines = transcript.map { entry -> String in
            let args = entry.call.args.inlineDescription
            return "{\"skill\": \"\(entry.call.name)\"\(args.isEmpty ? "" : ", \"args\": {\(args)}")}"
        }
        return "```expunge\n" + lines.joined(separator: "\n") + "\n```"
    }

    /// 观测结果。每条截断，避免几百项扫描结果把上下文挤爆。
    static func observationBlock(_ transcript: [(call: SkillCall, result: SkillResult)]) -> String {
        let blocks = transcript.map { entry -> String in
            let body = String(entry.result.observation.prefix(1600))
            return "### \(entry.call.name)\n\(body)"
        }
        return L10n.t("以下是 skill 的真实执行结果，请基于它继续：\n\n",
                      "Here are the real skill results — continue based on them:\n\n")
            + blocks.joined(separator: "\n\n")
    }
}

// MARK: - 流式大脑

/// 与 `LLMBrain` 逐字相同的大脑，唯一区别是**用流式调用**并把增量转发出去。
///
/// 刻意不重构 `LLMBrain` 去共用代码：那条路径被 CLI 与自检依赖，
/// 而这里的增量回调是 `@Sendable` 的异步闭包，硬合并只会让两边都变复杂。
/// 共用的部分（提示词、指令解析、观测回放）仍然是同一份实现。
struct StreamingLLMBrain: AgentBrain {
    let config: AIModelConfig
    var memory: String = ""
    let onEvent: @Sendable (AgentEvent) async -> Void

    func decide(goal: String,
                history: [(role: String, content: String)],
                transcript: [(call: SkillCall, result: SkillResult)]) async -> BrainDecision {
        var messages = history
        messages.append((role: "user", content: goal))
        if !transcript.isEmpty {
            messages.append((role: "assistant", content: LLMBrain.replayCalls(transcript)))
            messages.append((role: "user", content: LLMBrain.observationBlock(transcript)))
        }

        let result: LLMStream.Result
        do {
            result = try await LLMStream.run(
                config: config, messages: messages,
                system: LLMBrain.systemPrompt(memory: memory),
                onEvent: { ev in
                    switch ev {
                    case .reasoning(let s): await onEvent(.reasoningDelta(s))
                    case .text(let s):     await onEvent(.textDelta(s))
                    }
                })
        } catch {
            // 流式失败 ≠ 模型不可用：可能只是这个端点不支持 SSE、长回复被
            // max_tokens 截断导致帧不完整、或网关偶发抽风。退到非流式再试一次
            // ——宁可「不流式」，也不要「白跑一轮工具后告诉用户模型挂了」。
            do {
                let recovered = try await LLMClient.completeResilient(
                    config: config, messages: messages,
                    system: LLMBrain.systemPrompt(memory: memory))
                if !recovered.isEmpty {
                    await onEvent(.textDelta(recovered))
                    return .finish(recovered)
                }
                return .unavailable(nil)
            } catch let fallbackError {
                // 让失败原因决定文案：余额不足要提示充值，而不是泛泛地说「检查 Key」。
                return .unavailable(AgentRuntime.diagnose(fallbackError))
            }
        }

        let (text, calls) = AgentProtocol.parse(result.text)
        if calls.isEmpty {
            return .finish(text.isEmpty ? result.text : text)
        }
        return .call(calls)
    }
}

// MARK: - 指令解析

/// 模型回复 ↔ skill 调用之间的翻译层。
enum AgentProtocol {

    /// 从回复里抽出 skill 调用，返回「去掉调用之后的正文」。
    ///
    /// **为什么不按语言标记认调用**：提示词只要求「在回复末尾附一个代码块，每行一个 JSON」，
    /// 于是模型经常把标记写成 ```` ```json ````、` ``` ``, 甚至干脆漏写围栏；参数也会写成
    /// `"path=/a b"` 这种用 `=` 而不是 `:` 的伪 JSON。以前只认 ```` ```expunge ```` 里的严格
    /// JSON，那一整块调用就**既不执行、也不从正文里摘掉**，最后原样糊进气泡 —— 用户看到的
    /// 是一坨 `{"skill": ...}`：活没干，界面还像坏了。所以改成**按内容认**，而不是按标记认：
    ///
    /// - 围栏块里解析得出调用 → 整块是工具块，摘走；
    /// - 语言标记正好是 `expunge`（我们教模型的写法）→ 无论解析结果都摘走：
    ///   这轮调用写坏了，留在正文里只会更难看；
    /// - 其余解析不出调用的块（例如真正的 ```` ```swift ```` 示例）→ 原样保留在正文；
    /// - 正文里裸写的 `{ "skill": … }` 对象（漏写围栏）也认。
    static func parse(_ raw: String) -> (text: String, calls: [SkillCall]) {
        var calls: [SkillCall] = []
        var kept: [String] = []
        var cursor = raw.startIndex

        for block in fencedBlocks(in: raw) {
            let found = parseBlock(block.body)
            guard !found.isEmpty || block.lang.lowercased() == "expunge" else { continue }
            calls.append(contentsOf: found)
            kept.append(String(raw[cursor..<block.range.lowerBound]))
            cursor = block.range.upperBound
        }
        kept.append(String(raw[cursor...]))

        // 漏写围栏的裸调用对象：就地摘掉。这里**只认 `skill` 键**（提示词里教的那个），
        // 不像围栏块里那样兼容 name/tool —— 正文里出现一个 { "name": "…" } 的普通
        // 数据片段不该被当成调用吞掉并执行。
        var text = kept.joined()
        var cut: [Range<String.Index>] = []
        for obj in jsonObjects(in: text) {
            guard let call = parseObject(obj.body, aliasKeys: false) else { continue }
            calls.append(call)
            cut.append(obj.range)
        }
        for range in cut.reversed() { text.removeSubrange(range) }

        return (tidy(text), Array(calls.prefix(3)))   // 一轮最多 3 个，防止模型一口气排一长串
    }

    /// 流式过程中用来上屏的「可见正文」：把工具调用从半截文本里摘掉。
    ///
    /// 流式是逐帧来的，模型此刻可能刚写下 ```` ``` ```` 或刚写到 `{"skill": ...` 一半。
    /// 原样上屏，用户会看到一坨 JSON 在眼前跳 —— 那不是「过程」，那是噪音。
    /// 处理办法：遇到围栏起始就截断（调用块总在末尾），行首是 `{` 的行一律丢掉。
    static func visibleStreamingText(_ raw: String) -> String {
        var text = raw
        if let fence = text.range(of: "```") {
            text = String(text[text.startIndex..<fence.lowerBound])
        }
        let kept = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("{") }
        return kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 解析一行调用。优先 JSON；失败则按裸文本处理 —— 小模型经常
    /// 写成 `scan Cursor` 而不是标准 JSON，为这点小事让整轮失败不值得。
    static func parseLine(_ line: String) -> SkillCall? {
        if let call = parseObject(line) { return call }
        return parseBare(line)
    }

    /// 解析一个代码块的内容：优先按 JSON 对象切（模型有时会把一个调用 pretty-print 成多行），
    /// 切不出对象时退回「一行一个调用」，兼容 `scan Cursor` 这类裸文本写法。
    private static func parseBlock(_ body: String) -> [SkillCall] {
        let objects = jsonObjects(in: body)
        guard objects.isEmpty else { return objects.compactMap { parseObject($0.body) } }
        return body.split(separator: "\n", omittingEmptySubsequences: true)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .compactMap { parseLine($0) }
    }

    /// 一个 JSON 对象 → SkillCall。先走严格 JSON，过不了再走宽松抠值。
    /// - Parameter aliasKeys: 是否兼容 `name` / `tool` 这两种别名键。
    private static func parseObject(_ json: String, aliasKeys: Bool = true) -> SkillCall? {
        guard json.hasPrefix("{") else { return nil }
        if let data = json.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let name = (obj["skill"] as? String)
                ?? (aliasKeys ? ((obj["name"] as? String) ?? (obj["tool"] as? String)) : nil)
            if let name {
                var args: [String: String] = [:]
                if let dict = obj["args"] as? [String: Any] {
                    for (k, v) in dict { args[k] = stringify(v) }
                }
                return SkillCall(name: name, args: SkillArgs(args))
            }
        }
        return parseLooseObject(json, aliasKeys: aliasKeys)
    }

    /// 非严格 JSON 兜底：模型把参数写成 `"path=/tmp/x"`（`=` 而非 `:`）时整段都过不了
    /// `JSONSerialization`，于是调用既不执行、也摘不掉。这里只抠两样东西：skill 名，
    /// 以及 `k=v` / `k: v` 形式的参数对（值允许带空格 —— 路径本来就有空格）。
    private static func parseLooseObject(_ json: String, aliasKeys: Bool) -> SkillCall? {
        let namePattern = aliasKeys
            ? #""(?:skill|name|tool)"\s*[:=]\s*"([^"]+)""#
            : #""skill"\s*[:=]\s*"([^"]+)""#
        guard let name = firstGroup(namePattern, in: json) else { return nil }

        // 参数区只从 `"args"` 之后开始算，免得把 skill 名本身也当成一个参数。
        var scope = json
        if let r = json.range(of: #""args"\s*[:=]\s*"#, options: .regularExpression) {
            scope = String(json[r.upperBound...])
        }

        var args: [String: String] = [:]
        if let regex = try? NSRegularExpression(
            pattern: #"([A-Za-z_][A-Za-z0-9_]*)\s*[:=]\s*("[^"]*"|[^,}\]]+)"#) {
            let ns = scope as NSString
            for m in regex.matches(in: scope, range: NSRange(location: 0, length: ns.length)) {
                guard let kR = Range(m.range(at: 1), in: scope),
                      let vR = Range(m.range(at: 2), in: scope) else { continue }
                let key = String(scope[kR]).lowercased()
                guard !["skill", "name", "tool", "args"].contains(key) else { continue }
                let value = String(scope[vR])
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'{}[] "))
                if !value.isEmpty { args[key] = value }
            }
        }
        return SkillCall(name: name, args: SkillArgs(args))
    }

    /// 扫出正文里所有**配平的** `{ … }` 对象（字符串里的花括号不算）。
    /// 按花括号配平而不是「按行切」，是因为模型有时会把一个调用 pretty-print 成多行。
    private static func jsonObjects(in text: String) -> [(body: String, range: Range<String.Index>)] {
        var found: [(String, Range<String.Index>)] = []
        var depth = 0
        var start: String.Index?
        var inString = false
        var escaped = false

        var i = text.startIndex
        while i < text.endIndex {
            let c = text[i]
            if inString {
                if escaped { escaped = false }
                else if c == "\\" { escaped = true }
                else if c == "\"" { inString = false }
            } else if c == "\"" {
                inString = true
            } else if c == "{" {
                if depth == 0 { start = i }
                depth += 1
            } else if c == "}", depth > 0 {
                depth -= 1
                if depth == 0, let s = start {
                    let end = text.index(after: i)
                    found.append((String(text[s..<end]), s..<end))
                }
            }
            i = text.index(after: i)
        }
        return found
    }

    /// 扫出所有围栏代码块。未闭合的块取到文本末尾 —— 被 max_tokens 截断时
    /// 模型常常只写了半块，而那半块同样是调用，必须认。
    private static func fencedBlocks(in raw: String)
        -> [(lang: String, body: String, range: Range<String.Index>)] {
        let pattern = "```([^\\n`]*)\\n([\\s\\S]*?)(?:```|$)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = raw as NSString
        return regex.matches(in: raw, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            guard let full = Range(m.range, in: raw),
                  let langR = Range(m.range(at: 1), in: raw),
                  let bodyR = Range(m.range(at: 2), in: raw) else { return nil }
            return (String(raw[langR]).trimmingCharacters(in: .whitespaces),
                    String(raw[bodyR]), full)
        }
    }

    /// 摘掉调用后收尾：连续空行压成一行，并去掉首尾空白。
    private static func tidy(_ text: String) -> String {
        var out: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let blank = line.trimmingCharacters(in: .whitespaces).isEmpty
            if blank, out.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { continue }
            out.append(String(line))
        }
        return out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 取正则的第一个捕获组。
    private static func firstGroup(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let m = regex.firstMatch(in: text,
                                       range: NSRange(text.startIndex..<text.endIndex, in: text)),
              m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: text)
        else { return nil }
        return String(text[r])
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
