import SwiftUI
import Foundation
import AppKit
import MarkdownUI

/// 「问 AI」tab：用自然语言指挥本地 Agent 调用 AI Mac Cleaner 的 skill 完成清理。
///
/// 这一页只负责「说」和「看」，不做任何决策：
/// - 决策在 `AgentRuntime`（纯 AI 多轮 loop，由真实模型驱动）
/// - 能做什么在 `SkillRegistry`（白名单，每个 skill 都对应一条真实 CLI）
/// - 副作用怎么落地在 `AgentBridge`
///
/// 关键边界：**删除类动作绝不经 Agent 之手**。它最多给出 `plan_uninstall`
/// 的预演清单，真正动手要用户在「应用 / 残留」页点确认。

/// 输入框的尺寸口径。放这里不放 ChatPolicy —— 那是纯模型命名空间，不该装 UI 度量。
private enum ComposerMetrics {
    static let visibleLines = 3          // 输入框默认/固定高度按 3 行显示
    static let fontSize: CGFloat = 14    // 与输入法候选字大小对齐，不再用 12.5 小字
    static let lineH: CGFloat = 21       // 单行内容高（font 14 + 行距缓冲）
    static let inset: CGFloat = 10       // TextEditor 上下内边距
    static let inputHeight = CGFloat(visibleLines) * lineH + inset * 2 // ≈ 83
    static let corner: CGFloat = 28      // 千问风格：胶囊大圆角
    static let maxWidth: CGFloat = 720   // 空态建议词卡片的最大宽度（输入框本身跟随软件宽度，见 composer）
    /// 不点放大钮时，输入框随内容自动长高的上限；超过后启用滚动条。
    /// 这个高度同时也是「粘贴大段文本后点放大前」最自然的天花板。
    static let maxAutoHeight: CGFloat = 280
    /// 底部工具栏高度：字数限制、发送钮，以及后续要扩展的按钮都放这里。
    static let footerHeight: CGFloat = 30
    /// 放大态输入框的固定开销（不含文本区、不含斜杠面板）：
    /// Divider(1) + 输入区外层 HStack 上下 padding(12+12) + 胶囊上下内边距(10+6)
    /// + 底部工具栏(30) + 胶囊内 padding(10+6)。
    /// 计算放大态文本区高度时从可用高度里扣掉这部分，保证发送钮永远留在可视区。
    static let composerFixedOverhead: CGFloat = 87
    /// 放大态斜杠命令框自身高度：面板 maxHeight(104) + 上下 padding(6+4)。
    /// 出现斜杠面板时再从可用高度里额外扣掉这部分（自适应：面板消失则回收）。
    static let slashPaletteHeight: CGFloat = 114
}

/// 测量 PageHeader（标题栏 + 右侧工具钮）高度，用于计算放大态输入框可用高度。
private struct HeaderHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct AskAIView: View {
    @EnvironmentObject var state: AppState
    @StateObject private var bridge = AgentBridge()
    // 对话状态（messages / isThinking）住在 AppState 里，不在这里。
    // 这个 View 会随着切 tab 被销毁重建，@State 活不过一次往返。
    @State private var input = ""
    /// 从残留页深链进来时携带的来源约束（看哪一档就判断哪一档）。
    /// 首次发送时交给 Agent session，发送后置 nil。
    @State private var pendingLeftoverScope: LeftoverSource?
    /// 从应用 / 残留 / 进程页深链进来时携带的强制分析范围。
    /// 非 nil 时让 `review_plan` 直接按 `.apps` 或 `.leftovers` 执行，不依赖模型推断。
    @State private var pendingReviewScope: ReviewScope?
    // 注意：这里用普通 @State 而非 @FocusState。本输入框是自定义 NSViewRepresentable，
    // 焦点完全由 ComposerTextView 的 makeFirstResponder 分支手动管理；若用 @FocusState
    // 而没有配套 .focused() modifier，SwiftUI 的 focus 协调器会在每次输入重绘时插手、
    // 收回 NSTextView 的 firstResponder，表现为「输入一个字光标就消失」。
    @State private var inputFocused = false
    @State private var showSettings = false
    @State private var showSkills = false
    @State private var showMemory = false
    @State private var showNewChatConfirm = false
    @State private var slashSelection = 0
    @State private var slashDismissed = false
    /// 输入框右上角放大/缩小：粘贴大段文本时点开，输入框变高方便阅读，再点收起。
    @State private var inputExpanded = false
    /// 当前文本在输入框宽度下排版后所需高度，用于不点放大钮时随内容自动增高。
    @State private var inputContentHeight: CGFloat = ComposerMetrics.inputHeight
    /// 页头（问 AI 标题栏 + 工具钮）高度，用于计算放大态可用高度。
    @State private var headerHeight: CGFloat = 0
    /// body 总高度，用于计算放大态可用高度。
    @State private var bodyHeight: CGFloat = 0
    /// 输入框里一旦开始输入（含 IME 未确认的候选），placeholder 应立即隐藏，
    /// 避免与首字母重影。
    @State private var isTyping = false

