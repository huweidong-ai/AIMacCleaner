import SwiftUI
import AppKit

/// 应用外壳：品牌区 + 四项导航 + 磁盘卡片 + 底部工具入口，右侧按 tab 路由。
///
/// 页面内容一律不写在这里 —— 每个 tab 一个独立 View 文件。
/// 这个文件只负责「壳」，改页面时不用碰它。
struct MainView: View {
    @EnvironmentObject var state: AppState
    @State private var showHistory = false
    @State private var showFeedback = false
    @State private var showMacTools = false
    /// 用户主动收起 sidebar（工具栏按钮 / 把分隔线拖到最左）。
    @State private var userCollapsed = false
    /// 临时展开（flyout）：窗口很窄、sidebar 被自动收起后，点工具栏按钮滑出，
    /// 点击空白处收回。Xcode/Safari 同款交互。
    @State private var transientVisible = false
    /// sidebar 实际宽度。不用 HSplitView —— 它在 macOS 上由底层 NSSplitView 管理，
    /// 窗口缩小时会把 sidebar 压得比 SwiftUI minWidth 还窄、内容向左溢出被边框遮挡。
    /// 这里自己管宽度：拖拽把手 clamp 在 100...280，物理上不可能被压扁。
    @State private var sidebarWidth: CGFloat = 235
    @State private var widthAtDragStart: CGFloat = 235
    /// 实时窗口宽度（由 GeometryReader + PreferenceKey 提供）。
    @State private var windowWidth: CGFloat = 1200
    // 直接订阅语言键 —— AppState 也会推 objectWillChange，但本视图里的 DiskCard
    // 嵌套较深、SwiftUI 不一定传透。这里双保险：自己再观察一次，切换时强制重建。
    @AppStorage("expunge.language") private var languageRaw: String = L10n.Language.system.rawValue

    /// 常驻模式下 sidebar + detail 的最小总宽度 = sidebar 当前宽 + detail 最低宽度(360) + 分隔线(~1) + 余量。
    /// 窗口宽度 < 这个值 → 自动收起（flyout），避免 sidebar/detail 互相挤爆导致左右遮挡。
    /// 这个值同时用作「常驻时」窗口的最小宽度，二者保持一致，杜绝中间的溢出死区。
    private var dockedMinWidth: CGFloat {
        sidebarWidth + 360 + 8
    }

    /// 窗口太窄、放不下 sidebar + detail 时自动收起。实时计算而非 @State：
    /// 窗口 resize 触发 body 重算，无需额外监听。
    private var autoCollapsed: Bool {
        windowWidth < dockedMinWidth
    }

    /// sidebar 是否应该显示：临时展开中，或（用户没主动收 ∧ 窗口够宽）。
    private var sidebarVisible: Bool {
        transientVisible || (!userCollapsed && !autoCollapsed)
    }

    /// 常驻展开模式（sidebar 挤压 detail）——只有用户没收、窗口够宽且不在临时展开时。
    private var isDocked: Bool {
        sidebarVisible && !transientVisible && !autoCollapsed
    }

