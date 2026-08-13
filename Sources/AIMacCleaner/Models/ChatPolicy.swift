import Foundation

/// 「问 AI」输入里的斜杠命令。
///
/// **白名单精确匹配**：整条输入 trim + lowercased 后**全等**白名单才命中，
/// 否则返回 nil（照常发给模型）。
enum ChatCommand: Equatable {
    /// 清空整段会话。`/clear` 是它的同义写法，补全面板里两条都会列出、行为完全一致。
    case new
    /// 打上下文锚点：屏幕记录保留、落盘保留，只是模型看不到锚点之前的内容。
    case reset
    /// `/remember <内容>`：写入一条长期记忆。**唯一带参数的命令。**
    ///
    /// 空参数 = 用户只敲了 `/remember`，调用方应回一条用法提示而不是记空记忆。
    case remember(String)

    /// 解析一条用户输入。
    ///
    /// **为什么不用 `NSRegularExpression`** 而是全等匹配：
    /// 漏写 `^`/`$` 就变成「包含即命中」（`/Users/foo/new` 直接被当成清空指令吞掉）；
    /// `try?` 构造失败会静默降级；大小写不敏感容易被后人重构掉。
    /// 字符串全等**没有任何一种写错的方式能退化成「以 / 开头就吞」**。
    ///
    /// `/remember` 是这条纪律唯一的例外（它必须带参数），走单独的 `rememberArgument`
    /// 把例外收敛在一个可自检的小函数里，而不是放宽整个 `parse` 成前缀匹配。
    ///
    /// `String.lowercased()` 走 Unicode 默认大小写映射、不受 locale 影响。
    static func parse(_ raw: String) -> ChatCommand? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        switch trimmed.lowercased() {
        case "/new", "/clear": return .new
        case "/reset":         return .reset
        default:               break
        }
        if let arg = rememberArgument(trimmed) { return .remember(arg) }
        return nil
    }

    static let rememberToken = "/remember"

    /// 抽出 `/remember` 的参数，不命中返回 nil。
    ///
    /// 规则：小写化后以 `/remember` 开头，**紧接着必须是空白字符**，
    /// 且去空白后剩余内容非空。`/rememberfoo`、`/remember/x`、`/Users/remember me`
    /// 全部出局。参数从**原串**截取 — 保留用户原本大小写，路径 `~/Library/Application Support` 小写化后路径就废了。
    private static func rememberArgument(_ trimmed: String) -> String? {
        guard trimmed.count > rememberToken.count,
              trimmed.lowercased().hasPrefix(rememberToken) else { return nil }
        let rest = trimmed.dropFirst(rememberToken.count)
        guard let first = rest.first, first.isWhitespace else { return nil }
        let arg = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        return arg.isEmpty ? nil : arg
    }
}

/// 斜杠命令的**展示元数据**：补全面板要显示的图标与描述。
///
/// 它只回答「弹出来给用户看什么」，**不参与任何执行判定** ——
/// 一条输入算不算命令，永远只由 `ChatCommand.parse` 的全等白名单决定。
struct SlashCommandItem: Identifiable, Equatable {
    let token: String   // "/clear"（必须是白名单里原样存在的字符串）
    let icon: String    // SF Symbol
    let zh: String
    let en: String
    let section: SlashSection
    var id: String { token }
    /// 计算属性，不是存储属性 —— L10n 必须在渲染时现取，
    /// 固化进 `static let` 会让切换语言后描述不刷新。
    var detail: String { L10n.t(zh, en) }
}

/// 斜杠命令分组。仅影响补全面板的展示顺序与标题，不参与执行判定。
enum SlashSection: String, CaseIterable {
    case session
    case memory

    var title: String {
        switch self {
        case .session: return L10n.t("会话", "SESSION")
        case .memory:  return L10n.t("记忆", "MEMORY")
        }
    }
}

extension ChatCommand {
    /// 补全候选。顺序即面板里的显示顺序。
    ///
    /// 不变量（由 SelfTest 钉死）：每个 token 都必须能被 `parse` 命中 ——
    /// 面板永远不能提供一条白名单不认的命令。
    static let palette: [SlashCommandItem] = [
        SlashCommandItem(token: "/clear", icon: "eraser",
                         zh: "清空当前会话", en: "Clear this conversation",
                         section: .session),
        SlashCommandItem(token: "/reset", icon: "arrow.counterclockwise",
                         zh: "重置上下文，屏幕记录保留", en: "Reset context — messages stay on screen",
                         section: .session),
        SlashCommandItem(token: "/new", icon: "square.and.pencil",
                         zh: "开始新会话（与 /clear 等效）", en: "Start a new chat (same as /clear)",
                         section: .session),
        SlashCommandItem(token: "/remember", icon: "pin",
                         zh: "记住一件事，清空会话也不丢",
                         en: "Remember something — survives clearing the chat",
                         section: .memory)
    ]

    /// 当前输入应该展示哪些候选。返回空数组 = 不弹面板。
    ///
    /// 三道收敛，方向一律「宁可不弹」：
    /// 1. 必须以 `/` 开头（前导空格都不弹 —— 保守，不影响 `parse` 的既有语义）
    /// 2. 首字符之后**不许再出现斜杠或空白** —— `/Users/…`、`//new`、`/new foo` 全部出局
    /// 3. 剩下的做小写前缀匹配；匹配不上就是空（`/Users`、`/newsletter` 天然不弹）
    static func suggestions(for raw: String) -> [SlashCommandItem] {
        guard raw.hasPrefix("/") else { return [] }
        let rest = raw.dropFirst()
        guard !rest.contains(where: { $0.isWhitespace || $0 == "/" }) else { return [] }
        let q = raw.lowercased()
        return palette.filter { $0.token.hasPrefix(q) }
    }
}

