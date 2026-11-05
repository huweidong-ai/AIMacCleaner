import SwiftUI

/// 「端口」tab：列出当前监听的 TCP 端口，显示占用进程与路径，一键结束占用进程，
/// 方便排查「端口被谁占了 / 某个服务起不来」。
///
/// 安全取向：默认全不选、结束前二次确认；系统关键进程不可杀由 ProcessTerminator 兜底。
struct PortsView: View {
    @EnvironmentObject var state: AppState
    @State private var showKillConfirm = false
    @State private var showKillResult = false
    @State private var killedCount = 0
    @State private var searchText = ""

    private var subtitle: String {
        guard state.hasScannedPorts, !state.listeningPorts.isEmpty else {
            return L10n.t("列出正在监听的端口与占用进程", "List listening ports and the processes holding them")
        }
        return L10n.t("\(state.listeningPorts.count) 个监听端口",
                      "\(state.listeningPorts.count) listening ports")
    }

    private var filtered: [ListeningPort] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let list = state.listeningPorts
        guard !q.isEmpty else { return list }
        return list.filter { p in
            "\(p.port)".contains(q)
                || p.command.lowercased().contains(q)
                || p.address.lowercased().contains(q)
                || (p.programPath?.lowercased().contains(q) ?? false)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .alert(L10n.t("结束占用进程", "End processes"),
               isPresented: $showKillConfirm) {
            Button(L10n.t("取消", "Cancel"), role: .cancel) {}
            Button(L10n.t("结束 \(state.selectedPortIds.count) 个进程",
                          "End \(state.selectedPortIds.count) processes"),
                   role: .destructive) {
                killedCount = state.killSelectedPortProcesses()
                showKillResult = true
            }
        } message: {
            Text(L10n.t("将结束选中端口占用的 \(state.selectedPortIds.count) 个进程以释放端口。未保存的工作会丢失，且无法撤销。",
                          "This ends the \(state.selectedPortIds.count) processes holding the selected ports to free them. Unsaved work will be lost and this cannot be undone."))
        }
        .alert(L10n.t("已结束进程", "Processes ended"),
               isPresented: $showKillResult) {
            Button(L10n.t("好的", "OK"), role: .cancel) {}
        } message: {
            Text(L10n.t("成功结束 \(killedCount) 个进程，已自动重新扫描。",
                        "Successfully ended \(killedCount) process(es) and re-scanned automatically."))
        }
    }

    private var header: some View {
        PageHeader(title: L10n.t("端口", "Ports"), subtitle: subtitle) {
            Button {
                Task { await state.scanPorts() }
            } label: {
                Label(state.hasScannedPorts
                      ? L10n.t("重新扫描", "Rescan")
                      : L10n.t("开始扫描", "Scan"),
                      systemImage: "arrow.clockwise")
            }
            .controlSize(.small)
            .disabled(state.isScanningPorts)
        }
    }

    @ViewBuilder
    private var content: some View {
        if state.isScanningPorts {
            VStack(spacing: 12) {
                ProgressView()
                Text(L10n.t("正在枚举监听端口…", "Enumerating listening ports…"))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !state.hasScannedPorts {
            VStack(spacing: 14) {
                Image(systemName: "cable.connector")
                    .font(.system(size: 48))
                    .foregroundStyle(.tertiary)
                Text(L10n.t("端口被占用了？", "Port taken?"))
                    .font(.title3)
                VStack(spacing: 4) {
                    Text(L10n.t("列出当前正在监听的 TCP 端口和对应进程，看看是谁占着 8080、谁的服务起不来，一键结束。",
                                "List the TCP ports currently listening and their processes — see who holds 8080 or why a service won't start, then end it."))
                }
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button {
                    Task { await state.scanPorts() }
                } label: {
                    Label(L10n.t("开始扫描", "Start scan"), systemImage: "magnifyingglass")
                }
                .controlSize(.large).buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        } else if state.listeningPorts.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "checkmark.seal")
                    .font(.system(size: 48))
                    .foregroundStyle(.green.opacity(0.7))
                Text(L10n.t("没有监听端口", "No listening ports"))
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
            TextField(L10n.t("搜索端口号 / 进程名 / 地址…", "Search port / process / address…"),
                      text: $searchText)
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
            ForEach(filtered) { p in
                HStack(alignment: .top, spacing: 8) {
                    Toggle("", isOn: Binding(
                        get: { state.selectedPortIds.contains(p.id) },
                        set: { _ in state.togglePortSelected(p.id) }
                    ))
                    .labelsHidden()
                    .padding(.top, 3)

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(":\(p.port)").font(.callout.monospacedDigit())
                            Text(p.proto).font(.caption2).foregroundStyle(Theme.accent)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Theme.accentSubtle, in: RoundedRectangle(cornerRadius: 4))
                            Text(p.address.isEmpty ? "*" : p.address)
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        HStack(spacing: 6) {
                            Text(p.command).font(.callout).lineLimit(1)
                            Text("PID \(p.pid)")
                                .font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                            Text("·").foregroundStyle(.tertiary)
                            Text(p.user).font(.caption2).foregroundStyle(.tertiary)
                        }
                        if let path = p.programPath, !path.isEmpty {
                            Text(path)
                                .font(.system(.caption, design: .monospaced))
                                .lineLimit(1).truncationMode(.middle)
                                .foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                    Spacer(minLength: 0)

                    Button {
                        RevealService.revealInFinder(path: p.programPath ?? "")
                    } label: {
                        Image(systemName: "folder").font(.system(size: 12))
                    }
                    .buttonStyle(.plain)
                    .help(L10n.t("在访达中显示", "Reveal in Finder"))
                    .disabled(p.programPath?.isEmpty ?? true)
                }
                .padding(.vertical, 3)
                .contentShape(Rectangle())
                .contextMenu {
                    if let path = p.programPath, !path.isEmpty {
                        Button(L10n.t("复制路径", "Copy path")) { RevealService.copyPath(path) }
                    }
                }
            }
        }
        .listStyle(.inset)
    }

    private var bottomBar: some View {
        let total = state.listeningPorts.count
        return BottomActionBar(
            selectedCount: state.selectedPortIds.count,
            totalCount: total,
            selectedSize: 0,
            hint: L10n.t("默认全不选，结束前确认", "Nothing selected by default; confirm before ending"),
            onToggleAll: { on in state.setAllPortsSelected(on) }
        ) {
            Button {
                showKillConfirm = true
            } label: {
                Label(L10n.t("结束所选进程…", "End selected…"), systemImage: "xmark.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.destructive)
            .disabled(state.selectedPortIds.isEmpty)
            .help(state.selectedPortIds.isEmpty
                  ? L10n.t("先勾选要结束的进程", "Select processes first")
                  : L10n.t("结束选中端口占用的进程（二次确认）", "End the processes holding selected ports (with confirmation)"))
        }
    }
}
