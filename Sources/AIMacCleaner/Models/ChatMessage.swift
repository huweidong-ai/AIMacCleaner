import Foundation

/// 「问 AI」的一条对话消息。
///
/// 从 `UI/AskAIView.swift` 迁到这里的理由：改造后它被 `AppState`（状态层）、
/// `ChatStore`（存储层）、`ChatPolicy`（策略层）三处引用，已经不是 View 的私有模型。
/// 并且 `Codable` 一致性声明在类型原声明处，`encode(to:)` 才能自动合成 ——
/// 跨文件 extension 声明一致性时 Swift 拒绝合成，两个方法都得手写。
///
/// ⚠️ `id` **不参与序列化**（见 `CodingKeys`）：它只是进程内的渲染标识
/// （SwiftUI `ForEach` 的 `Identifiable` 与 `ScrollViewReader.scrollTo`），
/// 每次解码都会重新生成。**禁止**拿它做任何跨启动的持久化关联
/// （收藏某条回复、引用某条消息…）。真有需求得另加一个参与序列化的 `stableID`。
struct AIMessage: Identifiable, Codable, Equatable {
    let id = UUID()
    let role: Role
    let text: String
    /// 消息产生时间。用于聊天里按天显示日期分隔、每条显示时分。
    /// 参与序列化：老历史没有这个字段时解码兜底为 `Date()`（显示为当前时间，可接受）。
    let createdAt: Date
    /// Agent 这一轮实际执行过的 skill。空数组 = 纯对话没动手。
    var steps: [AgentStep] = []
    /// 若设置，气泡下方出现「前往 →」按钮，点击切到对应 tab。
    var redirect: AgentTab? = nil
    /// 这一轮产出了需要用户点头的计划。
    var awaitingApproval: Bool = false
    /// 上下文锚点标记。true = 这是一条 `/reset` 打下的分割线，
    /// 发往模型的 history 只取它之后的消息（见 `ChatPolicy.afterAnchor`）。
    var isAnchor: Bool = false
    /// 模型的**深度思考**内容（推理过程）。nil = 该模型/该轮没有推理内容。
    ///
    /// 与 `text` 分开存，而不是拼进正文：思考过程要能折叠起来单独看，
    /// 而且它**不该进下一轮的 history** —— 那是给用户看的推理轨迹，不是对话。
    var reasoning: String? = nil

    /// 消息角色。
    ///
    /// `.system` **只**用于 `/reset` 的锚点分割线，不作他用：
    /// - 它永远不进模型 history（`ChatPolicy.modelHistory` 会 filter 掉）
    /// - 它不计入「是否有真实对话」（`ChatPolicy.hasConversation`）
    /// - 它不计入 15 轮的轮数统计（`ChatPolicy.trim` 只数 `.me` / `.ai`）
    ///
    /// 特别地，未配置模型时的 `AgentRuntime.configPrompt` 提示**保持 `.ai`**：
    /// 空态判定看的是「有没有 .me/.ai」，改成 `.system` 会让那条提示被空态首屏盖住。
    enum Role: String, Codable { case me, ai, system }

    init(role: Role,
         text: String,
         steps: [AgentStep] = [],
         redirect: AgentTab? = nil,
         awaitingApproval: Bool = false,
         isAnchor: Bool = false,
         reasoning: String? = nil,
         createdAt: Date = Date()) {
        self.role = role
        self.text = text
        self.createdAt = createdAt
        self.steps = steps
        self.redirect = redirect
        self.awaitingApproval = awaitingApproval
        self.isAnchor = isAnchor
        self.reasoning = reasoning
    }

    /// 造一条上下文锚点消息。
    ///
    /// `text` 落盘存本地化文案（人肉打开 JSON 时能读懂），但渲染时以 `isAnchor`
    /// 为准实时取 `L10n` —— 用户切语言后旧锚点跟着变，不会中英混排。
    static func anchor() -> AIMessage {
        AIMessage(role: .system,
                  text: L10n.t("上下文已重置 —— 以下开始不再携带之前的对话",
                               "Context reset — messages above are no longer sent to the model"),
                  isAnchor: true)
    }

    /// ⚠️ 故意不含 `id`：encode 不写它（JSON 更干净），decode 不读它
    /// （`let id = UUID()` 的默认值生效，重新生成）。这样既不会触发
    /// "immutable property will not be decoded" 警告，也不用为 id 写任何代码。
    private enum CodingKeys: String, CodingKey {
        case role, text, steps, redirect, awaitingApproval, isAnchor, createdAt, reasoning
    }

    /// 手写解码：**全字段 `decodeIfPresent` + 默认值**。
    ///
    /// Swift 合成的 `init(from:)` 不会用属性默认值填补缺失的键 —— 对非 Optional
    /// 属性，键缺失直接抛 `keyNotFound`。而 `ChatStore` 的容错策略是「解码失败 → 空数组」，
    /// 也就是说：将来任何一次加字段，都会让所有老用户的历史被静默清空。
    /// 新增字段时同步在这里加一行兜底。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        role = (try? c.decodeIfPresent(Role.self, forKey: .role)) ?? .ai
        text = (try? c.decodeIfPresent(String.self, forKey: .text)) ?? ""
        steps = (try? c.decodeIfPresent([AgentStep].self, forKey: .steps)) ?? []
        redirect = try? c.decodeIfPresent(AgentTab.self, forKey: .redirect)
        awaitingApproval = (try? c.decodeIfPresent(Bool.self, forKey: .awaitingApproval)) ?? false
        isAnchor = (try? c.decodeIfPresent(Bool.self, forKey: .isAnchor)) ?? false
        createdAt = (try? c.decodeIfPresent(Date.self, forKey: .createdAt)) ?? Date()
        // 老历史没有这个键 → nil，不能因此让整条消息解码失败。
        reasoning = try? c.decodeIfPresent(String.self, forKey: .reasoning)
    }
}