    var body: some View {
        GeometryReader { outerGeo in
            ZStack(alignment: .top) {
                // 底层：正常布局。非放大态时 composer 落在底部；放大态隐藏，改由覆盖层承载。
                VStack(spacing: 0) {
                    PageHeader(title: L10n.t("问 AI", "Ask AI"),
                               subtitle: L10n.t("用自然语言清理 Mac，执行删除前会请你确认",
                                                 "Clean your Mac in plain language — it asks before deleting anything")) {
                        modelStatusPill
                        Button {
                            showSkills = true
                        } label: {
                            Image(systemName: "square.grid.2x2")
                                .font(.system(size: 13))
                        }
                        .buttonStyle(.plain)
                        .help(L10n.t("查看 Agent 可调用的 skill", "See the skills the agent can call"))
                        Button {
                            showSettings = true
                        } label: {
                            Image(systemName: "gearshape")
                                .font(.system(size: 13))
                        }
                        .buttonStyle(.plain)
                        .help(L10n.t("配置模型（OpenAI / Anthropic / 自定义）",
                                     "Configure model (OpenAI / Anthropic / custom)"))
                        // 记忆与记录文件收进一个菜单：这两项都是低频入口，
                        // 摊平成按钮会把头部挤成一排图标，反而让高频的「新会话」难找。
                        Menu {
                            Button {
                                showMemory = true
                            } label: {
                                Label(state.memoryNotes.isEmpty
                                        ? L10n.t("长期记忆…", "Long-term memory…")
                                        : L10n.t("长期记忆（\(state.memoryNotes.count)）…",
                                                 "Long-term memory (\(state.memoryNotes.count))…"),
                                      systemImage: "brain")
                            }
                            Divider()
                            Button {
                                RevealService.revealDataFile(ChatStore.shared.fileURL)
                            } label: {
                                Label(L10n.t("在 Finder 中显示对话记录", "Reveal chat history in Finder"),
                                      systemImage: "folder")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .font(.system(size: 13))
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .frame(width: 18)
                        .help(L10n.t("记忆与对话记录", "Memory and chat history"))
                        if state.chatHasConversation {
                            Button(L10n.t("新会话", "New chat")) { showNewChatConfirm = true }
                                .controlSize(.small)
                        }
                    }
                    .background(GeometryReader { geo in
                        Color.clear.preference(key: HeaderHeightPreferenceKey.self, value: geo.size.height)
                    })
                    Divider()
                    if !state.chatHasConversation && !state.chatIsThinking { emptyState } else { chatLog }
                    if !inputExpanded { composer }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

                // 放大态覆盖层：铺满整个聊天区（页头以下），遮挡下方标题与对话内容；
                // 页头区域用透明占位并放行点击，保留「新会话 / 设置」等按钮可用。
                if inputExpanded {
                    VStack(spacing: 0) {
                        Color.clear
                            .frame(height: headerHeight)
                            .allowsHitTesting(false)
                        composer
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                            .background(Theme.bgCanvas)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .zIndex(10)
                    .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .onPreferenceChange(HeaderHeightPreferenceKey.self) { headerHeight = $0 }
            .onChange(of: outerGeo.size.height) { bodyHeight = $1 }
            .onAppear {
                bodyHeight = outerGeo.size.height
                bridge.attach(state)
                consumePendingPrompt()
            }
            // 已在问 AI 页时再从别的 tab 深链进来：selectedTab 没变，靠这个补捉。
            .onChange(of: state.askAIPendingPrompt) { _, _ in consumePendingPrompt() }
            .sheet(isPresented: $showSettings) { AIModelSettingsSheet() }
            .sheet(isPresented: $showSkills) { SkillCatalogSheet() }
            .sheet(isPresented: $showMemory) { MemorySheet() }
            .alert(L10n.t("开始新会话", "Start a new chat?"), isPresented: $showNewChatConfirm) {
                Button(L10n.t("取消", "Cancel"), role: .cancel) {}
                Button(L10n.t("清空并开始新会话", "Clear and start new"), role: .destructive) {
                    runNewChat()
                }
            } message: {
                Text(L10n.t("当前对话历史将被清空。长期记忆（/remember 记的内容）不受影响。",
                            "The current chat history will be cleared. Long-term memories (saved via /remember) are untouched."))
            }
            // 上下键在 SwiftUI 集成下的 NSTextView 里接收不可靠，改由全局 NSEvent monitor 拦截：
            // 面板显示时吞掉上下键并移动选中项；面板隐藏时放行，光标才可正常移动。
            .onAppear { SlashKeyInterceptor.shared.setActive(showSlashPalette) }
            .onDisappear { SlashKeyInterceptor.shared.setActive(false) }
            .onChange(of: showSlashPalette) { _, on in
                SlashKeyInterceptor.shared.setActive(on)
            }
            .onReceive(NotificationCenter.default.publisher(for: .slashPaletteMove)) { note in
                guard showSlashPalette, !slashMatches.isEmpty else { return }
                let dir = (note.object as? Int) ?? 0
                slashSelection = (slashSelection + dir + slashMatches.count) % slashMatches.count
            }
        }
    }
    // 头部右侧：当前使用的模型。未配置时点击去设置；已配置时可切换默认/具体模型。
    private var modelStatusPill: some View {
        Group {
            if state.modelStore.selectable.isEmpty {
                Button {
                    showSettings = true
                } label: {
                    pill(text: L10n.t("未配置模型", "Model not set"),
                         bg: Theme.riskUncertainBg, border: Theme.riskUncertainBorder,
                         fg: Theme.riskUncertainText)
                }
                .buttonStyle(.plain)
                .help(L10n.t("点此去配置模型（需要 API Key）", "Tap to configure a model (API key required)"))
            } else {
                Menu {
                    ForEach(state.modelStore.selectable) { p in
                        Button {
                            state.modelStore.activeID = p.id
                        } label: {
                            HStack(spacing: 6) {
                                Text(ModelConfigStore.displayName(p))
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                                if state.activeConfig?.id == p.id {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }

                    Divider()

                    Button {
                        showSettings = true
                    } label: {
                        Label(L10n.t("管理模型…", "Manage models…"), systemImage: "gearshape")
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(currentModelLabel)
                            .font(.system(size: 11, weight: .semibold))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .bold))
                    }
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Theme.aiBg, in: Capsule())
                    .overlay(Capsule().stroke(Theme.aiBorder, lineWidth: 1))
                    .foregroundStyle(Theme.aiText)
                }
                .help(L10n.t("切换当前对话使用的模型", "Switch the model used for this chat"))
            }
        }
    }

    /// 顶部 Pill 上显示的模型名：直接展示当前实际使用的模型档。
    private var currentModelLabel: String {
        guard let cfg = state.activeConfig else {
            return L10n.t("未配置模型", "Model not set")
        }
        return ModelConfigStore.displayName(cfg)
    }

    /// 已配置至少一个模型档 —— 这是「问 AI」能跑的前提。
    private var modelReady: Bool {
        state.modelReady
    }

    private var slashMatches: [SlashCommandItem] { ChatCommand.suggestions(for: input) }

    private var showSlashPalette: Bool {
        !slashDismissed && !slashMatches.isEmpty && !state.chatIsThinking
    }

    private var slashHighlighted: SlashCommandItem? {
        guard showSlashPalette else { return nil }
        return slashMatches.indices.contains(slashSelection) ? slashMatches[slashSelection]
                                                             : slashMatches.first
    }

    private func pill(text: String, bg: Color, border: Color, fg: some ShapeStyle) -> some View {
        Text(text)
            .font(.system(size: 10))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(bg, in: Capsule())
            .overlay(Capsule().stroke(border, lineWidth: 1))
            .foregroundStyle(fg)
    }

    // MARK: - 空态（首屏）

    private var emptyState: some View {
        ScrollView {
            VStack(spacing: 0) {
                Spacer(minLength: 40)

                aiGreeting

                if !modelReady {
                    configCard
                        .padding(.top, 28)
                }

                if modelReady {
                    promptChips
                        .padding(.top, 28)
                }

                Spacer(minLength: 80)
            }
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity, minHeight: 420)
            .background(Theme.bgCanvas)
        }
        .background(Theme.bgCanvas)
    }

    /// 千问风格首屏：AI 图标 + 居中大标题 + 副标题。
    private var aiGreeting: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(LinearGradient(colors: [Theme.aiPrimary, Theme.aiDeep],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 52, height: 52)
                Image(systemName: "sparkles")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(.white)
            }

            VStack(spacing: 6) {
                Text(L10n.t("你好，我是 AI Mac Cleaner", "Hello, I'm AI Mac Cleaner"))
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(L10n.t("用自然语言清理 Mac，执行删除前会请你确认",
                             "Clean your Mac in plain language — it asks before deleting anything"))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
        }
    }

    private var promptChips: some View {
        let items: [(String, String)] = [
            ("sparkles",        L10n.t("看看装了哪些 AI 工具，能清理吗", "Check installed AI tools for cleanup")),
            ("wand.and.rays",   L10n.t("扫一遍所有残留", "Scan all leftovers")),
            ("waveform.path.ecg", L10n.t("列出后台进程", "List background processes")),
            ("bolt.fill",       L10n.t("ChatGPT 占的空间有多大？", "How much space does ChatGPT take?")),
            ("magnifyingglass", L10n.t("看看有什么可以清理的", "See what can be cleaned up")),
            ("macwindow",       L10n.t("macOS 工具使用指南", "macOS tools guide"))
        ]
        return FlowRow(spacing: 10) {
            ForEach(items, id: \.1) { icon, text in
                Button {
                    // 只填入、不发送：建议词是起点不是终点，用户往往要改一改
                    //（换个 app 名、加个限定）再发。直接发出去等于替他做主。
                    inputFocused = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        input = text
                    }
                } label: {
                    Label(text, systemImage: icon)
                        .font(.system(size: 12))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Theme.bgSurface, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.divider, lineWidth: 1))
                        .foregroundStyle(.primary)
                }
                .buttonStyle(.plain)
                .help(L10n.t("填入输入框，可修改后按回车发送",
                             "Fills the input box — edit it, then press Return"))
            }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: ComposerMetrics.maxWidth)
    }

    // 未配置模型时的醒目提示卡：点一下直接去设置。
    private var configCard: some View {
        Button {
            showSettings = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.riskUncertainText)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.t("请先配置模型", "Configure a model first"))
                        .font(.system(size: 13, weight: .semibold))
                    Text(L10n.t("「问 AI」需要 API Key 才能调用模型。点这里去填（OpenAI / Anthropic 兼容都行）。",
                                "Ask AI needs an API key to call the model. Tap to set it up — OpenAI- or Anthropic-compatible both work."))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Text(L10n.t("去配置 →", "Configure →"))
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Theme.accent)
            }
            .padding(12)
            .frame(maxWidth: 460)
            .background(Theme.riskUncertainBg, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.riskUncertainBorder, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: - 对话记录

    private var chatLog: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // 与下方输入框保持相同的左右边距，让对话记录宽度和输入框一致。
                HStack(spacing: 0) {
                    Spacer(minLength: 40)
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(Array(state.chatMessages.enumerated()), id: \.element.id) { idx, m in
                            VStack(alignment: .leading, spacing: 8) {
                                if shouldShowDateHeader(at: idx) {
                                    HStack(spacing: 8) {
                                        Divider().frame(width: 1).overlay(Theme.divider)
                                        Text(dateString(m.createdAt))
                                            .font(.system(size: 10.5, weight: .medium))
                                            .foregroundStyle(.secondary)
                                        Divider().frame(width: 1).overlay(Theme.divider)
                                    }
                                    .id("date-\(m.id)")
                                }

                                if m.role == .system {
                                    SystemDivider(message: m)
                                } else {
                                    MessageBubble(
                                        message: m,
                                        initialExpanded: bubbleInitialExpanded(at: idx),
                                        collapsible: bubbleCollapsible(at: idx)
                                    ) {
                                        if let tab = m.redirect {
                                            switch tab {
                                            case .apps:      state.selectedTab = .apps
                                            case .leftovers: state.selectedTab = .leftovers
                                            case .processes: state.selectedTab = .processes
                                            }
                                        }
                                    }
                                    .id(m.id)
                                }
                            }
                        }
                        if state.chatIsThinking {
                            ThinkingBubble(steps: bridge.steps, running: bridge.runningCommand)
                                .id("thinking")
                        }
                    }
                    .padding(.vertical, 16)
                    .frame(maxWidth: .infinity)
                    Spacer(minLength: 40)
                }
                .frame(maxWidth: .infinity)
                .background(Theme.bgCanvas)
            }
            .background(Theme.bgCanvas)
            .onAppear {
                // 切 tab 回来 / 冷启动恢复时滚到最后一条。
                // 延迟一帧：onAppear 时 ScrollView 还没完成布局，直接 scrollTo 无效。
                guard let last = state.chatMessages.last else { return }
                DispatchQueue.main.async {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
            .onChange(of: state.chatMessages.count) { _, _ in
                if state.chatIsThinking {
                    proxy.scrollTo("thinking", anchor: .bottom)
                } else if let last = state.chatMessages.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
            .onChange(of: bridge.steps.count) { _, _ in
                if state.chatIsThinking { proxy.scrollTo("thinking", anchor: .bottom) }
            }
            // 用户发送后 chatIsThinking 变 true、思考气泡出现；之前没有监听这个
            // 状态，于是只滚到用户消息、思考气泡留在可视区下方。这里补上。
            // 延迟一帧：状态翻转时气泡还没完成布局，直接 scrollTo 无效。
            .onChange(of: state.chatIsThinking) { _, isThinking in
                if isThinking {
                    DispatchQueue.main.async { proxy.scrollTo("thinking", anchor: .bottom) }
                }
            }
        }
    }

    // MARK: - 气泡默认折叠策略

    /// 气泡初始是否展开：长消息一律默认折叠（用户问题、AI 回复都如此），
    /// 短消息没有折叠按钮、直接完整展示。
    private func bubbleInitialExpanded(at idx: Int) -> Bool {
        bubbleCollapsible(at: idx) ? false : true
    }

    /// 气泡是否可折叠：文本足够长才允许折叠。用户长输入、AI 长回复都可折叠。
    private func bubbleCollapsible(at idx: Int) -> Bool {
        let m = state.chatMessages[idx]
        let estimatedLines = CGFloat(m.text.count) / 58
        let longEnough = estimatedLines > CGFloat(MessageBubble.collapsedLines)
        switch m.role {
        case .me, .ai:  return longEnough
        default:        return false
        }
    }

    // MARK: - 日期 / 时间分隔

    /// 只有当跨天才单独显示日期分隔（如 2026.8.11）；系统提示（锚点）不带头。
    /// 真实对话的第一条也显示当天日期（往前跳过 system 消息找相邻真实消息）。
    private func shouldShowDateHeader(at idx: Int) -> Bool {
        guard idx < state.chatMessages.count else { return false }
        let m = state.chatMessages[idx]
        if m.role == .system { return false }
        var j = idx - 1
        while j >= 0, state.chatMessages[j].role == .system { j -= 1 }
        if j < 0 { return true }
        return !Calendar.current.isDate(state.chatMessages[j].createdAt, inSameDayAs: m.createdAt)
    }

    private func dateString(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "M月d日"
        f.locale = Locale(identifier: "zh_CN")
        return f.string(from: d)
    }

    // MARK: - 输入区

    private var composer: some View {
        VStack(spacing: 0) {
            // 命令面板放在输入区上方，与下方输入框同宽、左右对齐。
            // 给面板容器 zIndex(1)，确保它在绘制顺序上高于白色胶囊，不被输入框遮挡。
            if showSlashPalette {
                HStack(spacing: 0) {
                    Spacer(minLength: 40)
                    SlashPalette(items: slashMatches,
                                 selection: slashSelection,
                                 onHover: { slashSelection = $0 },
                                 onPick:  { acceptSlash($0) })
                        .padding(.horizontal, 12)
                        .padding(.top, 6)
                        .padding(.bottom, 4)
                        .transition(.opacity)
                        .frame(maxWidth: .infinity)
                    Spacer(minLength: 40)
                }
                // 给面板容器统一填上聊天区底色，让透明面板内部与外部完全同色；
                // 同时避免 composer VStack 透明时露出窗口白底。
                .background(Theme.bgCanvas)
                .zIndex(1)
            }

            Divider()
                .opacity(0.6)

            // 输入框：白色胶囊，宽度与上方消息气泡一致；其余区域保持聊天背景灰色。
            HStack(spacing: 0) {
                Spacer(minLength: 40)
                composerInput
                Spacer(minLength: 40)
            }
            .padding(.top, 12)
            .padding(.bottom, 12)
            .background(Theme.bgCanvas)
            .animation(.easeOut(duration: 0.12), value: showSlashPalette)
            .onChange(of: input) { _, newValue in
                // 硬性截断到上限：防止输入框继续累积，确保计数器永远不超过 maxInputChars。
                // 之前"只禁发不裁字"在 GUI 上被用户感知为 bug（显示 1105/1000），
                // 因此改为输入层直接截断。
                if newValue.count > ChatPolicy.maxInputChars {
                    input = String(newValue.prefix(ChatPolicy.maxInputChars))
                }
                // 外部（如建议词、斜杠命令、程序清空）改变 input 时，同步 placeholder 状态。
                isTyping = !newValue.isEmpty
                slashDismissed = false
                slashSelection = 0
            }
        }
    }

    /// 输入框文本区高度（不含底部工具栏、不含 padding）。
    /// - 不点放大钮：随 `inputContentHeight` 在 3 行最小高度 ~ maxAutoHeight 之间弹性变化。
    /// - 点放大钮：覆盖层已独占「页头以下」整个聊天区，文本区高度 = 该区域高度
    ///   减去固定开销（`composerFixedOverhead`）与斜杠命令框高度（出现时才扣，
    ///   自适应——面板消失则高度回收）。这样发送钮永远留在可视区，且输入 `/` 唤出
    ///   命令框时输入框自动让位、不再把发送钮挤出窗口。
    private var textAreaHeight: CGFloat {
        if inputExpanded {
            var reserved = ComposerMetrics.composerFixedOverhead
            if showSlashPalette { reserved += ComposerMetrics.slashPaletteHeight }
            let available = max(0, bodyHeight - headerHeight - reserved)
            return max(ComposerMetrics.inputHeight, available)
        } else {
            let desired = max(ComposerMetrics.inputHeight, inputContentHeight)
            return min(desired, ComposerMetrics.maxAutoHeight)
        }
    }

    /// 输入框整体高度（含编辑区、底部工具栏、内边距），防止右侧 Spacer 把框撑到窗口高度。
    private var inputBoxHeight: CGFloat {
        textAreaHeight + ComposerMetrics.footerHeight + 16 // 10 top + 6 bottom padding inside the pill
    }

    /// 千问风格：白色胶囊输入框。左侧多行编辑区 + 底部工具栏，右侧按钮列。
    /// 外部是聊天背景灰；输入框内部为白色，与消息气泡底色拉平。
    private var composerInput: some View {
        HStack(alignment: .bottom, spacing: 0) {
            // 左侧：文字可输入区
            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .topLeading) {
                    ComposerTextView(
                        text: $input,
                        isFocused: Binding<Bool>(
                            get: { inputFocused },
                            set: { inputFocused = $0 }
                        ),
                        isTyping: $isTyping,
                        contentHeight: $inputContentHeight,
                        expanded: inputExpanded,
                        onReturn: {
                            if let item = slashHighlighted {
                                acceptSlash(item)
                                return true
                            }
                            if canSend {
                                send(input)
                                return true
                            }
                            return true // 空输入时回车也不让系统响铃
                        },
                        onOptionReturn: { input.append("\n") },
                        onTab: {
                            guard let item = slashHighlighted else { return false }
                            input = item.token
                            return true
                        },
                        onEscape: {
                            if showSlashPalette {
                                slashDismissed = true
                                return true
                            }
                            if inputExpanded {
                                withAnimation(.easeOut(duration: 0.15)) { inputExpanded = false }
                                return true
                            }
                            return false
                        }
                    )
                    .frame(height: textAreaHeight, alignment: .topLeading)

                    // placeholder：与输入文本同字号、同颜色层级；一旦开始输入
                    // （包括 IME 的首个拼音字母）立即隐藏，避免与候选文字重影。
                    if input.isEmpty && !isTyping {
                        Text(L10n.t("向 AI 提问", "Ask AI"))
                            .font(.system(size: ComposerMetrics.fontSize))
                            .foregroundStyle(.tertiary)
                            .lineSpacing(2)
                            .allowsHitTesting(false)
                    }
                }

                // 底部工具栏：文字不可输入，专门放字数限制和扩展按钮。
                composerFooter
                    .frame(height: ComposerMetrics.footerHeight)
            }

            // 右侧：按钮列，文字不可输入；展开钮在上，发送钮在下，中间留白。
            VStack(spacing: 0) {
                expandButton
                Spacer()
                sendButton
            }
            .padding(.leading, 8)
        }
        .frame(height: inputBoxHeight)
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .animation(.easeOut(duration: 0.12), value: textAreaHeight)
        .background(Theme.bgSurface, in: RoundedRectangle(cornerRadius: ComposerMetrics.corner))
        .overlay(RoundedRectangle(cornerRadius: ComposerMetrics.corner)
            .stroke(inputFocused ? Theme.accentBorder : Theme.divider, lineWidth: 1))
    }

    /// 底部工具栏：字数限制；后续可在此扩展其他功能按钮。
    private var composerFooter: some View {
        HStack {
            Spacer()
            Text(counterText)
                .font(.system(size: 9.5))
                // 等宽数字：否则 999 → 1000 时宽度跳动。
                .monospacedDigit()
                .foregroundStyle(counterStyle)
                .help(overLimit
                      ? L10n.t("已超出 \(ChatPolicy.maxInputChars) 字上限，请精简后发送",
                               "Over the \(ChatPolicy.maxInputChars)-character limit — please shorten it")
                      : "")
        }
    }

    /// 右上角放大/缩小钮。
    private var expandButton: some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) { inputExpanded.toggle() }
        } label: {
            Image(systemName: inputExpanded
                  ? "arrow.down.right.and.arrow.up.left"
                  : "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(6)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(inputExpanded
              ? L10n.t("缩小输入框", "Collapse input box")
              : L10n.t("放大输入框", "Expand input box"))
    }

    /// 发送钮。
    private var sendButton: some View {
        Button { send(input) } label: {
            Image(systemName: "arrow.up")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(canSend ? Theme.accent : Color.secondary.opacity(0.35), in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(!canSend)
    }

    /// 按 `Character` 计数：一个汉字 = 1，一个 emoji 字素簇 = 1。
    /// **不用** `utf8.count` / `utf16.count`，那会让中文用户莫名其妙地少打两千字。
    private var inputCount: Int { input.count }

    private var overLimit: Bool { inputCount > ChatPolicy.maxInputChars }

    /// 计数器文本，千分位格式化（与参考截图的 "1,105/1,000" 一致）。
    private var counterText: String {
        let fmt = NumberFormatter()
        fmt.numberStyle = .decimal
        let current = fmt.string(from: NSNumber(value: inputCount)) ?? "\(inputCount)"
        let max = fmt.string(from: NSNumber(value: ChatPolicy.maxInputChars)) ?? "\(ChatPolicy.maxInputChars)"
        return "\(current)/\(max)"
    }

    /// 三档配色。默认用 `.secondary` 保证「灰色」可读；警告/超限再用主题色。
    /// `HierarchicalShapeStyle` 与 `Color` 类型不同，统一包一层 `AnyShapeStyle`。
    private var counterStyle: AnyShapeStyle {
        if overLimit { return AnyShapeStyle(Theme.destructive) }
        if inputCount >= ChatPolicy.inputWarnThreshold { return AnyShapeStyle(Theme.riskUncertainText) }
        return AnyShapeStyle(.secondary)
    }

    private var canSend: Bool {
        !input.trimmingCharacters(in: .whitespaces).isEmpty
            && !state.chatIsThinking
            && !overLimit
    }

    /// 补全只做一件事：把 token 填回输入框，然后**走和手打完全相同的那条发送路径**。
    /// 白名单仍是唯一闸门，这里不做任何命令分发。
    ///
    /// /remember 是唯一带参命令：只填输入框（加尾部空格），不发送，让用户继续写内容。
    private func acceptSlash(_ item: SlashCommandItem) {
        if item.token == ChatCommand.rememberToken {
            input = item.token + " "
            slashDismissed = true
            return
        }
        input = item.token
        send(item.token)
    }

    // MARK: - 发送

    /// 从应用 / 残留 / 进程页深链进来时，把预填问句灌进输入框并聚焦，消费后置 nil。
    private func consumePendingPrompt() {
        guard let prompt = state.askAIPendingPrompt else { return }
        state.askAIPendingPrompt = nil
        // 一并消费来源约束（残留页当前档）和强制分析范围；首次发送时约束给 Agent，之后置 nil。
        pendingLeftoverScope = state.askAIPendingLeftoverScope
        state.askAIPendingLeftoverScope = nil
        pendingReviewScope = state.askAIPendingReviewScope
        state.askAIPendingReviewScope = nil
        inputFocused = true
        // 延迟一帧再填文本：与建议词按钮一致——先让焦点落进输入框再写，避免光标丢失。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { input = prompt }
    }

    private func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // 闸门 1/2/3：空输入、重入、超限。canSend 已经覆盖这三条，
        // 这里是二次防线（回车走的是 onSubmit，绕不开它）。
        guard canSend else { return }

        // 闸门 4：斜杠命令白名单。只有整条输入全等 /new · /clear · /reset 才命中，
        // `/Users/…`、`/tmp/x`、`/new foo`、`//new` 一律照常发给模型。
        if let command = ChatCommand.parse(text) {
            input = ""
            isTyping = false
            switch command {
            case .new:                runNewChat()
            case .reset:              runResetContext()
            case .remember(let body): runRemember(raw: trimmed, body: body)
            }
            return
        }

        // 没配模型：不发请求，直接提示去配置并弹出设置页。
        // 系统角色：能被 hasConversation 识别为「有内容」以显示在屏幕上，
        // 但会被 modelHistory 自动过滤掉，不会进入模型上下文。
        guard modelReady else {
            input = ""
            isTyping = false
            state.appendChat(AIMessage(role: .system, text: AgentRuntime.configPrompt))
            showSettings = true
            return
        }
        input = ""
        isTyping = false
        // 深链来源约束：本次发送用掉后置 nil，避免后续追问也带上旧范围。
        let scope = pendingLeftoverScope
        pendingLeftoverScope = nil
        let reviewScope = pendingReviewScope
        pendingReviewScope = nil
        // ⚠️ history 必须在 appendChat(.me) **之前**取：
        // AgentRuntime 内部会自己 append 一条 (role: "user", content: goal)，
        // 顺序调换会让本轮问题被发两遍。
        let history = state.chatModelHistory
        state.appendChat(AIMessage(role: .me, text: trimmed))
        state.chatIsThinking = true
        bridge.reset()

        // 记忆块在发请求前从 AppState 现取：用户可能刚在面板里删掉一条，
        // 那一条从这一刻起就不该再影响模型。
        let memory = state.memoryPromptBlock

        Task {
            let runtime = AgentRuntime(config: state.activeConfig, bridge: bridge, memory: memory)
            let run = await runtime.run(goal: trimmed, history: history, session: bridge.makeSession(leftoverScope: scope, reviewScope: reviewScope))

            var body = run.answer
            if let note = run.note { body += "\n\n" + note }
            state.appendChat(AIMessage(role: .ai, text: body,
                                       steps: run.steps,
                                       redirect: run.redirect,
                                       awaitingApproval: run.awaitingApproval))
            state.chatIsThinking = false
            bridge.reset()
        }
    }

    /// `/new`（含 `/clear` 别名）与头部「新会话」按钮共用的同一条路径 ——
    /// 两个入口效果必须完全一致，所以只有这一个实现。
    private func runNewChat() {
        state.clearChat()
        bridge.reset()
    }

    /// `/reset`：打上下文锚点。屏幕记录与落盘都保留，只是模型不再看到锚点之前的内容。
    /// `bridge.reset()` 清的是本次运行的实时进度，与上下文无关，两者职责不同、都要调。
    private func runResetContext() {
        state.resetChatContext()
        bridge.reset()
    }

    /// `/remember`：写一条长期记忆。不发网络请求，立即落盘。
    ///
    /// 用户原话(.me) + 系统回执(.system)：回执可见但不进入模型上下文。
    private func runRemember(raw: String, body: String) {
        let receipt = state.rememberNote(body)
        state.appendChat(AIMessage(role: .me, text: raw))
        state.appendChat(AIMessage(role: .system, text: receipt))
    }

}

