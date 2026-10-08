import SwiftUI

// 应用页 / 残留页共用的展示组件。抽在一处的理由：这两页的信息结构
// 是同构的（提示条 → AI 分析条 → 分区标题 → 分组卡片 → 底部操作条），
// 各写一遍必然慢慢走形，改一处忘一处。

// MARK: - 提示横幅

/// 页面顶部的说明条。`warn` 用于「这是启发式推断」这类需要人类判断的场合，
/// `info` 用于中性说明。
struct Banner: View {
    enum Kind { case warn, info }

    let kind: Kind
    let title: String
    let message: String

    private var icon: String {
        kind == .warn ? "exclamationmark.triangle.fill" : "info.circle.fill"
    }
    private var tint: Color { kind == .warn ? Theme.riskUserData : Theme.accent }
    private var bg: Color { kind == .warn ? Theme.riskUserDataBg : Theme.accentSubtle }
    private var border: Color { kind == .warn ? Theme.riskUserDataBorder : Theme.accentBorder }
    private var fg: Color { kind == .warn ? Theme.riskUserDataText : Theme.accentActive }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(tint)
                .padding(.top, 1)
            // 标题加粗、正文接在同一段里，和原型的 `<b>…</b>正文` 排版一致。
            Text(.init("**\(title)** \(message)"))
                .font(.system(size: 12))
                .foregroundStyle(fg)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(bg, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(border, lineWidth: 1))
    }
}

// MARK: - AI 分析条

/// 「一键让 AI 分析这些能不能删」入口条。三态：待分析 / 分析中 / 已分析。
///
/// 应用页和残留页方向相反但共用这一个组件：
/// 应用页默认全选，AI 帮你**取消**不该删的；
/// 残留页默认全不选，AI 帮你**勾上**可以放心删的。
/// 文案由调用方给，组件只管状态机和视觉。
struct AIReviewBar: View {
    let phase: AIReviewPhase
    let title: String
    let detail: String
    let actionTitle: String
    let onReview: () -> Void
    let onViewConclusion: () -> Void
    /// 未配置模型时点这个去设置（needsConfig 阶段才用到）。
    var onConfigure: (() -> Void)? = nil
    /// 主按钮置灰（如未勾选任何项）。仅 idle/failed 阶段生效。
    var disabled: Bool = false

    private var isDone: Bool { phase == .done }

    var body: some View {
        HStack(spacing: 10) {
            icon
            Text(.init("**\(title)** \(detail)"))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            switch phase {
            case .idle:
                Button(action: onReview) {
                    Label(actionTitle, systemImage: "sparkles")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(AIButtonStyle())
                .disabled(disabled)
                .opacity(disabled ? 0.5 : 1.0)
            case .running:
                // 分析进行中也要能「去看过程」：点进去是「问 AI」里正在跑的那个气泡
                //（深度思考逐字出、工具一条条上屏），而不是在这儿干等转圈。
                Button(L10n.t("去看分析过程", "View progress")) { onViewConclusion() }
                    .controlSize(.small)
            case .done:
                Button(L10n.t("去看 AI 怎么说", "View AI conclusion")) { onViewConclusion() }
                    .controlSize(.small)
            case .needsConfig:
                if let onConfigure {
                    Button(action: onConfigure) {
                        Label(L10n.t("去配置模型", "Configure model"), systemImage: "gearshape")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(AIButtonStyle())
                }
            case .failed:
                Button(action: onReview) {
                    Label(L10n.t("重试", "Retry"), systemImage: "arrow.clockwise")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(AIButtonStyle())
                .disabled(disabled)
                .opacity(disabled ? 0.5 : 1.0)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(isDone ? Theme.aiDoneBg : Theme.aiBarBg, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .stroke(isDone ? Theme.aiDoneBorder : Theme.aiBarBorder, lineWidth: 1))
    }

    @ViewBuilder
    private var icon: some View {
        if phase == .running {
            ProgressView()
                .controlSize(.small)
                .frame(width: 26, height: 26)
        } else {
            RoundedRectangle(cornerRadius: 8)
                .fill(LinearGradient(
                    colors: isDone ? [Theme.success, Theme.success.opacity(0.82)]
                                   : [Theme.aiPrimary, Theme.aiDeep],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 26, height: 26)
                .overlay(
                    Image(systemName: isDone ? "checkmark" : "sparkles")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                )
        }
    }
}

/// AI 专用按钮样式：紫色渐变，和普通 accent 按钮区分开。
struct AIButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                LinearGradient(colors: [Theme.aiPrimary, Theme.aiDeep],
                               startPoint: .topLeading, endPoint: .bottomTrailing),
                in: RoundedRectangle(cornerRadius: 6)
            )
            .brightness(configuration.isPressed ? -0.06 : 0)
    }
}

/// AI 判定理由的注释行，挂在被判定的条目下方。
struct AINoteRow: View {
    let reason: String
    let isKeep: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: isKeep ? "hand.raised.fill" : "checkmark.seal.fill")
                .font(.system(size: 10))
                .foregroundStyle(isKeep ? Theme.aiPrimary : Theme.success)
                .padding(.top, 2)
            Text(reason)
                .font(.system(size: 11.5))
                .foregroundStyle(isKeep ? Theme.aiText : Theme.success)
                .fixedSize(horizontal: false, vertical: true)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(reason)
        }
    }
}

