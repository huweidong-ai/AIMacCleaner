import SwiftUI
import AppKit

/// 「需要完全磁盘访问权限」引导页。
///
/// 替代 macOS 在扫描 `~/Library` 下其他 app 数据时硬弹的
/// 「想访问其他App的数据」系统框：没授权时先弹这个，引导用户去
/// 系统设置一次性授权，授权回来后继续扫描。
struct FDAGuidanceSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var stillDenied = false

    var body: some View {
        VStack(spacing: 0) {
            // 顶部图标 + 标题
            VStack(spacing: 10) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                Text(L10n.t("需要「完全磁盘访问」权限", "Full Disk Access required"))
                    .font(.system(size: 17, weight: .bold))
            }
            .padding(.top, 22)
            .padding(.bottom, 14)

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                Text(L10n.t("AI Mac Cleaner 要扫描其他 App 的数据（缓存、配置，以及微信等 App 的沙盒容器残留），这需要 macOS 的「完全磁盘访问」权限。",
                            "AI Mac Cleaner scans other apps’ data — caches, settings, and sandbox-container leftovers such as WeChat’s. "
                            + "macOS requires Full Disk Access for that."))
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(L10n.t("只需授权一次：在系统设置里把本应用勾选上即可，之后不再提示。",
                            "Grant it once: tick this app in System Settings and the prompt won’t return."))
                    .frame(maxWidth: .infinity, alignment: .leading)

                if stillDenied {
                    Text(L10n.t("仍未检测到授权。请确认已在系统设置里勾选 AI Mac Cleaner，然后重试。",
                                "Still no access detected. Make sure AI Mac Cleaner is ticked in System Settings, then retry."))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 24)
            .padding(.vertical, 16)

            Divider()

            SheetActionBar {
                Button(L10n.t("打开系统设置", "Open System Settings")) {
                    PrivacyAccess.openFullDiskAccessSettings()
                }
                .controlSize(.small)
            } trailing: {
                Button(L10n.t("取消", "Cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(L10n.t("我已授权，继续扫描", "I’ve granted it, scan")) {
                    if state.recheckFullDiskAccessAndResume() {
                        dismiss()
                    } else {
                        stillDenied = true
                    }
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .frame(width: 460)
        .interactiveDismissDisabled(true)
    }
}
