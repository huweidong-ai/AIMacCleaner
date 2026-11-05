import SwiftUI

/// 「启动项」tab：列出随登录 / 开机自启的 LaunchAgent / Daemon / 登录项，
/// 支持禁用（用户级重命名 .plist ↔ .plist.disabled）与移除（移到废纸篓）。
///
/// 安全取向：系统级条目需要管理员权限，操作失败会如实提示；登录项系统未开放
/// 稳定的禁用 API，仅展示。默认全不选、删除前二次确认。
struct StartupView: View {
    @EnvironmentObject var state: AppState
    @State private var showDisableConfirm = false
    @State private var showRemoveConfirm = false
    @State private var showResult = false
    @State private var resultMessage = ""
    @State private var searchText = ""

    private var subtitle: String {
        guard state.hasScannedStartup, !state.startupItems.isEmpty else {
            return L10n.t("找出随登录 / 开机自启的 Agent、Daemon 与登录项",
                          "Find agents, daemons and login items that start on login / boot")
        }
        let enabled = state.startupItems.filter { $0.isEnabled }.count
        return L10n.t("\(state.startupItems.count) 个启动项 · \(enabled) 个启用中",
                      "\(state.startupItems.count) startup items · \(enabled) enabled")
    }

    private var filtered: [StartupItem] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let list = state.startupItems
        guard !q.isEmpty else { return list }
        return list.filter { $0.label.lowercased().contains(q) || ($0.program?.lowercased().contains(q) ?? false) }
    }

    private var grouped: [(domain: StartupDomain, items: [StartupItem])] {
        StartupDomain.allCases.compactMap { d in
            let items = filtered.filter { $0.domain == d }
            return items.isEmpty ? nil : (d, items)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .alert(L10n.t("禁用所选启动项", "Disable selected"),
               isPresented: $showDisableConfirm) {
            Button(L10n.t("取消", "Cancel"), role: .cancel) {}
            Button(L10n.t("禁用 \(state.startupItems.filter { $0.selected && $0.domain.manageable }.count) 项",
                          "Disable \(state.startupItems.filter { $0.selected && $0.domain.manageable }.count)"),
                   role: .destructive) { runDisable() }
        } message: {
            Text(L10n.t("将把选中的启动项重命名为 .disabled，下次开机不再加载。系统级条目若没有管理员权限会失败。",
                        "Selected items will be renamed to .disabled and won't load on next boot. System items may fail without admin rights."))
        }
        .alert(L10n.t("移除所选启动项", "Remove selected"),
               isPresented: $showRemoveConfirm) {
            Button(L10n.t("取消", "Cancel"), role: .cancel) {}
            Button(L10n.t("移到废纸篓 \(state.startupItems.filter { $0.selected && $0.domain.manageable }.count) 项",
                          "Trash \(state.startupItems.filter { $0.selected && $0.domain.manageable }.count)"),
                   role: .destructive) { runRemove() }
        } message: {
            Text(L10n.t("将把选中的启动项移到废纸篓。系统级条目若没有管理员权限会失败。",
                        "Selected items will be moved to Trash. System items may fail without admin rights."))
        }
        .alert(L10n.t("操作结果", "Result"), isPresented: $showResult) {
            Button(L10n.t("好的", "OK"), role: .cancel) {}
        } message: {
            Text(resultMessage)
        }
    }

    private var header: some View {
        PageHeader(title: L10n.t("启动项", "Startup"), subtitle: subtitle) {
            Button {
                Task { await state.scanStartupItems() }
            } label: {
                Label(state.hasScannedStartup
                      ? L10n.t("重新扫描", "Rescan")
                      : L10n.t("开始扫描", "Scan"),
                      systemImage: "arrow.clockwise")
            }
            .controlSize(.small)
            .disabled(state.isScanningStartup)
        }
    }

    @ViewBuilder
    private var content: some View {
        if state.isScanningStartup {
            VStack(spacing: 12) {
                ProgressView()
                Text(L10n.t("正在扫描 LaunchAgents / Daemons 与登录项…",
                            "Scanning LaunchAgents, Daemons and login items…"))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !state.hasScannedStartup {
            VStack(spacing: 14) {
                Image(systemName: "power")
                    .font(.system(size: 48))
                    .foregroundStyle(.tertiary)
                Text(L10n.t("开机越来越慢？", "Slow to boot?"))
                    .font(.title3)
                VStack(spacing: 4) {
                    Text(L10n.t("列出随你登录 / 开机自动启动的 Agent 与 Daemon，挑着禁用或移除，加快开机、减少后台占用。",
                                "List the agents and daemons that auto-start on login/boot. Disable or remove the ones you don't need."))
                }
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button {
                    Task { await state.scanStartupItems() }
                } label: {
                    Label(L10n.t("开始扫描", "Start scan"), systemImage: "magnifyingglass")
                }
                .controlSize(.large).buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        } else if state.startupItems.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "checkmark.seal")
                    .font(.system(size: 48))
                    .foregroundStyle(.green.opacity(0.7))
                Text(L10n.t("没有发现启动项", "No startup items found"))
                    .font(.title3)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                controls
                Divider()
                list
                bottomBar
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.caption)
            TextField(L10n.t("搜索名称或程序…", "Search by name or program…"), text: $searchText)
                .textFieldStyle(.plain).font(.callout)
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }.buttonStyle(.plain)
            }
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Theme.bgCanvas)
    }

    private var list: some View {
        List {
            ForEach(grouped, id: \.domain) { group in
                Section {
                    ForEach(group.items) { item in
                        StartupRow(item: item, searchText: searchText) { id, enabled in
                            if !state.setStartupItemEnabled(id, enabled: enabled) {
                                resultMessage = L10n.t("操作失败：系统级条目需要管理员权限。可在终端用 sudo launchctl 或手动移动文件。",
                                                      "Failed: system items need admin rights. Use sudo launchctl in Terminal or move the file manually.")
                                showResult = true
                            }
                        } onRemove: { id in
                            if !state.removeStartupItem(id) {
                                resultMessage = L10n.t("移除失败：系统级条目需要管理员权限。可在终端用 sudo 或手动移到废纸篓。",
                                                      "Remove failed: system items need admin rights. Use sudo in Terminal or move manually.")
                                showResult = true
                            }
                        }
                    }
                } header: {
                    HStack(spacing: 6) {
                        Text(group.domain.displayName)
                        Text("\(group.items.count)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .listStyle(.inset)
    }

    private var bottomBar: some View {
        let manageableSelected = state.startupItems.filter { $0.selected && $0.domain.manageable }.count
        return BottomActionBar(
            selectedCount: manageableSelected,
            totalCount: state.startupItems.filter { $0.domain.manageable }.count,
            selectedSize: 0,
            hint: L10n.t("登录项仅展示；系统项需管理员权限", "Login items are read-only; system items need admin"),
            onToggleAll: { on in state.setAllStartupSelected(on) }
        ) {
            HStack(spacing: 10) {
                Button {
                    showDisableConfirm = true
                } label: {
                    Label(L10n.t("禁用所选", "Disable"), systemImage: "pause.circle")
                }
                .controlSize(.small)
                .disabled(manageableSelected == 0)
                Button {
                    showRemoveConfirm = true
                } label: {
                    Label(L10n.t("移除所选", "Remove"), systemImage: "trash")
                }
                .controlSize(.small)
                .tint(Theme.destructive)
                .disabled(manageableSelected == 0)
            }
        }
    }

    private func runDisable() {
        let n = state.applyStartupEnabled(false)
        resultMessage = n > 0
            ? L10n.t("已禁用 \(n) 个启动项（重命名为 .disabled）。", "Disabled \(n) item(s) (renamed to .disabled).")
            : L10n.t("没有成功禁用任何项。系统级条目需管理员权限。", "None disabled. System items need admin rights.")
        showResult = true
    }

    private func runRemove() {
        let n = state.removeSelectedStartupItems()
        resultMessage = n > 0
            ? L10n.t("已把 \(n) 个启动项移到废纸篓。", "Moved \(n) item(s) to Trash.")
            : L10n.t("没有成功移除任何项。系统级条目需管理员权限。", "None removed. System items need admin rights.")
        showResult = true
    }
}

/// 单个启动项行。
private struct StartupRow: View {
    let item: StartupItem
    let searchText: String
    let onToggleEnabled: (UUID, Bool) -> Void
    let onRemove: (UUID) -> Void
    @EnvironmentObject var state: AppState

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Toggle("", isOn: Binding(
                get: { state.startupItems.first(where: { $0.id == item.id })?.selected ?? false },
                set: { _ in state.toggleStartupSelected(item.id) }
            ))
            .labelsHidden()
            .disabled(!item.domain.manageable)
            .padding(.top, 3)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.label)
                        .font(.callout)
                        .lineLimit(1)
                    DomainPill(domain: item.domain)
                    if !item.isEnabled {
                        Text(L10n.t("已禁用", "Disabled"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                    }
                }
                if let prog = item.program, !prog.isEmpty {
                    Text(prog)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 0)

            // 操作按钮（仅可管理项）
            if item.domain.manageable {
                HStack(spacing: 6) {
                    if !item.path.isEmpty {
                        Button {
                            RevealService.revealInFinder(path: item.path)
                        } label: {
                            Image(systemName: "folder").font(.system(size: 12))
                        }
                        .buttonStyle(.plain)
                        .help(L10n.t("在访达中显示", "Reveal in Finder"))
                    }
                    Button {
                        onToggleEnabled(item.id, !item.isEnabled)
                    } label: {
                        Image(systemName: item.isEnabled ? "pause.circle" : "play.circle")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.plain)
                    .help(item.isEnabled ? L10n.t("禁用", "Disable") : L10n.t("启用", "Enable"))
                    Button {
                        onRemove(item.id)
                    } label: {
                        Image(systemName: "trash").font(.system(size: 12))
                    }
                    .buttonStyle(.plain)
                    .help(L10n.t("移除（移到废纸篓）", "Remove (to Trash)"))
                }
                .foregroundStyle(Theme.accent)
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }
}

private struct DomainPill: View {
    let domain: StartupDomain
    private var color: Color {
        switch domain {
        case .userAgent:   return Theme.accent
        case .systemAgent: return Theme.warning
        case .systemDaemon:return Theme.riskUserDataText
        case .loginItem:   return Color.secondary
        }
    }
    var body: some View {
        Text(domain.displayName)
            .font(.caption2)
            .foregroundStyle(color)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
    }
}