    var body: some View {
        ZStack {
            if isDocked {
                // 常驻模式：sidebar 与 detail 并排，中间分隔线。
                HStack(spacing: 0) {
                    sidebarWithHandle
                    Divider()
                    detail
                        // 常驻模式允许 detail 下探到 360：窗口很窄（但仍 >= dockedMinWidth）
                        // 时页面自适应压缩，不再出现「sidebar+detail 超出窗口」的左右遮挡。
                        .frame(minWidth: 360, maxWidth:  .infinity, maxHeight: .infinity)
                }
            } else {
                // 收起 / 临时展开（flyout）：detail 占满全宽。
                ZStack(alignment: .leading) {
                    detail
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if transientVisible {
                        // 点击空白处收回 flyout。放在 sidebar 下层，点 sidebar 不触发。
                        Color.black.opacity(0.05)
                            .onTapGesture { transientVisible = false }
                        sidebarWithHandle
                            .shadow(color: .black.opacity(0.18), radius: 10, x: 3, y: 0)
                            .zIndex(1)
                    }
                }
            }
        }
        // 窗口最小宽度随状态变化：
        // - 常驻（sidebar 展开并排）：必须 >= dockedMinWidth，窗口物理上装得下，杜绝左右遮挡。
        // - 折叠 / 临时展开：detail 占满，只需 detail 最低 700。
        .frame(minWidth: isDocked ? dockedMinWidth : 700, minHeight: 560)
        // 在布局之外挂一个零成本 GeometryReader 捕获窗口宽度。
        .background(
            GeometryReader { geo in
                Color.clear.preference(
                    key: WindowWidthPreferenceKey.self,
                    value: geo.size.width
                )
            }
        )
        .onPreferenceChange(WindowWidthPreferenceKey.self) { width in
            if abs(width - windowWidth) > 0.5 {
                windowWidth = width
            }
        }
        // 启动时保证 sidebar 默认展开：macOS 会记住上次的窗口尺寸，如果上次把窗口
        // 缩到装不下常驻 sidebar，一打开 sidebar 就是折叠态。这里在启动瞬间把窗口
        // 拉宽到 comfortably 默认宽度（保持原位置、只改宽），恢复「默认展开」。
        // 用一个短延迟，确保窗口已就位、躲过系统对记住尺寸的还原，避免被覆盖。
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                let candidates = [NSApp.mainWindow, NSApp.keyWindow] + NSApp.windows
                guard let window = candidates.compactMap({ $0 }).first(where: { $0.isVisible }) else { return }
                let targetWidth = max(dockedMinWidth, 1040)
                let maxW = (window.screen?.visibleFrame.width ?? 1280) - 40
                if window.frame.width < targetWidth {
                    var frame = window.frame
                    frame.size.width = min(targetWidth, maxW)
                    frame.size.height = max(frame.size.height, 600)
                    window.setFrame(frame, display: true)
                }
            }
        }
        .toolbar {
            // 按钮放在标题左侧，标题自然“移到后面”。
            ToolbarItem(placement: .navigation) {
                Button {
                    if transientVisible {
                        // 正在临时展开 → 收回
                        transientVisible = false
                    } else if sidebarVisible {
                        // 常驻展开中 → 收起
                        userCollapsed = true
                    } else {
                        // 已收起（手动或窗口太窄自动）→ 临时滑出
                        transientVisible = true
                    }
                } label: {
                    Image(systemName: "sidebar.left")
                }
                .help(L10n.t("显示/隐藏边栏", "Show/hide sidebar"))
            }
        }
        .sheet(isPresented: $showHistory) {
            HistorySheet()
        }
        .sheet(isPresented: $showFeedback) {
            FeedbackHistorySheet()
        }
        .sheet(isPresented: $showMacTools) {
            MacToolkitSheet()
        }
        .sheet(isPresented: $state.showAbout) {
            AboutSheet()
        }
        .sheet(isPresented: $state.showAIModelSettings) {
            AIModelSettingsSheet()
        }
        .sheet(isPresented: $state.showFDAGuidance) {
            FDAGuidanceSheet()
        }
    }

    // MARK: - 侧栏

    /// sidebar + 右侧拖拽把手。常驻与 flyout 两种模式共用。
    private var sidebarWithHandle: some View {
        sidebar
            .frame(width: sidebarWidth)
            .overlay(alignment: .trailing) {
                // 拖拽把手：6px 透明命中区，向右拖加宽、向左拖收窄；
                // 拖到最左（< 160）等同点了 sidebar 按钮 —— 收回。
                Rectangle()
                    .fill(Color.clear)
                    .frame(width: 6)
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        if hovering {
                            NSCursor.resizeLeftRight.push()
                        } else {
                            NSCursor.pop()
                        }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { value in
                                if value.translation.width == 0 {
                                    widthAtDragStart = sidebarWidth
                                }
                                sidebarWidth = min(max(100, widthAtDragStart + value.translation.width), 280)
                            }
                            .onEnded { _ in
                                // 拖到最左 = 收回
                                if sidebarWidth < 160 {
                                    sidebarWidth = 235
                                    if transientVisible {
                                        transientVisible = false
                                    } else {
                                        userCollapsed = true
                                    }
                                }
                            }
                    )
            }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            brand
            nav
            Spacer(minLength: 8)
            DiskCard(reclaimable: reclaimableBytes)
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            footLinks
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.bgSidebar)
    }

    private var brand: some View {
        HStack(spacing: 8) {
            // 36 在窄 sidebar 里偏胖；30 与导航图标同尺度，视觉密度更稳。
            AppIconView(size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text("AI Mac Cleaner")
                    .font(.system(size: 13.5, weight: .semibold))
                Text("v\(AIMacCleanerApp.version)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    private var nav: some View {
        VStack(spacing: 2) {
            ForEach(AppState.Tab.allCases) { tab in
                NavItem(tab: tab,
                        icon: icon(for: tab),
                        badge: badge(for: tab),
                        isActive: state.selectedTab == tab) {
                    state.selectedTab = tab
                }
            }
        }
        .padding(.horizontal, 12)
    }

    private var footLinks: some View {
        VStack(alignment: .leading, spacing: 1) {
            Divider()
                .padding(.bottom, 5)
            SideLink(icon: "clock.arrow.circlepath",
                     title: L10n.t("卸载历史", "History")) { showHistory = true }
            SideLink(icon: "flag",
                     title: L10n.t("反馈记录", "Feedback")) { showFeedback = true }
            SideLink(icon: "keyboard",
                     title: L10n.t("macOS 工具", "macOS Tools")) { showMacTools = true }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    private func icon(for tab: AppState.Tab) -> String {
        switch tab {
        case .askAI:     return "sparkles"
        case .apps:      return "square.grid.2x2"
        case .leftovers: return "wand.and.rays"
        case .processes: return "waveform.path.ecg"
        }
    }

    /// 导航项右侧的计数徽章。没有数字就不显示 —— 空徽章只是噪声。
    private func badge(for tab: AppState.Tab) -> Int? {
        switch tab {
        case .askAI:     return nil
        case .apps:      return state.allApps.isEmpty ? nil : state.allApps.count
        case .leftovers: return state.leftoverGroups.isEmpty ? nil : state.leftoverGroups.count
        case .processes: return state.processes.isEmpty ? nil : state.visibleProcesses.count
        }
    }

    /// 侧栏磁盘卡片里的「本次可回收」：当前页面已勾选的量。
    private var reclaimableBytes: Int64 {
        switch state.selectedTab {
        case .apps:      return state.totalSelectedSize
        case .leftovers: return state.leftoverSelectedSize
        default:         return state.totalSelectedSize + state.leftoverSelectedSize
        }
    }

    // MARK: - 路由

    @ViewBuilder
    private var detail: some View {
        switch state.selectedTab {
        case .askAI:     AskAIView()
        case .apps:      AppsView()
        case .leftovers: LeftoversView()
        case .processes: ProcessesView()
        }
    }
}

// MARK: - 侧栏零件

private struct NavItem: View {
    let tab: AppState.Tab
    let icon: String
    let badge: Int?
    let isActive: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 16)
                Text(tab.displayName)
                    .font(.system(size: 13.5, weight: isActive ? .semibold : .regular))
                Spacer(minLength: 4)
                if let badge {
                    Text("\(badge)")
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(isActive ? Theme.accent.opacity(0.16) : Color.secondary.opacity(0.12),
                                    in: Capsule())
                }
            }
            .foregroundStyle(isActive ? Theme.accent : Color.primary.opacity(0.78))
            .padding(.horizontal, 9)
            .frame(height: 32)
            .background(background)
            .overlay(alignment: .leading) {
                // 选中态左侧的一小段竖条：比整块底色更轻，也更好定位。
                if isActive {
                    Capsule()
                        .fill(Theme.accent)
                        .frame(width: 2.5, height: 17)
                        .offset(x: -4)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    @ViewBuilder
    private var background: some View {
        if isActive {
            RoundedRectangle(cornerRadius: 6).fill(Theme.accentSubtle)
        } else if hovering {
            RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.045))
        }
    }
}

private struct SideLink: View {
    let icon: String
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .frame(width: 14)
                Text(title)
                    .font(.system(size: 12.5))
                Spacer(minLength: 0)
            }
            .foregroundStyle(hovering ? Theme.accent : Color.secondary)
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(hovering ? Theme.accentSubtle : .clear, in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// 启动磁盘用量卡片。存在的意义：让「删掉这些能腾出多少」有个参照系 ——
/// 单看「1.4 GB」没有概念，看到「还剩 28 GB」就有了。
struct DiskCard: View {
    let reclaimable: Int64

    private var capacity: (free: Int64, total: Int64)? {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        guard let v = try? url.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey
        ]) else { return nil }
        guard let free = v.volumeAvailableCapacityForImportantUsage,
              let total = v.volumeTotalCapacity else { return nil }
        return (Int64(free), Int64(total))
    }

    var body: some View {
        if let cap = capacity, cap.total > 0 {
            let usedRatio = 1.0 - Double(cap.free) / Double(cap.total)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(L10n.t("启动磁盘", "Startup disk"))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                    Spacer(minLength: 4)
                    Text(L10n.t("\(SizeFormat.human(cap.free)) 可用", "\(SizeFormat.human(cap.free)) free"))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.secondary.opacity(0.18))
                        Capsule()
                            .fill(usedRatio > 0.9 ? Theme.riskUserData : Theme.accent)
                            .frame(width: max(2, geo.size.width * usedRatio))
                    }
                }
                .frame(height: 5)
                if reclaimable > 0 {
                    Text(.init(L10n.t("本次可回收 **\(SizeFormat.human(reclaimable))**",
                                      "**\(SizeFormat.human(reclaimable))** reclaimable")))
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.accent)
                }
            }
            .padding(9)
            .background(Theme.bgSurface, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.divider, lineWidth: 1))
        }
    }
}

// MARK: - 卸载历史（从侧栏底部进入的 sheet）

/// 历史不再占一个 tab —— 它是低频的回顾入口，不该和三个高频操作页平级。
/// 包一层 sheet 外壳，内容仍复用 `HistoryView`。
struct HistorySheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(L10n.t("卸载历史", "Uninstall history"), systemImage: "clock.arrow.circlepath")
                    .font(.system(size: 14, weight: .semibold))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            Divider()
            HistoryView()
            Divider()
            SheetActionBar {
                EmptyView()
            } trailing: {
                SheetCloseButton(title: L10n.t("关闭", "Close")) { dismiss() }
            }
        }
        .frame(width: SheetPreset.historyList.width, height: SheetPreset.historyList.height)
        .blanketDismiss { dismiss() }
        .presentationBackground(Theme.bgSurface)
        .frame(width: SheetPreset.historyListOuter.width, height: SheetPreset.historyListOuter.height)
    }
}

// MARK: - 窗口宽度监听

/// 把窗口宽度沿 SwiftUI 视图树向上传递的 PreferenceKey。
/// MainView 用它在窗口缩窄时自动收起 sidebar（`autoCollapsed`）。
private struct WindowWidthPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
