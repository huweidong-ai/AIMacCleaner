import SwiftUI
import AppKit

/// 「关于 AI Mac Cleaner」弹窗（替代系统标准关于面板，内容可控、与设计系统一致）。
struct AboutSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    private let repoURL = URL(string: "https://github.com/hwd8080-ai/AIMacCleaner")!

    var body: some View {
        VStack(spacing: 0) {
            // 顶部：图标 + 名称 + 版本
            VStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 16)
                    .fill(LinearGradient(colors: [Theme.accent, Theme.accentActive],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 64, height: 64)
                    .overlay(
                        Image(systemName: "wand.and.rays")
                            .font(.system(size: 30, weight: .semibold))
                            .foregroundStyle(.white)
                    )
                Text("AI Mac Cleaner")
                    .font(.system(size: 20, weight: .bold))
                Text(L10n.t("Mac 深度卸载工具", "Deep uninstaller for macOS"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Text("v\(AIMacCleanerApp.version)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 2)
            }
            .padding(.top, 24)
            .padding(.bottom, 18)

            Divider()

            // 简介
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.t("AI Mac Cleaner 帮你把 app 连同它的依赖、缓存、配置和残留痕迹一起清掉，",
                            "AI Mac Cleaner removes an app together with its dependencies, caches, "
                            + "settings and leftover traces."))
                Text(L10n.t("默认移到废纸篓，可恢复；要彻底删除时才会一并清空。",
                            "By default everything goes to the Trash — recoverable. "
                            + "Permanent deletion is opt-in."))
            }
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.vertical, 16)

            Divider()

            // 四个能力点
            HStack(spacing: 10) {
                capability(icon: "bubble.left.and.text.bubble.right",
                           title: L10n.t("问 AI", "Ask AI"),
                           desc: L10n.t("用自然语言驱动清理", "Drive cleanup by chat"))
                capability(icon: "apps.iphone",
                           title: L10n.t("应用", "Apps"),
                           desc: L10n.t("卸载与重置", "Uninstall & reset"))
                capability(icon: "sparkle",
                           title: L10n.t("残留", "Leftovers"),
                           desc: L10n.t("揪出孤儿文件", "Find orphan files"))
                capability(icon: "memorychip",
                           title: L10n.t("进程", "Processes"),
                           desc: L10n.t("管理后台进程", "Manage background tasks"))
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)

            Divider()

            // 底部：链接 + 关闭
            SheetActionBar {
                HStack(spacing: 8) {
                    Button {
                        openURL(repoURL)
                    } label: {
                        Label(L10n.t("GitHub 仓库", "GitHub Repository"),
                              systemImage: "link")
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderless)
                    .foregroundStyle(Theme.accent)
                    Text(L10n.t("免费 · 开源 · 数据不出本机", "Free · Open source · Local only"))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            } trailing: {
                Button(L10n.t("完成", "Done")) { dismiss() }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .frame(width: 440, height: 460)
        .blanketDismiss { dismiss() }
        .presentationBackground(Theme.bgSurface)
        .frame(width: 520, height: 540)
    }

    private func capability(icon: String, title: String, desc: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Theme.accent)
                .frame(width: 36, height: 36)
                .background(Circle().fill(Theme.accentSubtle))
            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
            Text(desc)
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }
}