/// `/reset` 打下的上下文分割线。
///
/// 不塞进 `MessageBubble`：气泡是「头像 + 圆角 + 左右对齐」，这里是一条横贯的
/// 分割线，两套布局硬合并会让那个 View 变成双形态的 if 迷宫。
///
/// 文案按 `isAnchor` 实时取 `L10n`，不读 `message.text` —— 这样用户切换语言后，
/// 历史里的旧锚点也跟着变，不会中英混排。`text` 落盘只作人肉可读的 fallback。
private struct SystemDivider: View {
    let message: AIMessage

    var body: some View {
        HStack(spacing: 10) {
            rule
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize()
            rule
        }
        .frame(maxWidth: .infinity)
    }

    /// 左右两侧的横线。
    ///
    /// 这里刻意**不用** `Divider()`：在 HStack 里 `Divider()` 是**竖**的
    /// （它跟随父栈的轴向），渲染出来是文案两侧各一根小竖杠，不是设计要的
    /// 「————— 文案 —————」。用 1pt 的 Rectangle 才能得到横贯的分割线。
    private var rule: some View {
        Rectangle()
            .fill(Theme.divider)
            .frame(height: 1)
    }

    private var label: String {
        message.isAnchor
            ? L10n.t("上下文已重置 —— 以下开始不再携带之前的对话",
                     "Context reset — messages above are no longer sent to the model")
            : message.text
    }
}