/// 「问 AI」的对话策略：裁剪窗口、锚点截断、发模型派生、限额常量。
///
/// **全部是无状态纯函数**（`enum` 当命名空间用）：不 import SwiftUI、不碰 MainActor、
/// 不碰文件系统 —— 所以 `SelfTest` 能直接、彻底地覆盖它。
/// 斜杠命令白名单是本次唯一的安全项，它必须可自检，不能藏在 View 的 `send()` 里。
enum ChatPolicy {
    /// 上下文保留轮数。1 轮 = 1 条 `.me` + 1 条 `.ai`，即最多 30 条。
    ///
    /// ⚠️ 与 `AgentRuntime.maxTurns`（= 4，**单次提问内** agent loop 的决策轮数）
    /// 完全无关，两者命名刻意不同，改动任一处时不要顺手改另一处。
    static let maxContextTurns = 15
    /// 单条输入的硬上限（按 `Character` 计：一个汉字 = 1，一个 emoji 字素簇 = 1）。
    static let maxInputChars = 9999
    /// 计数从这个值起变橙提醒。
    static let inputWarnThreshold = 900

    /// 裁剪到 ≤ `maxTurns` 轮。**这是三处统一裁剪的唯一一处实现**
    /// （屏幕 / 落盘直接用它的结果，发模型的 history 从结果派生）。
    ///
    /// 15 是**上限而非精确值**：窗口起点若切在 `.ai` 上，会向后挪到第一条 `.me`，
    /// 以免屏幕上留下「没有提问的孤儿回答」，代价是实际可能只保留 14.5 轮。
    ///
    /// 锚点若落在窗口之前会被一并丢弃 —— 这是安全的：锚点被裁掉说明锚点之后
    /// 已积累 ≥15 轮，保留窗口本身就完全位于锚点之后，「只发锚点之后」的语义
    /// 自动继续成立，不需要补偿分支。
    static func trim(_ messages: [AIMessage], maxTurns: Int = maxContextTurns) -> [AIMessage] {
        let limit = max(0, maxTurns) * 2
        // limit == 0：一轮都不留，只保留系统消息（锚点）。
        guard limit > 0 else { return messages.filter { $0.role == .system } }

        let conversational = messages.reduce(into: 0) { n, m in
            if m.role == .me || m.role == .ai { n += 1 }
        }
        // 未超限时**原样返回**：不做首条对齐 —— 首条若是 `.ai`，那大概率是未配模型时的
        // `configPrompt`，屏幕上必须显示它。发模型那一份由 `modelHistory` 单独处理。
        guard conversational > limit else { return messages }

        // 从尾部向前扫，累计 me/ai 到第 limit 条时定位下标。
        var counted = 0
        var cut = messages.startIndex
        for idx in messages.indices.reversed() {
            let role = messages[idx].role
            guard role == .me || role == .ai else { continue }
            counted += 1
            if counted == limit { cut = idx; break }
        }
        // 从该下标起向后找第一条 `.me`，窗口起点定到它；找不到就退化为原下标。
        if let start = messages[cut...].firstIndex(where: { $0.role == .me }) {
            return Array(messages[start...])
        }
        return Array(messages[cut...])
    }

    /// 取**最后一个**锚点之后的消息；无锚点则返回全部。
    static func afterAnchor(_ messages: [AIMessage]) -> [AIMessage] {
        guard let idx = messages.lastIndex(where: { $0.isAnchor }) else { return messages }
        return Array(messages[messages.index(after: idx)...])
    }

    /// 派生出发给模型的 history。
    ///
    /// 入参必须是**已 trim 的** `chatMessages`（`AppState` 的不变量保证），
    /// 所以这里不再裁剪，只做派生：
    /// 1. 锚点截断
    /// 2. 排除 `.system` —— 封死「二分映射把 system 当 assistant 喂给模型」的死角
    /// 3. 丢掉开头连续的 `.ai` —— 保证首条是 user。Anthropic 的 `/v1/messages`
    ///    要求 `messages[0].role == "user"`，否则 400；「未配模型 → 发一句 → 收到
    ///    configPrompt(.ai) → 配好模型 → 再发一句」这条路径上首条正好是 assistant。
    /// 4. 映射成 LLMClient 要的元组
    static func modelHistory(_ messages: [AIMessage]) -> [(role: String, content: String)] {
        afterAnchor(messages)
            .filter { $0.role != .system }
            .drop { $0.role == .ai }
            .map { (role: $0.role == .me ? "user" : "assistant", content: $0.text) }
    }

    /// 是否有任何可显示的内容。
    ///
    /// `.me` / `.ai` 始终计入；`.system` 仅当非锚点时计入 ——
    /// 这样配置提示、/remember 回执等系统消息可见，但 /reset 后的纯锚点不触发对话显示。
    /// `modelHistory` 会过滤掉所有 `.system` 消息，不会进入模型上下文。
    static func hasConversation(_ messages: [AIMessage]) -> Bool {
        messages.contains { m in
            m.role == .me || m.role == .ai || (m.role == .system && !m.isAnchor)
        }
    }
}
