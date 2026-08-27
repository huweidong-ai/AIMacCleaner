import SwiftUI

/// 用户数据怎么处置：默认移到废纸篓（可恢复），或勾选后一并彻底删除。
///
/// 真实的「删什么走哪儿」由 `Artifact.risk` 决定，这里只控制**用户数据**这一类：
/// - `toTrash`   ：userData 类 → 废纸篓（可恢复）；safe / uncertain 类 → 直接删除（不可恢复）
/// - `hardDelete`：全部 → 直接删除（不可恢复）
enum UserDataDisposition {
    case toTrash
    case hardDelete
}

/// 删除前的确认弹窗，扫描页和残留页共用。
///
/// 设计取舍：不要「输入 app 名」那种摩擦（针对不可逆操作的仪式，用在走废纸篓的删除上属于过度设防），
/// 也不要「不问直接删」。这里给的是**看清再点**：完整路径列表 + 可选中复制 + 高风险项单独提示 +
/// 一条明确的分流说明（哪些直接删、哪些进废纸篓）。
///
/// v1.5 起不再让用户全局二选一「废纸篓 / 彻底删除」——那是把「删到哪」的实现细节
/// 甩给用户。改成按 `risk` 自动分流：可安全删除的项（应用、缓存、日志、安装器）直接删，
/// **默认连用户数据也一起直接删**（彻底干净），想保留到废纸篓可找回是一个显式的取消勾选。
struct ConfirmSheet: View {
    @Environment(\.dismiss) var dismiss
    @State private var toast: String? = nil

    let title: String
    let artifacts: [Artifact]
    let onConfirm: (UserDataDisposition) -> Void

    private var totalSize: Int64 { artifacts.reduce(0) { $0 + $1.size } }
    private var userDataItems: [Artifact] { artifacts.filter { $0.risk == .userData } }

    /// 实际会进「直接删除」通道的项数：
    /// - 勾选硬删时 = `artifacts.count`（用户数据也跟着直接删，不留任何东西）
    /// - 取消勾选时 = `artifacts.count - userDataItems.count`（只算非用户数据部分）
    private var effectiveDirectCount: Int {
        hardDeleteUserData ? artifacts.count : artifacts.count - userDataItems.count
    }
    /// 实际会进「废纸篓」的项数：
    /// - 勾选硬删时 = 0
    /// - 取消勾选时 = `userDataItems.count`
    private var effectiveTrashCount: Int {
        hardDeleteUserData ? 0 : userDataItems.count
    }

    /// 是否连用户数据也直接彻底删除。**默认勾选**（true）——用户数据默认就一起硬删除，
    /// 想保留到废纸篓可找回，就**取消**这个勾选。
    @State private var hardDeleteUserData = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: "exclamationmark.triangle.fill")
                .font(.title2.bold())
                .foregroundStyle(Theme.warning)

            // 分流概览：一眼看清「哪些直接删、哪些进废纸篓」。
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.t(
                    "即将卸载 \(artifacts.count) 项（\(SizeFormat.human(totalSize))）：",
                    "About to uninstall \(artifacts.count) items (\(SizeFormat.human(totalSize))):"))
                    .font(.callout)
                HStack(spacing: 12) {
                    Label {
                        Text(L10n.t("\(effectiveDirectCount) 项直接删除（应用 / 缓存 / 日志，不可恢复）",
                                    "\(effectiveDirectCount) deleted directly (app, caches, logs — not recoverable)"))
                    } icon: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.destructive)
                    }
                    Label {
                        Text(L10n.t("\(effectiveTrashCount) 项移到废纸篓（用户数据，可找回）",
                                    "\(effectiveTrashCount) moved to Trash (user data, recoverable)"))
                    } icon: {
                        Image(systemName: "trash.fill").foregroundStyle(Theme.accent)
                    }
                }
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            }

            if !userDataItems.isEmpty {
                Label(L10n.t(
                    "其中 \(userDataItems.count) 项是用户数据（聊天记录、账号、配置等），删除后需要重新登录或重新配置。",
                    "\(userDataItems.count) of them are user data (chat history, accounts, settings) — you would need to sign in or reconfigure afterwards."),
                      systemImage: "person.crop.circle.badge.exclamationmark")
                    .font(.caption)
                    .foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // 路径必须能选中复制：想在删之前把清单贴到别处核对是很自然的需求。
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(artifacts) { a in
                        HStack(spacing: 6) {
                            Text(a.path)
                                .font(.system(.caption2, design: .monospaced))
                                .textSelection(.enabled)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            // 每行都标风险 pill（色 + 图标 + 字），看清再点。
                            RiskPill(risk: a.risk)
                            Text(SizeFormat.human(a.size))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 200)
            .padding(8)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))

            SheetActionBar {
                Button {
                    copyAllPaths()
                } label: {
                    Label(L10n.t("复制全部路径", "Copy all paths"), systemImage: "doc.on.doc")
                }
                .controlSize(.small)

                if !userDataItems.isEmpty {
                    Toggle(L10n.t("用户数据也直接删除（不可恢复）",
                                  "Also hard-delete user data (unrecoverable)"),
                           isOn: $hardDeleteUserData)
                        .font(.callout)
                        .help(L10n.t("默认连用户数据也一起彻底删除（不可恢复）。取消勾选则只移到废纸篓，清空废纸篓前都能找回。",
                                     "By default user data is also hard-deleted (unrecoverable). Uncheck to keep it in Trash — recoverable until you empty it."))
                }
            } trailing: {
                Button(L10n.t("取消", "Cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                // 卸载动作包含「直接删除」的不可逆部分，主按钮用红色强调。
                Button {
                    dismiss()
                    onConfirm(hardDeleteUserData ? .hardDelete : .toTrash)
                } label: {
                    Text(L10n.t("卸载", "Uninstall"))
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.destructive)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 540)
        .interactiveDismissDisabled(true)
        .overlay(alignment: .bottom) {
            if let toast {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                    Text(toast)
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(Theme.success, in: RoundedRectangle(cornerRadius: 8))
                .shadow(color: .black.opacity(0.22), radius: 8, y: 4)
                .padding(.bottom, 48)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(.easeOut(duration: 0.18), value: toast)
    }

    private func copyAllPaths() {
        let text = artifacts.map(\.path).joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        flash(L10n.t("已复制 \(artifacts.count) 条路径", "Copied \(artifacts.count) paths"))
    }

    /// 复制成功后底部浮出、约 1.6s 自动消失的轻提示（success toast）。
    private func flash(_ msg: String) {
        toast = msg
        let token = msg
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            if toast == token { toast = nil }
        }
    }
}
