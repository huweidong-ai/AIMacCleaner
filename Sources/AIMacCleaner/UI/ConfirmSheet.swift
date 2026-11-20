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
    /// 额外的强警告（如「重置会让你退出登录」）。nil = 不显示。
    let warning: String?
    /// 确认按钮文案。默认沿用「卸载」。
    let confirmTitle: String
    let onConfirm: (UserDataDisposition) -> Void

    /// 是否连用户数据也直接彻底删除。**卸载时默认 true**；「瘦身 / 重置」传
    /// `trashByDefault: true`，让用户数据默认进废纸篓 —— 重置的本质是「弄丢状态」，
    /// 既然已经要退出登录，就再留一条可找回的退路。
    @State private var hardDeleteUserData: Bool

    /// - Parameters:
    ///   - trashByDefault: true 时初始不勾「硬删用户数据」，即默认全部进废纸篓。
    init(title: String, artifacts: [Artifact], warning: String? = nil,
         confirmTitle: String = L10n.t("卸载", "Uninstall"),
         trashByDefault: Bool = false,
         onConfirm: @escaping (UserDataDisposition) -> Void) {
        self.title = title
        self.artifacts = artifacts
        self.warning = warning
        self.confirmTitle = confirmTitle
        self._hardDeleteUserData = State(initialValue: !trashByDefault)
        self.onConfirm = onConfirm
    }

    /// 执行器不会自动删除的分类：shell rc 只标记「需手动编辑」，
    /// pkg 收据需要 root 权限，两者都不能算进「直接删除」。
    /// 这里必须与 RemovalExecutor 的阶段 4 保持一致，否则确认弹窗会假报数量。
    nonisolated static let manualCategories: Set<ArtifactCategory> = [.shellRc, .pkgReceipt]

    /// 确认弹窗的分流计数。抽成纯函数供自检断言——这正是出过误导文案的地方。
    /// - direct：真的会被执行器删掉的项（硬删时含用户数据）
    /// - trash：取消硬删时的用户数据项
    /// - manual：明确不自动处理、需要用户介入的项
    nonisolated static func split(artifacts: [Artifact], hardDeleteUserData: Bool) -> (direct: Int, trash: Int, manual: Int) {
        let manual = artifacts.filter { manualCategories.contains($0.category) }
        let actionable = artifacts.filter { !manualCategories.contains($0.category) }
        let userData = actionable.filter { $0.risk == .userData }
        return (hardDeleteUserData ? actionable.count : actionable.count - userData.count,
                hardDeleteUserData ? 0 : userData.count,
                manual.count)
    }

    private var totalSize: Int64 { artifacts.reduce(0) { $0 + $1.size } }
    private var userDataItems: [Artifact] { artifacts.filter { $0.risk == .userData } }
    private var counts: (direct: Int, trash: Int, manual: Int) {
        Self.split(artifacts: artifacts, hardDeleteUserData: hardDeleteUserData)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: "exclamationmark.triangle.fill")
                .font(.title2.bold())
                .foregroundStyle(Theme.warning)

            // 分流概览：一眼看清「哪些直接删、哪些进废纸篓」。
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.t(
                    "即将处理 \(artifacts.count) 项（\(SizeFormat.human(totalSize))）：",
                    "About to process \(artifacts.count) items (\(SizeFormat.human(totalSize))):"))
                    .font(.callout)
                HStack(spacing: 12) {
                    Label {
                        Text(L10n.t("\(counts.direct) 项直接删除（应用 / 缓存 / 日志，不可恢复）",
                                    "\(counts.direct) deleted directly (app, caches, logs — not recoverable)"))
                    } icon: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.destructive)
                    }
                    Label {
                        Text(L10n.t("\(counts.trash) 项移到废纸篓（用户数据，可找回）",
                                    "\(counts.trash) moved to Trash (user data, recoverable)"))
                    } icon: {
                        Image(systemName: "trash.fill").foregroundStyle(Theme.accent)
                    }
                    if counts.manual > 0 {
                        Label {
                            Text(L10n.t("\(counts.manual) 项需手动编辑，不会自动删",
                                        "\(counts.manual) need manual editing — not auto-removed"))
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
                        }
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

            // 档位特有的强警告（如「重置会让你退出登录」）。放在这里而不是只写在
            // 结果页横幅上：这是用户点下主按钮后的最后一道确认屏。
            if let warning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(Theme.destructive)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.destructive.opacity(0.10),
                                in: RoundedRectangle(cornerRadius: 6))
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
                            // 需手动项单独打标：这一行点了卸载也不会自动处理。
                            if Self.manualCategories.contains(a.category) {
                                Text(L10n.t("需手动", "Manual"))
                                    .font(.system(size: 9.5, weight: .semibold))
                                    .foregroundStyle(Theme.warning)
                            }
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
                    Text(confirmTitle)
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