/// 自托管的多行输入框。
///
/// SwiftUI `TextEditor` 在 macOS 上有默认的 `textContainerInset`，导致光标和 overlay placeholder
/// 对不齐。这里直接用 `NSTextView` 并清零内边距，同时自己处理回车/⌥回车/上下/Tab/Esc。
private struct ComposerTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    @Binding var isTyping: Bool
    /// 当前文本排版后需要的文本区高度（含上下内边距），用于 SwiftUI 层随内容自动增高。
    @Binding var contentHeight: CGFloat

    /// 是否处于放大态。展开/缩小动画期间据此临时压制滚动条显隐，消除闪屏。
    var expanded: Bool

    var onReturn: () -> Bool
    var onOptionReturn: () -> Void
    var onTab: () -> Bool
    var onEscape: () -> Bool

    /// 输入框滚动容器：在展开/缩小动画窗口内抑制 `reflectScrolledClipView`，
    /// 避免每帧高度变化触发 autohidesScrollers 把滚动条闪一下又收回去。
    final class ComposerScrollView: NSScrollView {
        /// true 时跳过滚动条显隐与滑块重算（动画期间）。
        var suppressScrollerFlash = false
        /// 上一次的 expanded 值，用于 detect 状态翻转。
        var wasExpanded = false

        override func reflectScrolledClipView(_ clipView: NSClipView) {
            if suppressScrollerFlash { return }
            super.reflectScrolledClipView(clipView)
        }
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = ComposerScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        // 覆盖式滚动条：绘制在内容之上、不挤占布局，显隐为系统淡入淡出，配合下方
        // 动画期抑制逻辑，展开/缩小时不再出现「闪一下消失」的横向抖动。
        scrollView.scrollerStyle = .overlay
        // 内容未超出可视高度时不显示滚动条；展开后空间足够也自动隐藏。
        scrollView.autohidesScrollers = true
        scrollView.focusRingType = .none

        let textView = KeyHandlingTextView()
        textView.isRichText = false
        textView.isSelectable = true
        textView.isEditable = true
        textView.drawsBackground = false
        textView.font = NSFont.systemFont(ofSize: ComposerMetrics.fontSize)
        textView.textColor = NSColor.labelColor
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize.zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.delegate = context.coordinator
        textView.onFocusChange = { focused in
            DispatchQueue.main.async { self.isFocused = focused }
        }
        textView.onContentChange = { [unowned coordinator = context.coordinator] in
            coordinator.contentChanged()
        }
        textView.onReturn = onReturn
        textView.onOptionReturn = onOptionReturn
        textView.onTab = onTab
        textView.onEscape = onEscape

        scrollView.documentView = textView
        context.coordinator.textView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? KeyHandlingTextView else { return }
        // 展开/缩小切换时：动画期间强制隐藏滚动条并跳过 reflect（滚动条显隐与滑块重算都在
        // reflectScrolledClipView 里），结束后恢复可见性并让 reflect 按真实溢出决定显隐。
        // 仅「跳过 reflect」不够——展开态里内容本就溢出、滚动条原本可见，跳过会让它全程露着、
        // 动画后才被 reflect 藏掉，表现为「闪一下消失」被推迟。这里改为主动 isHidden=true。
        if let cs = scrollView as? ComposerScrollView, cs.wasExpanded != expanded {
            cs.wasExpanded = expanded
            cs.suppressScrollerFlash = true
            cs.verticalScroller?.isHidden = true
            let target = cs
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { [weak target] in
                guard let sv = target else { return }
                sv.suppressScrollerFlash = false
                sv.verticalScroller?.isHidden = false
                sv.reflectScrolledClipView(sv.contentView)
            }
        }
        if textView.string != text {
            textView.string = text
        }
        // 排版稳定后把内容高度同步回 SwiftUI，驱动输入框自动增高。
        updateContentHeight(textView)
        // 每次 body 重算都会生成新的 closure，必须同步回 NSTextView。
        textView.onReturn = onReturn
        textView.onOptionReturn = onOptionReturn
        textView.onTab = onTab
        textView.onEscape = onEscape
        textView.onFocusChange = { focused in
            DispatchQueue.main.async { self.isFocused = focused }
        }

        // 斜杠面板状态通过 Binding 同步，确保上下键读取到的永远是最新值。
        // 注意：不要在这里为 !isFocused 强制 resignFirstResponder。
        // 用户第一次点击文本框时，NSTextView 已经 becomeFirstResponder，但通知 SwiftUI
        // 改 isFocused=true 是异步的；updateNSView 如果在这期间带着旧值 false 进来，
        // 会抢走焦点，导致「点第一下光标没落进去，点第二下才进去」的竞态。
        if isFocused, let window = textView.window, window.firstResponder != textView {
            window.makeFirstResponder(textView)
        }
    }

    /// 测量 NSTextView 在当前宽度下排完版需要的高度，写回 `contentHeight`。
    /// 值用于 SwiftUI 层按 `min...max(..., maxAutoHeight)` 自动调整输入框高度。
    private func updateContentHeight(_ textView: NSTextView) {
        guard let lm = textView.layoutManager, let tc = textView.textContainer else { return }
        lm.ensureLayout(for: tc)
        let textH = lm.usedRect(for: tc).height
        let newH = textH + ComposerMetrics.inset * 2
        // 以 0.5 为粒度向上取整，避免像素级抖动反复触发 SwiftUI 重绘。
        let rounded = ceil(newH * 2) / 2
        if abs(contentHeight - rounded) > 0.5 {
            contentHeight = rounded
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextView
        weak var textView: KeyHandlingTextView?

        init(_ parent: ComposerTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? KeyHandlingTextView else { return }
            // 直接同步写回即可：焦点抖动的根因是 @FocusState（已改为 @State），
            // 不是这里的同步写回。延迟写回反而会引入快速输入丢字的竞态。
            parent.text = textView.string
            syncTypingState(textView)
        }

        /// 在 insertText / setMarkedText / deleteBackward 等原始输入事件里立即调用，
        /// 比 textDidChange 更早（且对 IME 首字母更可靠），用来立刻隐藏 placeholder。
        func contentChanged() {
            guard let textView = textView else { return }
            parent.text = textView.string
            syncTypingState(textView)
        }

        private func syncTypingState(_ textView: KeyHandlingTextView) {
            let empty = textView.string.isEmpty && !textView.hasMarkedText()
            parent.isTyping = !empty
        }
    }
}