// MARK: - 分区标题（右侧带 展开 / 折叠）

struct SectionLabel: View {
    let text: String
    var onExpand: (() -> Void)?
    var onCollapse: (() -> Void)?

    var body: some View {
        HStack(spacing: 4) {
            Text(text.uppercased())
                .font(.system(size: 10.5, weight: .bold))
                .kerning(0.6)
                .foregroundStyle(.tertiary)
            Spacer()
            if let expand = onExpand, let collapse = onCollapse {
                Button(L10n.t("展开", "Expand")) { expand() }
                    .buttonStyle(.plain)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                Text("/")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.quaternary)
                Button(L10n.t("折叠", "Collapse")) { collapse() }
                    .buttonStyle(.plain)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Theme.accent)
            }
        }
    }
}

// MARK: - 底部操作条

/// 贴在页面底部的操作条：全选复选框 + 统计 + 主操作按钮。
///
/// 做成常驻而不是浮现：列表滚到哪都能看到「选了几项、占多大」，
/// 不用滚回顶部找按钮。
struct BottomActionBar<Trailing: View>: View {
    let selectedCount: Int
    let totalCount: Int
    let selectedSize: Int64
    /// 全选框右边的一句灰字说明（如「默认全选，含用户数据」）。
    let hint: String?
    let onToggleAll: (Bool) -> Void
    @ViewBuilder let trailing: () -> Trailing

    private var allSelected: Bool { totalCount > 0 && selectedCount == totalCount }

    var body: some View {
        HStack(spacing: 12) {
            Toggle(isOn: Binding(
                get: { allSelected },
                set: { onToggleAll($0) }
            )) {
                Text(L10n.t("全选", "Select all"))
                    .font(.system(size: 12.5))
            }
            .toggleStyle(.checkbox)
            .disabled(totalCount == 0)

            Text(.init(L10n.t("**\(selectedCount)** / \(totalCount) 项已选 · \(SizeFormat.human(selectedSize))",
                              "**\(selectedCount)** / \(totalCount) selected · \(SizeFormat.human(selectedSize))")))
                .font(.system(size: 12.5).monospacedDigit())
                .foregroundStyle(.secondary)

            if let hint {
                Text(hint)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, 20)
        .frame(height: 54)
        .background(.regularMaterial)
        .overlay(alignment: .top) { Divider() }
    }
}

// MARK: - 痕迹分组卡片

/// 一组痕迹（按类别 / 按归属者）的可折叠卡片。应用页和残留页共用。
struct ArtifactGroupCard: View {
    let title: String
    /// 标题后面的额外徽章（残留页放来源 pill，应用页不放）。
    let badge: TagPill?
    let entries: [Artifact]
    let expanded: Bool
    let onToggleGroup: (Bool) -> Void
    let onToggleItem: (UUID, Bool) -> Void
    /// 折叠切换回调（折叠态由调用方持有，便于跨视图同步）。
    let onToggleExpanded: () -> Void
    /// 被 PWA「卸载单元」锁定的项 id 集合（配置 plist）。这些项勾选框禁用、
    /// 跟随应用本体，由 `state.pwaAppToCompanion` 直接算出（@Published 赋值必刷新）。
    let lockedIds: Set<UUID>

    private var totalSize: Int64 { entries.reduce(0) { $0 + $1.size } }
    private var selectedCount: Int { entries.filter(\.selected).count }
    private var allSelected: Bool { !entries.isEmpty && selectedCount == entries.count }

