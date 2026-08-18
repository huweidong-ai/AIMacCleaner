import SwiftUI
import AppKit

// MARK: - 执行结果

struct ResultSheet: View {
    @Environment(\.dismiss) var dismiss
    @State private var toast: String? = nil
    /// false = 成功（绿色对勾），true = 失败/警告（红色叉）。
    @State private var toastTone: Bool = false
    let output: [String]
    /// 成败必须由执行器的真实计数决定，不能写死。
    /// v1.3 的 bug：这个 sheet 无条件显示绿色「卸载完成」，即使
    /// 「成功 0 项，失败 4 项」也一样 —— 正是本项目最该避免的假报成功。
    /// 需用户手动处理的项数（如 shell rc 配置行）。未自动删除，不能算成功。
    let manualCount: Int
    /// 直接删除释放的字节数与移入废纸篓的字节数（执行器统计，可为 0）。
    var freedBytes: Int64 = 0
    var trashedBytes: Int64 = 0
    /// 因权限不足（root 拥有）普通删除失败、可「以管理员身份删除」兜底的项。
    var elevatableFailures: [HistoryStore.DeletedArtifact] = []

    // 成功 / 失败计数用 @State 工作副本：点「以管理员身份删除」成功后，
    // 实时把失败数 −1、成功数 +1，让汇总卡片反映真实结果（避免假报）。
    @State private var successCount: Int
    @State private var failureCount: Int
    /// 待「以管理员身份删除」的剩余项（点一次成功就从这里移除一条）。
    @State private var elevatable: [HistoryStore.DeletedArtifact]
    /// 每条提权删除后的结果说明（成功/失败原因），显示在对应行下方。
    @State private var elevatableMsg: [String: String] = [:]

    /// 四态：全失败 / 部分失败 / 全手动 / 全成功。部分失败单独成一态，
    /// 因为「删了 8 项、剩 2 项没删掉」既不能报完成、也不该报失败。
    /// 抽成 `nonisolated static` 纯函数是为了让自检能直接断言它 ——
    /// View 的私有计算属性测不到，而这正是出过 bug 的地方。
    enum Status { case allFailed, partial, manualOnly, allSucceeded }

    nonisolated static func status(successCount: Int, failureCount: Int, manualCount: Int) -> Status {
        // 真正的失败优先于「需手动」——失败是意外，手动是预期内但需用户介入。
        if failureCount > 0 && successCount == 0 { return .allFailed }
        if failureCount > 0 { return .partial }
        // 没有真实成功、也没有真实失败，但有手动项：整单都没自动完成。
        if manualCount > 0 && successCount == 0 { return .manualOnly }
        // 有真实成功，同时有手动项：部分自动完成，部分需手动。
        if manualCount > 0 { return .partial }
        return .allSucceeded
    }

    private var display: (title: String, icon: String, color: Color) {
        switch Self.status(successCount: successCount, failureCount: failureCount, manualCount: manualCount) {
        case .allFailed:
            return (L10n.t("卸载失败（\(failureCount) 项失败）",
                           "Uninstall failed (\(failureCount) failed)"),
                    "xmark.octagon.fill", Theme.destructive)
        case .partial:
            // 部分完成时，标题必须同时把成功数和失败/手动数摆出来，
            // 让用户一眼就知道这次到底发生了多少问题。
            let title: String
            if failureCount > 0 && manualCount > 0 {
                title = L10n.t("部分完成：成功 \(successCount) 项，失败 \(failureCount) 项，需手动 \(manualCount) 项",
                               "Partially complete: \(successCount) succeeded, \(failureCount) failed, \(manualCount) manual")
            } else if failureCount > 0 {
                title = L10n.t("部分完成：成功 \(successCount) 项，失败 \(failureCount) 项",
                               "Partially complete: \(successCount) succeeded, \(failureCount) failed")
            } else {
                title = L10n.t("部分完成：成功 \(successCount) 项，需手动 \(manualCount) 项",
                               "Partially complete: \(successCount) succeeded, \(manualCount) manual")
            }
            return (title, "exclamationmark.triangle.fill", Theme.warning)
        case .manualOnly:
            return (L10n.t("需手动完成（\(manualCount) 项未自动处理）",
                           "Manual action required (\(manualCount) not auto-removed)"),
                    "exclamationmark.triangle.fill", Theme.warning)
        case .allSucceeded:
            return (L10n.t("卸载完成（成功 \(successCount) 项）",
                           "Uninstall complete (\(successCount) succeeded)"),
                    "checkmark.circle.fill", Theme.success)
        }
    }