/// 负责拦截快捷键的 NSTextView 子类。
///
/// 注意：上下箭头（选中斜杠命令）不在这里处理 —— 在 SwiftUI 的 NSViewRepresentable
/// 集成下，NSTextView 收到的 keyDown 对方向键不可靠（事件常被先一步派发）。
/// 上下键改由 AskAIView 顶层的 `NSEvent` 本地 monitor 统一拦截，见 `SlashKeyInterceptor`。
private final class KeyHandlingTextView: NSTextView {
    var onFocusChange: ((Bool) -> Void)?
    var onContentChange: (() -> Void)?
    var onReturn: (() -> Bool)?
    var onOptionReturn: (() -> Void)?
    var onTab: (() -> Bool)?
    var onEscape: (() -> Bool)?

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onFocusChange?(true) }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { onFocusChange?(false) }
        return ok
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        super.insertText(string, replacementRange: replacementRange)
        onContentChange?()
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        onContentChange?()
    }

    override func deleteBackward(_ sender: Any?) {
        super.deleteBackward(sender)
        onContentChange?()
    }

    override func keyDown(with event: NSEvent) {
        let keyCode = event.keyCode
        let option = event.modifierFlags.contains(.option)

        switch keyCode {
        case 36: // Return
            if option {
                onOptionReturn?()
                return
            }
            if onReturn?() == true { return }
        case 48: // Tab
            if onTab?() == true { return }
        case 53: // Esc
            if onEscape?() == true { return }
        default:
            break
        }
        super.keyDown(with: event)
    }
}