    /// 本组条目的来源扫描器。唯一才显示名字，混合则显示「多个来源」。
    ///
    /// 为什么不逐行标：卸载页的分组与扫描器基本一一对应
    /// （AppBundleScanner → App bundle、LibraryDataScanner → Library 用户数据 ……），
    /// 逐行重复同一个名字只是噪音；在组头写一次，用户一眼就知道「这批是谁扫的」。
    /// 显示用的人话名（`应用包` 而不是 `AppBundleScanner`），以及悬浮里的一句话说明。
    private var groupSource: (name: String, detail: String)? {
        let sources = Set(entries.compactMap(\.source))
        guard sources.count == 1, let only = sources.first else {
            return sources.count > 1
                ? (L10n.t("多个来源", "multiple sources"), "")
                : nil
        }
        return ScannerCatalog.sourceLabel(for: only)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if expanded {
                Divider()
                VStack(spacing: 0) {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { idx, artifact in
                        if idx > 0 { Divider().padding(.leading, 34) }
                        ArtifactRow(artifact: artifact, isLocked: lockedIds.contains(artifact.id), onToggle: { onToggleItem(artifact.id, $0) })
                    }
                }
            }
        }
        .background(Theme.bgSurface, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.divider, lineWidth: 1))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: expanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.tertiary)
                .frame(width: 12)

            Toggle("", isOn: Binding(get: { allSelected }, set: { onToggleGroup($0) }))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .help(L10n.t("全选 / 取消全选本组", "Select / deselect all in this group"))

            Text(title)
                .font(.system(size: 12.5, weight: .semibold))
                .lineLimit(1)

            if let badge { badge }

            Text(L10n.t("\(entries.count) 项", "\(entries.count) items"))
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)

            if let groupSource {
                Text(groupSource.name)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(groupSource.detail.isEmpty
                          ? L10n.t("本组来自 \(groupSource.name)", "Found by \(groupSource.name)")
                          : L10n.t("本组来自 \(groupSource.name)：\(groupSource.detail)",
                                   "Found by \(groupSource.name): \(groupSource.detail)"))
            }

            Spacer(minLength: 8)

            Text(SizeFormat.human(totalSize))
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .contentShape(Rectangle())
        // 整行可点折叠，但复选框要吃掉自己的点击，否则勾选会连带折叠。
        .onTapGesture { onToggleExpanded() }
    }
}

/// 单条痕迹。AI 给过结论的行会染色 + 在下方补一行理由。
struct ArtifactRow: View {
    let artifact: Artifact
    /// PWA 跟随配置：勾选框禁用，永远跟随应用本体。由 `state.pwaAppToCompanion`
    /// 直接算出并传入（@Published 赋值必触发刷新），不依赖数组元素下标修改。
    let isLocked: Bool
    let onToggle: (Bool) -> Void

    private var aiKeep: Bool {
        if case .keep = artifact.aiVerdict { return true }
        return false
    }
    private var aiReason: String? {
        switch artifact.aiVerdict {
        case .keep(let r), .safe(let r): return r
        case nil: return nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                if isLocked {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .frame(width: 16, alignment: .center)
                        .help(L10n.t("随应用一起卸载，勾选跟随上面的应用本体",
                                     "Removed with the app — follows the app's checkbox"))
                } else {
                    Toggle("", isOn: Binding(get: { artifact.selected }, set: { onToggle($0) }))
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text((artifact.path as NSString).lastPathComponent)
                        .font(.system(size: 12))
                        .foregroundStyle(aiKeep ? .secondary : .primary)
                        .lineLimit(1)
                    Text(artifact.path)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        // 路径要能选中复制：右键菜单一次只能复制一条，
                        // 想把一批路径贴到别处核对时不够用。
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // 「这条是模型猜出来的」必须显式标出来：AI 项归属判断不如规则可靠，
                // 用户得先知道它是猜的，才会自己去核对。
                if artifact.isAISuggested {
                    TagPill.aiProposed
                }
                if artifact.aiVerdict != nil && !artifact.isAISuggested {
                    aiKeep ? TagPill.keep : TagPill.aiSafe
                }
                RiskPill(risk: artifact.risk)

                Text(SizeFormat.human(artifact.size))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 68, alignment: .trailing)

                Button {
                    RevealService.revealInFinder(path: artifact.path)
                } label: {
                    Image(systemName: "arrow.up.forward.square")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .help(L10n.t("在访达中显示", "Reveal in Finder"))
            }

            if let aiReason {
                AINoteRow(reason: aiReason, isKeep: aiKeep)
                    .padding(.leading, 26)
            }

            if let note = artifact.note {
                HStack(spacing: 4) {
                    Image(systemName: "link")
                        .font(.system(size: 9.5))
                    Text(note)
                }
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.accent)
                .padding(.leading, 26)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(artifact.aiVerdict != nil && aiKeep ? Theme.aiRowBg : Color.clear)
        .overlay(alignment: .leading) {
            if aiKeep {
                Rectangle().fill(Theme.aiPrimary).frame(width: 3)
            }
        }
        // contentShape 让整行都成为悬浮命中区：不加的话只有鼠标压在文字上才弹提示，
        // 行内留白 / 图标区域都点不到，等于这个功能形同没有。
        .contentShape(Rectangle())
        .help(rowHelp)
        .contextMenu {
            // 悬浮提示容易被忽略，右键菜单里再放一条文本，让「这条哪来的」可被主动查到。
            if let src = artifact.source {
                Text(L10n.t("来源：\(ScannerCatalog.sourceLabel(for: src).name)",
                           "Source: \(ScannerCatalog.sourceLabel(for: src).name)"))
            }
            Button(L10n.t("在访达中显示", "Reveal in Finder")) { RevealService.revealInFinder(path: artifact.path) }
            Button(L10n.t("复制路径", "Copy path")) { RevealService.copyPath(artifact.path) }
        }
    }

    /// 悬浮提示：回答「这条为什么会被扫出来」——是内置扫描器的规则命中的，
    /// 还是 AI 补充提议的。
    ///
    /// 只放 tooltip 不放行内文字，是因为 `LibraryDataScanner` 这类内部模块名
    /// 对用户没有决策价值，平铺在每行只会变成噪音；但「这条是不是 AI 猜的」
    /// 又确实该能查到，所以放在按需查看的位置。
    /// 没有来源时退回完整路径（行内路径是截断的，悬浮看全路径本身就有用）。
    private var rowHelp: String {
        guard let src = artifact.source else { return artifact.path }
        let (name, detail) = ScannerCatalog.sourceLabel(for: src)
        let tail = detail.isEmpty ? name : "\(name)：\(detail)"
        return L10n.t("\(artifact.path)\n\n来源：\(tail)",
                      "\(artifact.path)\n\nSource: \(tail)")
    }
}

// MARK: - 空态 / 加载态

/// 统一的空状态占位：大图标 + 标题 + 说明 + 可选主按钮。
struct EmptyStateView<Actions: View>: View {
    let icon: String
    let title: String
    let message: String
    var tint: Color = .secondary
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Theme.accentSubtle)
                    .frame(width: 68, height: 68)
                Image(systemName: icon)
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(tint)
            }
            Text(title)
                .font(.system(size: 15, weight: .semibold))
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
                .fixedSize(horizontal: false, vertical: true)
            actions()
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}

