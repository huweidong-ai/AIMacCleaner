import SwiftUI

// MARK: - 弹窗统一头部

/// 弹窗统一头部：标题 + 可选副标题 + 可选图标。
///
/// **刻意不放关闭按钮**——关闭动作统一沉到 `SheetActionBar` 的右下角，
/// 消除「关闭键有时在右上、有时在左下」的割裂感。
struct SheetHeader: View {
    let title: String
    var subtitle: String? = nil
    var icon: String? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if let icon {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Theme.accentSubtle)
                    .frame(width: 30, height: 30)
                    .overlay(Image(systemName: icon)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.accent))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(Theme.Spacing.lg)
    }
}

// MARK: - 弹窗统一底部操作条

/// 弹窗统一底部操作条：左侧放辅助动作（复制 / 预览 / 打开系统设置…），
/// 右侧放主操作 / 关闭，且**主操作永远最右**。
///
/// 只读弹窗只放一个「关闭」；操作弹窗放「取消」+ 主操作。
struct SheetActionBar<Leading: View, Trailing: View>: View {
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            leading
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.md)
        .background(Theme.bgSurface)
    }
}

// MARK: - 空白点击关闭

extension View {
    /// 在视图背后铺一层透明可点区域：点「卡片之外、容器之内的四周留白」即触发 `onDismiss`。
    ///
    /// 实现安全性：空白层是兄弟节点且在最底层，点中卡片本身（顶层，带自己的背景）不会触发，
    /// 因此**不会误触**卡片内的文字选择 / 按钮 / 输入框。只在四周留白处响应——实现安全的
    /// 「点空白关闭」。调用方需让本视图比外层容器小（留出 40pt 留白环）才看得到可点的空白。
    func blanketDismiss(enabled: Bool = true, onDismiss: @escaping () -> Void) -> some View {
        ZStack {
            if enabled {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onDismiss)
            }
            self
        }
    }
}

// MARK: - 标准关闭 / 取消按钮

/// 只读弹窗的统一「关闭」按钮：带 Esc 快捷键（`cancelAction`）。
struct SheetCloseButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(title, action: action)
            .keyboardShortcut(.cancelAction)
    }
}

// MARK: - 统一尺寸预设

/// 历史 / 记录类弹窗的统一尺寸，以 `FeedbackHistorySheet` 为基准。
///
/// 用这套预设而不是在三个 sheet 里各写一遍魔法数字，能保证它们永远一致、
/// 不会随手改其中一个而漂开。内容尺寸再叠 40pt 留白环即外层尺寸。
enum SheetPreset {
    /// 内容尺寸：FeedbackHistorySheet 基准 620×460。
    static let historyList = CGSize(width: 620, height: 460)
    /// 含点空白关闭留白环（四周各 +40）的外层尺寸：700×540。
    static let historyListOuter = CGSize(width: 700, height: 540)
}