/// 斜杠命令补全面板。
///
/// **纯展示**：它只把候选摆出来，并把用户选中的 token 交回上层填进输入框。
/// 一条命令成不成立仍然只由 `ChatCommand.parse` 的全等白名单说了算 ——
/// 这里绝不能出现「按下标直接调 runNewChat()」那种旁路，
/// 否则白名单就被绕过去了，SelfTest 也守不住。
private struct SlashPalette: View {
    let items: [SlashCommandItem]
    let selection: Int
    let onHover: (Int) -> Void
    let onPick: (SlashCommandItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
                row(item, active: idx == selection)
                    .contentShape(Rectangle())
                    .onHover { if $0 { onHover(idx) } }
                    .onTapGesture { onPick(item) }
                if idx < items.count - 1 {
                    Divider().opacity(0.5).padding(.horizontal, 14)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // 当前斜杠命令固定只有 4 条，不需要滚动。去掉 ScrollView 可彻底避免 macOS
        // NSScrollView 的白色 clipView 背景 / 滚动条轨道在圆角框内残留大白边。
        // 面板本身不填色，透明；底色由调用方（composer 里的 HStack）提供，
        // 这样框内与框外 guaranteed 同色，只留圆角描边作为“框”。
        .frame(maxWidth: .infinity, maxHeight: 104)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.divider.opacity(0.7), lineWidth: 0.5))
    }

    /// 单行命令项：图标 + token + 紧跟其后的描述，描述过长尾部省略。
    private func row(_ item: SlashCommandItem, active: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: item.icon)
                .font(.system(size: 12))
                .foregroundStyle(Theme.accent)
                .frame(width: 16)
            Text(item.token)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.accent)
            Text(item.detail)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(active ? Theme.accentSubtle : Color.clear)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - 对话气泡