    init(output: [String], successCount: Int, failureCount: Int, manualCount: Int,
         freedBytes: Int64 = 0, trashedBytes: Int64 = 0,
         elevatableFailures: [HistoryStore.DeletedArtifact] = []) {
        self.output = output
        self.manualCount = manualCount
        self.freedBytes = freedBytes
        self.trashedBytes = trashedBytes
        self.elevatableFailures = elevatableFailures
        self._successCount = State(initialValue: successCount)
        self._failureCount = State(initialValue: failureCount)
        self._elevatable = State(initialValue: elevatableFailures)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label(display.title, systemImage: display.icon)
                    .font(.title2.bold())
                    .foregroundStyle(display.color)
            }
            .padding()

            // 三格统计：成功 / 直接释放 / 进废纸篓。比日志更快回答
            //「到底腾出多少、有没有东西还能找回」。
            HStack(spacing: 10) {
                statCard(value: "\(successCount)", label: L10n.t("已处理", "Processed"), tint: Theme.success)
                statCard(value: SizeFormat.human(freedBytes), label: L10n.t("直接释放", "Freed"), tint: .primary)
                statCard(value: SizeFormat.human(trashedBytes), label: L10n.t("进废纸篓", "To Trash"), tint: Theme.accent)
                if failureCount > 0 {
                    statCard(value: "\(failureCount)", label: L10n.t("失败", "Failed"), tint: Theme.destructive)
                }
                if manualCount > 0 {
                    statCard(value: "\(manualCount)", label: L10n.t("需手动", "Manual"), tint: Theme.warning)
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 12)

            if failureCount > 0 {
                // 计数摆在最显眼处。日志滚动区里那几行 "!" 太容易被划过去。
                Text(L10n.t("失败项的原因见下方日志。", "See the log below for the reasons."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
                    .padding(.bottom, 8)
            }
            if manualCount > 0 {
                Text(L10n.t("以下 \(manualCount) 项未能自动删除（涉及系统权限或需手动编辑），请按日志中的 ⚠️ 提示处理。",
                           "\(manualCount) item(s) could not be auto-removed (require system privileges or manual edit). Follow the ⚠️ prompts in the log."))
                    .font(.callout)
                    .foregroundStyle(Theme.warning)
                    .padding(.horizontal)
                    .padding(.bottom, 8)
            }
            if !elevatable.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.t("以下 \(elevatable.count) 项因权限不足删除失败（文件由系统以 root 身份安装）。可点按钮以管理员身份删除 —— 会弹出系统密码框授权，且不可撤销。",
                               "\(elevatable.count) item(s) failed due to insufficient permissions (installed by the system as root). Delete them as admin — this triggers the system password prompt and is unrecoverable."))
                        .font(.callout)
                        .foregroundStyle(Theme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(elevatable, id: \.path) { item in
                        HStack(alignment: .center, spacing: 10) {
                            Image(systemName: "lock.fill")
                                .foregroundStyle(Theme.warning)
                                .frame(width: 18)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.path)
                                    .font(.system(.callout, design: .monospaced))
                                    .textSelection(.enabled)
                                if let msg = elevatableMsg[item.path], !msg.isEmpty {
                                    Text(msg)
                                        .font(.caption)
                                        .foregroundStyle(msg.hasPrefix(L10n.t("已用管理员权限删除", "Deleted with admin")) ? Theme.success : .secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            Spacer(minLength: 8)
                            Button {
                                elevate(item.path)
                            } label: {
                                Text(L10n.t("以管理员身份删除", "Delete as admin"))
                                    .font(.callout.weight(.semibold))
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(Theme.destructive)
                            .controlSize(.small)
                        }
                        .padding(10)
                        .background(Theme.bgCanvas, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.divider, lineWidth: 1))
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 8)
            }
            Divider()
            ScrollView {
                // 整段日志渲染成**一个** Text，而不是逐行一个。
                // 逐行的话每行是独立的可选区域，鼠标拖不过行边界 ——
                // 想复制整份失败报告（比如贴到 issue 里）就只能一行行来。
                Text(output.joined(separator: "\n"))
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            Divider()
            SheetActionBar {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(output.joined(separator: "\n"), forType: .string)
                    flash(L10n.t("已复制 \(output.count) 条日志", "Copied \(output.count) log lines"))
                } label: {
                    Label(L10n.t("复制全部日志", "Copy full log"), systemImage: "doc.on.doc")
                }
                .controlSize(.small)
            } trailing: {
                SheetCloseButton(title: L10n.t("关闭", "Close")) { dismiss() }
            }
        }
        .frame(width: 560, height: 460)
        .overlay(alignment: .bottom) { toastOverlay }
        .animation(.easeOut(duration: 0.18), value: toast)
        .blanketDismiss { dismiss() }
        .presentationBackground(Theme.bgSurface)
        .frame(width: 640, height: 540)
    }

    private func statCard(value: String, label: String, tint: Color) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 17, weight: .semibold, design: .monospaced))
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Theme.bgCanvas, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.divider, lineWidth: 1))
    }

    @ViewBuilder
    private var toastOverlay: some View {
        if let toast {
            HStack(spacing: 6) {
                Image(systemName: toastTone ? "xmark.circle.fill" : "checkmark.circle.fill")
                Text(toast)
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(toastTone ? Theme.destructive : Theme.success, in: RoundedRectangle(cornerRadius: 8))
            .shadow(color: .black.opacity(0.22), radius: 8, y: 4)
            .padding(.bottom, 48)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }

    /// 复制成功 / 提权删除结果后底部浮出、约 1.8s 自动消失的轻提示。
    /// `isError` 为 true 时显示红色叉（用于提权删除失败）。
    private func flash(_ msg: String, isError: Bool = false) {
        toast = msg
        toastTone = isError
        let token = msg
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            if toast == token { toast = nil }
        }
    }

    /// 「以管理员身份删除」：调 `PrivilegedDeleter` 以 root 删这一条。
    /// NSAppleScript 的密码框由 SecurityAgent 在独立进程弹出，主线程等待不会死锁，
    /// 且能确保 UI 状态在同一线程就地更新。
    private func elevate(_ path: String) {
        let results = PrivilegedDeleter.delete([path])
        guard let r = results.first else { return }
        if r.success {
            // 成功：失败数 −1、成功数 +1，并从待处理列表移除，汇总卡片如实反映。
            elevatable.removeAll { $0.path == path }
            successCount += 1
            failureCount = max(0, failureCount - 1)
            flash(L10n.t("已用管理员权限删除：\(path)", "Deleted as admin: \(path)"))
        } else {
            elevatableMsg[path] = r.message
            flash(L10n.t("管理员删除失败：\(r.message)", "Admin delete failed: \(r.message)"), isError: true)
        }
    }
}

