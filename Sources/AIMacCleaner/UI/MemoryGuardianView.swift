import SwiftUI

/// 「内存守卫」常驻状态条：挂在「进程」页顶部，一眼看到守卫开着没、拦不拦得住。
/// 点齿轮进 `MemoryGuardianSheet` 配置。
struct MemoryGuardianBar: View {
    @ObservedObject private var guardian = MemoryGuardian.shared
    @State private var showSheet = false

    private var subtitle: String {
        guard guardian.isRunning else {
            return L10n.t("已关闭——内存泄漏时无法保护系统", "Off — the system is unprotected against memory leaks")
        }
        let gb = SizeFormat.human(guardian.thresholdBytes)
        switch guardian.mode {
        case .notify:
            return L10n.t("监控中 · 单进程 ≥ \(gb) 持续 1 分钟将提醒你", "Watching · notify if a process ≥ \(gb) for 1 min")
        case .autoKill:
            return L10n.t("监控中 · 单进程 ≥ \(gb) 持续 1 分钟将自动结束", "Watching · auto-end if a process ≥ \(gb) for 1 min")
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: guardian.isRunning ? "shield.lefthalf.filled" : "shield.slash")
                .font(.system(size: 15))
                .foregroundStyle(guardian.isRunning ? Theme.accent : .secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.t("内存守卫", "Memory Guardian"))
                    .font(.system(size: 12.5, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { guardian.isEnabled },
                set: { on in
                    guardian.isEnabled = on
                    if on { guardian.requestNotificationPermission() }
                    guardian.applySettings()
                }
            ))
            .labelsHidden()
            .controlSize(.small)

            Button {
                showSheet = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .help(L10n.t("内存守卫设置", "Memory Guardian settings"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Theme.bgSurface, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.divider, lineWidth: 1))
        .sheet(isPresented: $showSheet) {
            MemoryGuardianSheet()
        }
    }
}

/// 内存守卫设置面板：开关、处理方式、阈值、白名单、最近事件。
struct MemoryGuardianSheet: View {
    @ObservedObject private var guardian = MemoryGuardian.shared
    @Environment(\.dismiss) private var dismiss
    @State private var newWhitelistName = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    explanation
                    modeSection
                    thresholdSection
                    whitelistSection
                    if !guardian.events.isEmpty { eventsSection }
                }
                .padding(16)
            }
            Divider()
            SheetActionBar {
                EmptyView()
            } trailing: {
                SheetCloseButton(title: L10n.t("完成", "Done")) { dismiss() }
            }
        }
        .frame(width: 560, height: 560)
        .presentationBackground(Theme.bgSurface)
    }

    // MARK: - 头部

    private var header: some View {
        HStack {
            Label(L10n.t("内存守卫", "Memory Guardian"), systemImage: "shield.lefthalf.filled")
                .font(.system(size: 14, weight: .semibold))
            Spacer()
            Toggle(L10n.t("启用", "Enabled"), isOn: Binding(
                get: { guardian.isEnabled },
                set: { on in
                    guardian.isEnabled = on
                    if on { guardian.requestNotificationPermission() }
                    guardian.applySettings()
                }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - 说明

    private var explanation: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.t("为什么需要它", "Why this exists"))
                .font(.system(size: 12, weight: .semibold))
            Text(L10n.t("""
                某些应用（如微信）出现过单进程内存涨到 98 GB 的泄漏，macOS 拼命换页硬撑，\
                系统僵死到强制退出都点不动、只能重启。守卫在系统还能响应时提前动手，\
                把灾难降级成「重启一下那个应用」。
                """, """
                Some apps (e.g. WeChat) have leaked up to 98 GB in a single process — macOS \
                swaps itself to death and the whole machine freezes. The Guardian steps in \
                while the system can still respond, turning disaster into "just reopen the app".
                """))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.bgCanvas, in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - 处理方式

    private var modeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.t("发现异常后", "When an anomaly is found"))
                .font(.system(size: 12, weight: .semibold))
            Picker("", selection: Binding(
                get: { guardian.mode },
                set: { guardian.mode = $0 }
            )) {
                ForEach(MemoryGuardian.ActionMode.allCases) { m in
                    Text(m.displayName).tag(m)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()

            Text(L10n.t(
                "「自动结束」会先尝试正常退出，再强制结束；聊天记录等云端数据不受影响，但未保存的本地工作会丢失。",
                "「End automatically」first tries a graceful quit, then force-ends. Cloud-synced data is safe; unsaved local work is lost."))
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 阈值

    private var thresholdSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L10n.t("异常阈值", "Threshold"))
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(L10n.t("单进程 ≥ \(SizeFormat.human(guardian.thresholdBytes))（物理内存的 \(guardian.thresholdPercent)%）",
                            "A process ≥ \(SizeFormat.human(guardian.thresholdBytes)) (\(guardian.thresholdPercent)% of RAM)"))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.accent)
            }
            Slider(value: Binding(
                get: { Double(guardian.thresholdPercent) },
                set: { guardian.thresholdPercent = Int($0) }
            ), in: 10...90, step: 5)
            Text(L10n.t("持续 1 分钟（连续 2 次采样）超阈值才动手，编译、AI 推理等正常峰值不会误触发。",
                        "Only sustained (2 samples ≈ 1 min) breaches trigger action — normal builds and AI inference peaks won't."))
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 白名单

    private var whitelistSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.t("白名单（这些进程永不处理）", "Whitelist (never touched)"))
                .font(.system(size: 12, weight: .semibold))
            HStack(spacing: 8) {
                TextField(L10n.t("进程名，如 Xcode、node…", "Process name, e.g. Xcode, node…"),
                          text: $newWhitelistName)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .onSubmit(addWhitelist)
                Button(L10n.t("添加", "Add"), action: addWhitelist)
                    .controlSize(.small)
                    .disabled(newWhitelistName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if !guardian.whitelist.isEmpty {
                ForEach(guardian.whitelist, id: \.self) { name in
                    HStack {
                        Text(name)
                            .font(.system(size: 11.5, design: .monospaced))
                        Spacer()
                        Button {
                            guardian.whitelist.removeAll { $0 == name }
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 11))
                        }
                        .buttonStyle(.plain)
                        .help(L10n.t("移除", "Remove"))
                    }
                    .padding(.vertical, 2)
                }
            } else {
                Text(L10n.t("暂无。系统进程、关键进程与本应用始终受保护，无需添加。",
                            "None. System, critical and this app's processes are always protected."))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func addWhitelist() {
        let name = newWhitelistName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        if !guardian.whitelist.contains(where: { $0.lowercased() == name.lowercased() }) {
            guardian.whitelist.append(name)
        }
        newWhitelistName = ""
    }

    // MARK: - 最近事件

    private var eventsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.t("最近事件", "Recent events"))
                .font(.system(size: 12, weight: .semibold))
            ForEach(guardian.events) { e in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(Self.timeText(e.date))
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    Text(e.processName)
                        .font(.system(size: 11.5))
                        .lineLimit(1)
                    Text(SizeFormat.human(e.memoryBytes))
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(e.action.displayName)
                        .font(.system(size: 10.5))
                        .foregroundStyle(color(for: e.action))
                }
            }
        }
    }

    private func color(for action: MemoryGuardian.EventAction) -> Color {
        switch action {
        case .killed:     return Theme.success
        case .notified:   return Theme.warning
        case .killFailed: return Theme.destructive
        case .skipped:    return .secondary
        }
    }

    private static func timeText(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss"
        return f.string(from: date)
    }
}