//
// 对话模型 `AIMessage` 已迁到 `Models/ChatMessage.swift` —— 它现在被
// AppState / ChatStore / ChatPolicy 三处引用，不再是这个 View 的私有模型。

private struct MessageBubble: View {
    let message: AIMessage
    let onGo: () -> Void
    /// 初始是否展开：用户问题一律折叠；AI 回复仅在「被 reset 上下文」之前才折叠。
    let initialExpanded: Bool
    /// 是否允许折叠／展开：用户长问题、以及被 reset 前的 AI 长回复均可折叠。
    let collapsible: Bool
    @State private var isExpanded: Bool

    init(message: AIMessage, initialExpanded: Bool, collapsible: Bool, onGo: @escaping () -> Void) {
        self.message = message
        self.initialExpanded = initialExpanded
        self.collapsible = collapsible
        self.onGo = onGo
        _isExpanded = State(initialValue: initialExpanded)
    }

    /// 用户气泡折叠：超过这个行数就折叠，底部显示「展开」。
    /// fileprivate：让同文件的 AskAIView 在默认的折叠策略里复用这个阈值。
    fileprivate static let collapsedLines = 8
    private static let lineHeight: CGFloat = 17
    /// 用户气泡展开后的最大高度；超出则内部滚动，避免单个气泡无限撑高。
    private static let expandedMaxHeight: CGFloat = 240

    /// 是否足够长，需要折叠。由调用方（chatLog）按角色与 reset 情况算好传入。
    private var isCollapsible: Bool { collapsible }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if message.role == .me { Spacer(minLength: 40) }
            if message.role == .ai { avatar(ai: true) }

            VStack(alignment: message.role == .me ? .trailing : .leading, spacing: 4) {
                // 发送者标签（时间移到气泡底部）
                senderLabel

                if !message.steps.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(message.steps) { step in
                            StepRow(step: step)
                        }
                    }
                }

                // 气泡：正文 + 底部工具栏（展开/收起、时间、复制）
                VStack(alignment: .leading, spacing: 6) {
                    messageText
                    bubbleBottomBar
                }
                .padding(10)
                .background(bubbleBg, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.divider, lineWidth: 1))
                .contextMenu {
                    Button {
                        copyMessage(message.text)
                    } label: {
                        Text(L10n.t("复制", "Copy"))
                        Image(systemName: "doc.on.doc")
                    }
                }

                if message.awaitingApproval {
                    Label(L10n.t("这是计划，还没有执行任何删除", "This is a plan — nothing has been deleted"),
                          systemImage: "hand.raised.fill")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Theme.riskUserDataText)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Theme.riskUserDataBg, in: Capsule())
                        .overlay(Capsule().stroke(Theme.riskUserDataBorder, lineWidth: 1))
                }

                if let tab = message.redirect {
                    Button { onGo() } label: {
                        Label(L10n.t("前往 \(tab.displayName)", "Go to \(tab.displayName)"),
                              systemImage: "arrow.forward")
                            .font(.system(size: 11.5, weight: .medium))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(Theme.accent)
                }
            }

            if message.role == .me { avatar(ai: false) }
            if message.role == .ai { Spacer(minLength: 40) }
        }
    }

    private var senderLabel: some View {
        Text(message.role == .ai ? L10n.t("AI", "AI") : L10n.t("我", "Me"))
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.primary)
    }

    /// 气泡底部工具栏：展开/收起（左）、时间 + 复制（右）。
    private var bubbleBottomBar: some View {
        HStack(spacing: 8) {
            if isCollapsible {
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { isExpanded.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Text(isExpanded
                             ? L10n.t("收起", "Collapse")
                             : L10n.t("显示更多", "Show more"))
                            .font(.system(size: 11.5, weight: .medium))
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(isExpanded
                      ? L10n.t("收起", "Collapse")
                      : L10n.t("展开", "Expand"))
            }

            Spacer(minLength: 0)

            Text(smartTimeString(message.createdAt))
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)

            Button {
                copyMessage(message.text)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(L10n.t("复制", "Copy"))
        }
    }

    /// 气泡正文：AI 完整展示；用户长文本折叠 / 展开后滚动。
    private var messageText: some View {
        Group {
            if isCollapsible {
                if isExpanded {
                    ScrollView {
                        markdownText(message.text, isMine: message.role == .me)
                            .font(.system(size: 12.5))
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: Self.expandedMaxHeight)
                } else {
                    markdownText(message.text, isMine: message.role == .me)
                        .font(.system(size: 12.5))
                        .textSelection(.enabled)
                        // MarkdownUI 的 Markdown 视图不吃 .lineLimit，
                        // 必须用定高 + 裁剪来实现折叠，否则折叠态仍渲染全文，
                        // 看起来就像「展开/收起」失灵、默认折叠没生效。
                        .frame(maxHeight: CGFloat(Self.collapsedLines) * Self.lineHeight, alignment: .top)
                        .clipped()
                }
            } else {
                markdownText(message.text, isMine: message.role == .me)
                    .font(.system(size: 12.5))
                    .textSelection(.enabled)
            }
        }
    }

    private func copyMessage(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private var bubbleBg: some ShapeStyle {
        message.role == .me
            ? LinearGradient(colors: [Theme.accent, Theme.accentActive],
                            startPoint: .topLeading, endPoint: .bottomTrailing)
            : LinearGradient(colors: [Theme.bgSurface, Theme.bgSurface],
                            startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    private func avatar(ai: Bool) -> some View {
        Circle()
            .fill(ai
                  ? LinearGradient(colors: [Theme.aiPrimary, Theme.aiDeep],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                  : LinearGradient(colors: [Theme.accent, Theme.accentActive],
                                   startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: 26, height: 26)
            .overlay(Image(systemName: ai ? "sparkles" : "person.fill")
                .font(.system(size: 11, weight: .bold)).foregroundStyle(.white))
    }

    /// 用 MarkdownUI 渲染对话文本，支持 GitHub 风格 Markdown（加粗、斜体、
    /// 链接、行内代码、列表、引用、代码块、表格）。用户气泡背景为蓝色渐变，
    /// 需把文字颜色统一为白色；AI 气泡用默认深色文字。
    private func markdownText(_ raw: String, isMine: Bool) -> some View {
        Markdown(raw)
            .markdownTextStyle {
                ForegroundColor(isMine ? .white : .primary)
            }
    }

    /// 智能时间：今天只显示 HH:mm；昨天显示「昨天 HH:mm」；
    /// 今年内其他天显示「M月d日 HH:mm」；更早显示「yyyy.M.d HH:mm」。
    private func smartTimeString(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return format(d, "HH:mm") }
        if cal.isDateInYesterday(d) { return L10n.t("昨天", "Yesterday") + " " + format(d, "HH:mm") }
        if cal.isDate(d, equalTo: Date(), toGranularity: .year) {
            return format(d, "M月d日 HH:mm")
        }
        return format(d, "yyyy.M.d HH:mm")
    }

    private func format(_ d: Date, _ format: String) -> String {
        let f = DateFormatter()
        f.dateFormat = format
        f.locale = Locale(identifier: "zh_CN")
        return f.string(from: d)
    }
}

/// 一步执行记录：命令 + 结果。Agent 做了什么必须原样摆出来。
private struct StepRow: View {
    let step: AgentStep

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Image(systemName: step.ok ? "terminal" : "exclamationmark.triangle.fill")
                    .font(.system(size: 9))
                Text(step.command)
                    .font(.system(size: 10, design: .monospaced))
                if step.risk == .destructive {
                    Text(L10n.t("预演", "preview"))
                        .font(.system(size: 8.5, weight: .semibold))
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Theme.riskUserDataBg, in: RoundedRectangle(cornerRadius: 3))
                        .foregroundStyle(Theme.riskUserDataText)
                }
            }
            .foregroundStyle(step.ok ? Theme.aiText : Theme.riskUncertainText)

            Text(step.summary)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 9).padding(.vertical, 6)
        .frame(maxWidth: 460, alignment: .leading)
        .background(step.ok ? Theme.aiBg : Theme.riskUncertainBg, in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7)
            .stroke(step.ok ? Theme.aiBorder : Theme.riskUncertainBorder, lineWidth: 1))
    }
}