// MARK: - 误报反馈

/// 「这条不该被扫到 / 风险判错了」的反馈入口。
///
/// 为什么要做：扫描规则是启发式的，误报是常态而不是意外。没有反馈通道，
/// 用户遇到误报只能自己绕过去，规则永远不会变准。
///
/// 两条通道：GitHub Issue（公开可追踪，预填标题与正文）和邮件（不想公开时用）。
/// 都不需要 app 内联网 —— 只是拼好文本、交给系统打开浏览器或邮件客户端，
/// 这样既不用申请网络权限，用户也能在发送前逐字看清要提交什么。
struct FeedbackSheet: View {
    @Environment(\.dismiss) private var dismiss

    /// 针对某一条痕迹的反馈；从侧栏进入时为 nil（泛化反馈）。
    let target: Artifact?
    /// 二次编辑：传入已有记录会预填表单，提交时更新而非新建。
    let editingEntry: FeedbackEntry?

    enum Reason: String, CaseIterable, Identifiable {
        case notThisApp, wrongRisk, brokeAfterDelete, missed
        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .notThisApp:       return L10n.t("不属于这个应用", "Not part of this app")
            case .wrongRisk:        return L10n.t("风险等级判错了", "Wrong risk level")
            case .brokeAfterDelete: return L10n.t("删了之后出问题", "Something broke after deleting")
            case .missed:           return L10n.t("该扫到却没扫到", "Should have been found")
            }
        }
    }

    enum Channel { case github, mail }

    @State private var reason: Reason = .notThisApp
    @State private var note: String = ""
    @State private var channel: Channel = .github
    @State private var includeDiagnostics = true
    @State private var showPreview = false
    /// 用户是否已改动表单。关闭时若有未提交改动，先弹二次确认，避免误丢。
    @State private var touched = false
    @State private var showDiscard = false

    private static let repoIssueURL = "https://github.com/hwd8080-ai/AIMacCleaner/issues/new"
    private static let feedbackMail = "aimaccleaner@duck.com"

    init(target: Artifact? = nil, editingEntry: FeedbackEntry? = nil) {
        self.target = target
        self.editingEntry = editingEntry
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let target { targetCard(target) }
                    fieldLabel(L10n.t("问题类型", "What went wrong"))
                    reasonPicker
                    fieldLabel(L10n.t("补充说明（可选）", "Details (optional)"))
                    TextEditor(text: $note)
                        .font(.system(size: 12))
                        .frame(height: 76)
                        .onChange(of: note) { _, _ in touched = true }
                        .padding(5)
                        .background(Theme.bgCanvas, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.divider, lineWidth: 1))
                    fieldLabel(L10n.t("提交到", "Send via"))
                    channelPicker
                    Toggle(isOn: $includeDiagnostics) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L10n.t("附带诊断信息", "Include diagnostics"))
                                .font(.system(size: 12))
                            Text(L10n.t("仅包含 macOS 版本、AI Mac Cleaner 版本与命中的路径；用户名会被打码，绝不上传文件内容。",
                                        "Only macOS version, AI Mac Cleaner version and the matched path. Your username is masked and no file contents are sent."))
                                .font(.system(size: 10.5))
                                .foregroundStyle(.tertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .toggleStyle(.checkbox)
                    .onChange(of: includeDiagnostics) { _, _ in touched = true }
                }
                .padding(16)
            }
            Divider()
            footer
        }
        .frame(width: 520, height: 560)
        // 子 sheet：macOS 上从 sheet 里再弹 sheet 是支持的，会叠在父弹窗之上居中。
        // 内容在弹出瞬间求值，拿到的就是当下填好的表单。
        .sheet(isPresented: $showPreview) {
            FeedbackPreviewSheet(titleLine: titleText(), bodyMarkdown: bodyText())
        }
        .onAppear {
            guard let e = editingEntry else { return }
            // 二次编辑：还原 reason / note / channel。
            if let r = Self.reason(from: e) { reason = r }
            note = e.note
            channel = e.channel == "github" ? .github : .mail
            includeDiagnostics = false // 编辑时默认不再重新附带诊断，可手动改
        }
        .interactiveDismissDisabled(true)
        .alert(L10n.t("放弃未提交的反馈？", "Discard feedback?"), isPresented: $showDiscard) {
            Button(L10n.t("继续编辑", "Keep editing"), role: .cancel) {}
            Button(L10n.t("放弃", "Discard"), role: .destructive) { dismiss() }
        } message: {
            Text(L10n.t("你填写的内容尚未提交，关闭后将丢失。", "Your draft will be lost if you close without sending."))
        }
    }

    /// 从 FeedbackEntry 还原 Reason：优先用原始 key，再按本地化文案匹配（兼容旧数据）。
    private static func reason(from entry: FeedbackEntry) -> Reason? {
        if let raw = entry.reasonRaw, let r = Reason(rawValue: raw) { return r }
        return Reason.allCases.first { $0.displayName == entry.reason }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 8)
                .fill(Theme.accentSubtle)
                .frame(width: 30, height: 30)
                .overlay(Image(systemName: "flag").font(.system(size: 13)).foregroundStyle(Theme.accent))
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.t("反馈记录", "Feedback"))
                    .font(.system(size: 14, weight: .semibold))
                Text(L10n.t("扫到了不该扫的？或者判断错了风险等级？提交后我们会据此修正匹配规则。",
                            "Found something that shouldn’t be there, or a wrong risk level? Submit feedback and we’ll fix the matching rules."))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
    }

    private func targetCard(_ a: Artifact) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "folder")
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text((a.path as NSString).lastPathComponent)
                    .font(.system(size: 12, weight: .medium))
                Text(Self.maskHome(a.path))
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            RiskPill(risk: a.risk)
        }
        .padding(10)
        .background(Theme.bgCanvas, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.divider, lineWidth: 1))
    }

    private func fieldLabel(_ t: String) -> some View {
        Text(t)
            .font(.system(size: 10.5, weight: .bold))
            .kerning(0.5)
            .foregroundStyle(.tertiary)
    }

    private var reasonPicker: some View {
        // 用自绘的小胶囊而不是 Picker：四个选项都要完整文案，
        // segmented Picker 在中文下会被压到看不清。
        FlowRow(spacing: 6) {
            ForEach(Reason.allCases) { r in
                Button {
                    reason = r
                    touched = true
                } label: {
                    Text(r.displayName)
                        .font(.system(size: 11.5))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .foregroundStyle(reason == r ? Theme.accent : Color.secondary)
                        .background(reason == r ? Theme.accentSubtle : Color.secondary.opacity(0.08),
                                    in: Capsule())
                        .overlay(Capsule().stroke(reason == r ? Theme.accentBorder : .clear, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var channelPicker: some View {
        VStack(spacing: 6) {
            channelRow(.github, icon: "chevron.left.forwardslash.chevron.right",
                       title: "GitHub Issue",
                       subtitle: L10n.t("公开可追踪，自动预填标题与详情", "Public and trackable; title and body prefilled"))
            channelRow(.mail, icon: "envelope",
                       title: L10n.t("发邮件", "Email"),
                       subtitle: L10n.t("\(Self.feedbackMail) · 不想公开时用",
                                        "\(Self.feedbackMail) · when you’d rather not go public"))
        }
    }

    private func channelRow(_ c: Channel, icon: String, title: String, subtitle: String) -> some View {
        Button {
            channel = c
            touched = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 13))
                    .frame(width: 24, height: 24)
                    .foregroundStyle(channel == c ? Theme.accent : Color.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 12, weight: .medium))
                    Text(subtitle).font(.system(size: 10.5)).foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
                Image(systemName: channel == c ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(channel == c ? Theme.accent : Color.secondary.opacity(0.4))
            }
            .padding(9)
            .background(channel == c ? Theme.accentSubtle : Theme.bgCanvas, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .stroke(channel == c ? Theme.accentBorder : Theme.divider, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var footer: some View {
        SheetActionBar {
            Button(L10n.t("预览提交内容", "Preview")) {
                showPreview = true
            }
            .controlSize(.small)
            .help(L10n.t("先摊开将要提交的标题与正文原文，确认无误再发送。",
                         "Shows the exact title and body that will be submitted, so you can check first."))
        } trailing: {
            Button(L10n.t("取消", "Cancel")) { attemptDismiss() }
                .keyboardShortcut(.cancelAction)
            Button(L10n.t("提交反馈", "Send")) {
                submit()
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
            .keyboardShortcut(.defaultAction)
        }
    }

    /// 关闭前若表单已改动，先弹二次确认，避免误丢未提交的反馈。
    private func attemptDismiss() {
        if touched {
            showDiscard = true
        } else {
            dismiss()
        }
    }

    // MARK: - 内容拼装

    /// 家目录打码：反馈里带真实用户名没有必要，也让人不敢点提交。
    /// 抽成 `nonisolated static` 纯函数是为了让自检能直接断言它。
    nonisolated static func maskHome(_ path: String) -> String {
        let home = NSHomeDirectory()
        guard path.hasPrefix(home) else { return path }
        return "~" + String(path.dropFirst(home.count))
    }

    /// 标题里的对象名：编辑时用记录里保存的 targetName；新建时用当前 target。
    private var targetNameForTitle: String? {
        editingEntry?.targetName ?? target.map { ($0.path as NSString).lastPathComponent }
    }

    private func titleText() -> String {
        let name = targetNameForTitle ?? L10n.t("扫描规则", "scan rules")
        return "\(L10n.t("[误报]", "[False positive]")) \(reason.displayName)：\(name)"
    }

    private func bodyText() -> String {
        var lines: [String] = []
        lines.append("## \(L10n.t("问题类型", "Issue type"))")
        lines.append(reason.displayName)
        if let target {
            lines.append("")
            lines.append("## \(L10n.t("命中路径", "Matched path"))")
            lines.append("```")
            lines.append(Self.maskHome(target.path))
            lines.append("\(L10n.t("类别", "Category")): \(target.category.rawValue)")
            lines.append("\(L10n.t("风险", "Risk")): \(target.risk.displayName)")
            lines.append("\(L10n.t("大小", "Size")): \(SizeFormat.human(target.size))")
            if let meta = target.meta { lines.append("\(L10n.t("说明", "Meta")): \(meta)") }
            lines.append("```")
        }
        if !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("")
            lines.append("## \(L10n.t("补充说明", "Details"))")
            lines.append(note)
        }
        if includeDiagnostics {
            let os = ProcessInfo.processInfo.operatingSystemVersion
            lines.append("")
            lines.append("## \(L10n.t("环境", "Environment"))")
            lines.append("- AI Mac Cleaner \(AIMacCleanerApp.version)")
            lines.append("- macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)")
        }
        return lines.joined(separator: "\n")
    }

    private func submit() {
        let title = titleText()
        let body = bodyText()

        // 二次编辑只更新本地记录，不再重复打开浏览器/邮件客户端。
        if let existing = editingEntry {
            FeedbackStore.shared.update(FeedbackEntry(
                id: existing.id,
                date: existing.date,
                targetName: existing.targetName,
                reason: reason.displayName,
                reasonRaw: reason.rawValue,
                note: note.trimmingCharacters(in: .whitespacesAndNewlines),
                channel: channel == .github ? "github" : "mail",
                title: title
            ))
            return
        }

        let url: URL?
        switch channel {
        case .github:
            var comps = URLComponents(string: Self.repoIssueURL)
            comps?.queryItems = [
                URLQueryItem(name: "title", value: title),
                URLQueryItem(name: "body", value: body)
            ]
            url = comps?.url
        case .mail:
            var comps = URLComponents()
            comps.scheme = "mailto"
            comps.path = Self.feedbackMail
            comps.queryItems = [
                URLQueryItem(name: "subject", value: title),
                URLQueryItem(name: "body", value: body)
            ]
            url = comps.url
        }
        guard let url else { return }
        // 打不开（没装邮件客户端 / 没有默认浏览器）就退回剪贴板，
        // 至少让用户手上有一份可以贴出去的原文，而不是点了没反应。
        if !NSWorkspace.shared.open(url) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("\(title)\n\n\(body)", forType: .string)
        }
        // 无论走哪个通道，都先落一条本地记录 —— 「反馈记录」入口看的就是它。
        FeedbackStore.shared.record(FeedbackEntry(
            id: UUID(),
            date: Date(),
            targetName: target.map { ($0.path as NSString).lastPathComponent },
            reason: reason.displayName,
            reasonRaw: reason.rawValue,
            note: note.trimmingCharacters(in: .whitespacesAndNewlines),
            channel: channel == .github ? "github" : "mail",
            title: title
        ))
    }
}

// MARK: - 反馈内容预览

/// 「预览提交内容」弹窗：把即将提交的标题与正文**原文**摊开。
///
/// 为什么要有：老版本点「预览」只是把文本塞进剪贴板，屏幕上毫无反应 ——
/// 用户既不知道自己刚才预览了什么，也就无从核对。这个工具要求用户在
/// 点「提交」前看清自己要发出去的每一个字，预览就不能是隐形的。
///
/// 显示的是 Markdown **源码**而不是渲染结果：提交出去的就是这段源码，
/// 渲染一遍反而让人看不到真正会被发送的内容。
struct FeedbackPreviewSheet: View {
    @Environment(\.dismiss) private var dismiss

    /// 注意：属性不能叫 `body` —— 那是 View 协议的要求，会直接编译失败。
    let titleLine: String
    let bodyMarkdown: String

    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label(L10n.t("预览提交内容", "Preview submission"), systemImage: "doc.text.magnifyingglass")
                    .font(.system(size: 14, weight: .semibold))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.t("标题", "Title"))
                    .font(.system(size: 10.5, weight: .bold))
                    .kerning(0.5)
                    .foregroundStyle(.tertiary)
                Text(titleLine)
                    .font(.system(size: 12, weight: .medium))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()
            ScrollView {
                // 整段渲染成一个 Text，鼠标能一次拖选全文（与 ResultSheet 日志同理）。
                Text(bodyMarkdown)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .background(Theme.bgCanvas)

            Divider()
            SheetActionBar {
                Text(L10n.t("这就是点「提交反馈」后会发出去的全部内容。",
                            "This is exactly what “Send” will submit."))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("\(titleLine)\n\n\(bodyMarkdown)", forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { copied = false }
                } label: {
                    Label(copied ? L10n.t("已复制", "Copied") : L10n.t("复制原文", "Copy text"),
                          systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .controlSize(.small)
            } trailing: {
                SheetCloseButton(title: L10n.t("关闭", "Close")) { dismiss() }
            }
        }
        .frame(width: 520, height: 460)
        .blanketDismiss { dismiss() }
        .presentationBackground(Theme.bgSurface)
        .frame(width: 600, height: 540)
    }
}

// MARK: - 反馈记录列表

/// 「反馈记录」入口打开的页面：展示历史反馈，可新建、可编辑、可删除、可清空。
///
/// 提交动作本身仍在 `FeedbackSheet`（弹层表单）。数据来自 `FeedbackStore`（本地 JSON）。
struct FeedbackHistorySheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [FeedbackEntry] = []
    @State private var showComposer = false
    @State private var editingEntry: FeedbackEntry? = nil
    @State private var showClearConfirm = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(L10n.t("反馈记录", "Feedback"), systemImage: "flag")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                if !entries.isEmpty {
                    Button(L10n.t("清空", "Clear all")) { showClearConfirm = true }
                        .controlSize(.small)
                }
                Button(L10n.t("新建反馈", "New feedback")) { showComposer = true }
                    .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            Divider()

            if entries.isEmpty {
                EmptyStateView(icon: "tray",
                               title: L10n.t("还没有反馈记录", "No feedback yet"),
                               message: L10n.t("遇到误报或风险等级判断错误时提交反馈，记录会留在这里，方便你回看。",
                                              "When you report a false positive or wrong risk level, the record stays here so you can review it."))
            } else {
                List {
                    ForEach(entries) { e in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(e.title)
                                    .font(.system(size: 12.5, weight: .medium))
                                    .textSelection(.enabled)
                                Spacer(minLength: 6)
                                Text(e.dateText)
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(.tertiary)
                            }
                            if let name = e.targetName {
                                Text(L10n.t("对象：", "Target: ") + name)
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(.secondary)
                            }
                            if !e.note.isEmpty {
                                Text(e.note)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                    .textSelection(.enabled)
                            }
                            HStack(spacing: 6) {
                                reasonTag(e.reason)
                                Text(e.channelLabel)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.tertiary)
                                Spacer(minLength: 0)
                                // 直接露出的操作按钮，不必依赖右键菜单。
                                Button {
                                    editingEntry = e
                                } label: {
                                    Image(systemName: "pencil")
                                        .font(.system(size: 11))
                                }
                                .buttonStyle(.plain)
                                .controlSize(.small)
                                .help(L10n.t("编辑这条反馈", "Edit this feedback"))
                                Button {
                                    FeedbackStore.shared.delete(e.id)
                                    entries = FeedbackStore.shared.all()
                                } label: {
                                    Image(systemName: "trash")
                                        .font(.system(size: 11))
                                }
                                .buttonStyle(.plain)
                                .controlSize(.small)
                                .help(L10n.t("删除这条反馈", "Delete this feedback"))
                            }
                        }
                        .padding(.vertical, 6)
                        .contextMenu {
                            Button {
                                editingEntry = e
                            } label: {
                                Label(L10n.t("编辑", "Edit"), systemImage: "pencil")
                            }
                            Button {
                                FeedbackStore.shared.delete(e.id)
                                entries = FeedbackStore.shared.all()
                            } label: {
                                Label(L10n.t("删除", "Delete"), systemImage: "trash")
                            }
                        }
                    }
                    .onDelete { idx in
                        guard let i = idx.first else { return }
                        FeedbackStore.shared.delete(entries[i].id)
                        entries = FeedbackStore.shared.all()
                    }
                }
                .listStyle(.inset)
            }
            Divider()
            SheetActionBar {
                EmptyView()
            } trailing: {
                SheetCloseButton(title: L10n.t("关闭", "Close")) { dismiss() }
            }
        }
        .frame(width: SheetPreset.historyList.width, height: SheetPreset.historyList.height)
        .onAppear { entries = FeedbackStore.shared.all() }
        .onChange(of: showComposer) { _, open in
            // 提交表单关闭后刷新列表，让新记录立刻出现。
            if !open { entries = FeedbackStore.shared.all() }
        }
        .onChange(of: editingEntry) { _, new in
            // 编辑 sheet 关闭（置 nil）后刷新。
            if new == nil { entries = FeedbackStore.shared.all() }
        }
        .sheet(isPresented: $showComposer) {
            FeedbackSheet(target: nil)
        }
        .sheet(item: $editingEntry) { e in
            FeedbackSheet(target: nil, editingEntry: e)
        }
        .alert(L10n.t("确认清空？", "Clear all feedback?"), isPresented: $showClearConfirm) {
            Button(L10n.t("取消", "Cancel"), role: .cancel) { }
            Button(L10n.t("清空", "Clear"), role: .destructive) {
                FeedbackStore.shared.clearAll()
                entries = FeedbackStore.shared.all()
            }
        } message: {
            Text(L10n.t("这将删除所有本地反馈记录，且不可恢复。", "This will delete all local feedback records. This cannot be undone."))
        }
        .blanketDismiss { dismiss() }
        .presentationBackground(Theme.bgSurface)
        .frame(width: SheetPreset.historyListOuter.width, height: SheetPreset.historyListOuter.height)
    }

    private func reasonTag(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .foregroundStyle(Theme.accentActive)
            .background(Theme.accentSubtle, in: Capsule())
            .overlay(Capsule().stroke(Theme.accentBorder, lineWidth: 1))
    }
}

// MARK: - 简易流式布局

/// 一行放不下就换行的横向排列。SwiftUI 没有内建的 flow layout，
/// 而反馈弹窗那四个中文标签在 520pt 宽度下必然要折行。
struct FlowRow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > maxWidth {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: maxWidth == .infinity ? x : maxWidth, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                x = bounds.minX
                y += lineHeight + spacing
                lineHeight = 0
            }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