extension EmptyStateView where Actions == EmptyView {
    init(icon: String, title: String, message: String, tint: Color = .secondary) {
        self.init(icon: icon, title: title, message: message, tint: tint) { EmptyView() }
    }
}

// MARK: - 扫描器展示卡片

/// 单个扫描器能力卡片：图标 + 中文名 + 一句话描述。
struct ScannerCard: View {
    let entry: ScannerCatalog.Entry

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(tintColor.opacity(0.12))
                    .frame(width: 34, height: 34)
                Image(systemName: entry.icon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(tintColor)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.displayName)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.primary)
                Text(entry.description)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineSpacing(1)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Theme.bgSurface, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.divider, lineWidth: 1))
    }

    private var tintColor: Color {
        switch entry.tint {
        case .blue:   return .blue
        case .green:  return .green
        case .orange: return .orange
        case .purple: return .purple
        case .teal:   return .teal
        case .coral:  return Color(hex: 0xD85A30)
        }
    }
}

/// 扫描过程中「一个个跑」时，单个扫描器的一行状态。
///
/// 通过 `ScannerCatalog.entry(for:)` 拿到展示信息（图标、中文名、简介），
/// 再按 `ScannerProgress.phase` 显示 等待 / 进行中 / 完成（命中数）。
struct ScannerRunRow: View {
    let prog: ScannerProgress

    private var entry: ScannerCatalog.Entry { ScannerCatalog.entry(for: prog.name) }

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 7)
                    .fill(tint.opacity(prog.phase == .pending ? 0.06 : 0.14))
                    .frame(width: 30, height: 30)
                Image(systemName: entry.icon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(prog.phase == .pending ? tint.opacity(0.5) : tint)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(entry.displayName)
                    .font(.system(size: 12.5, weight: prog.phase == .running ? .semibold : .regular))
                    .foregroundStyle(prog.phase == .pending ? .secondary : .primary)
                Text(entry.description)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)

            statusView
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Theme.bgSurface, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .stroke(prog.phase == .running ? tint.opacity(0.5) : Theme.divider, lineWidth: 1))
        .opacity(prog.phase == .pending ? 0.6 : 1.0)
        .animation(.easeInOut(duration: 0.2), value: prog.phase)
    }

    @ViewBuilder
    private var statusView: some View {
        switch prog.phase {
        case .pending:
            Text(L10n.t("等待", "Queued"))
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
        case .running:
            ProgressView()
                .controlSize(.small)
                .frame(width: 16)
        case .done:
            HStack(spacing: 4) {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.success)
                Text(L10n.t("\(prog.foundCount) 项", "\(prog.foundCount)"))
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var tint: Color {
        switch entry.tint {
        case .blue:   return .blue
        case .green:  return .green
        case .orange: return .orange
        case .purple: return .purple
        case .teal:   return .teal
        case .coral:  return Color(hex: 0xD85A30)
        }
    }
}

extension Color {
    init(hex: UInt) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}