/// 思考中：把已经跑完的步骤和正在跑的命令都摆出来，不让用户对着转圈猜。
private struct ThinkingBubble: View {
    let steps: [AgentStep]
    let running: String?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            avatar
            VStack(alignment: .leading, spacing: 4) {
                ForEach(steps) { StepRow(step: $0) }
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    if let running {
                        Text(running)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(Theme.aiText)
                    } else {
                        Text(L10n.t("Agent 思考中…", "The agent is thinking…"))
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                .padding(10)
                .background(Theme.bgSurface, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.divider, lineWidth: 1))
            }
            Spacer(minLength: 40)
        }
    }

    private var avatar: some View {
        Circle()
            .fill(LinearGradient(colors: [Theme.aiPrimary, Theme.aiDeep],
                                startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: 26, height: 26)
            .overlay(Image(systemName: "sparkles")
                .font(.system(size: 11, weight: .bold)).foregroundStyle(.white))
    }
}

// MARK: - skill 清单

/// 把 Agent 的能力边界摊开给用户看 —— 「它能干什么」不该是黑箱。
private struct SkillCatalogSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.t("Agent 能调用的 skill", "Skills the agent can call"))
                        .font(.system(size: 15, weight: .semibold))
                    Text(L10n.t("共 \(SkillRegistry.all.count) 个。清单之外的任何指令都会被拒绝执行。",
                                "\(SkillRegistry.all.count) in total. Anything outside this list is refused."))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Button(L10n.t("完成", "Done")) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(SkillRegistry.specs, id: \.name) { spec in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Text(spec.name)
                                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                riskTag(spec.risk)
                                Spacer()
                                Text("expunge \(spec.cli)")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                            }
                            Text(spec.summary)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            ForEach(spec.args, id: \.name) { arg in
                                Text("· \(arg.name)\(arg.required ? "*" : "") — \(arg.desc)")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.tertiary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.bgSurface, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.divider, lineWidth: 1))
                    }
                }
                .padding(16)
            }
            .background(Theme.bgCanvas)
        }
        .frame(width: 620, height: 520)
    }

    private func riskTag(_ risk: SkillRisk) -> some View {
        let (bg, fg, border): (Color, Color, Color) = {
            switch risk {
            case .readOnly:    return (Theme.riskSafeBg, Theme.riskSafeText, Theme.riskSafeBorder)
            case .mutating:    return (Theme.aiBg, Theme.aiText, Theme.aiBorder)
            case .destructive: return (Theme.riskUserDataBg, Theme.riskUserDataText, Theme.riskUserDataBorder)
            }
        }()
        return Text(risk.label)
            .font(.system(size: 9, weight: .medium))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(bg, in: Capsule())
            .overlay(Capsule().stroke(border, lineWidth: 1))
            .foregroundStyle(fg)
    }
}

/// 斜杠命令面板的上下键拦截器。
///
/// 为什么不用 NSTextView 的 `keyDown`：
/// 在 SwiftUI 的 `NSViewRepresentable` 集成里，方向键事件常常在到达我们的 textView
/// 之前就被系统先一步派发，导致「上下键一个都不动」。这里改成在 App 级（`NSEvent`
/// 本地 monitor）拦截 —— 它在事件派发给 window 之前就拿到，且不受 first responder
/// 是谁的影响。面板显示时吞掉上下键并广播方向，面板隐藏时放行，光标才能正常移动。
private final class SlashKeyInterceptor {
    static let shared = SlashKeyInterceptor()
    private var monitor: Any?
    private var active = false

    /// 面板出现/消失时切换。重复调用为 true 不会重复注册 monitor。
    func setActive(_ on: Bool) {
        active = on
        if on { install() }
    }

    private func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.active else { return event }
            switch event.keyCode {
            case 126: // 上箭头
                NotificationCenter.default.post(name: .slashPaletteMove, object: -1)
                return nil
            case 125: // 下箭头
                NotificationCenter.default.post(name: .slashPaletteMove, object: 1)
                return nil
            default:
                return event
            }
        }
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }
}

private extension Notification.Name {
    static let slashPaletteMove = Notification.Name("expunge.slashPaletteMove")
}
