import SwiftUI

/// 「应用瘦身」tab：选一个已装 app，只清它的缓存 / 用户数据，不卸载、不退登录，
/// 给「微信 / 浏览器 / Xcode 这类占着几十 GB 缓存」的 app 一个安全的减肥入口。
///
/// 复用 `state.slim(app:mode:)` 扫描与 `RemovalExecutor` 清理，结果只含数据类项，
/// 用户数据默认进废纸篓（可恢复）。
struct SlimmingView: View {
    @EnvironmentObject var state: AppState
    @State private var selectedApp: AppIdentity?
    @State private var mode: SlimMode = .cacheOnly
    @State private var showCleanConfirm = false
    @State private var showCleanResult = false
    @State private var cleanedCount = 0
    @State private var searchText = ""

    private var isSlimming: Bool { state.isScanning }

    private var subtitle: String {
        if let app = state.matchedApp, state.slimMode != nil {
            return L10n.t("\(app.displayName) · \(state.slimMode?.title ?? "")",
                          "\(app.displayName) · \(state.slimMode?.title ?? "")")
        }
        return L10n.t("选一个应用，只清它的缓存与用户数据，不卸载应用",
                      "Pick an app and clear only its caches and user data — no uninstall")
    }

    private var filteredArtifacts: [Artifact] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let list = state.artifacts
        guard !q.isEmpty else { return list }
        return list.filter { a in
            a.path.lowercased().contains(q) || a.category.displayName.lowercased().contains(q)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { Task { await state.loadAppList() } }
        .alert(L10n.t("清理选中项", "Clean selected"),
               isPresented: $showCleanConfirm) {
            Button(L10n.t("取消", "Cancel"), role: .cancel) {}
            Button(L10n.t("开始清理 \(state.slimSelectedCount) 项",
                          "Clean \(state.slimSelectedCount) items"),
                   role: .destructive) {
                cleanedCount = state.runSlimCleanup()
                showCleanResult = true
            }
        } message: {
            var msg = L10n.t("将清理 \(state.slimSelectedCount) 项（约 \(SizeFormat.human(state.slimSelectedSize))）。用户数据会进废纸篓，可拖回恢复。",
                             "Will clean \(state.slimSelectedCount) items (~\(SizeFormat.human(state.slimSelectedSize))). User data goes to Trash and can be recovered.")
            if let warn = state.slimMode?.confirmWarning(appName: state.matchedApp?.displayName ?? "") {
                msg += "\n\n" + warn
            }
            return Text(msg)
        }
        .alert(L10n.t("已清理", "Cleaned up"),
               isPresented: $showCleanResult) {
            Button(L10n.t("好的", "OK"), role: .cancel) {}
        } message: {
            Text(L10n.t("成功清理 \(cleanedCount) 项，已自动重新扫描。",
                        "Cleaned up \(cleanedCount) item(s) and re-scanned automatically."))
        }
    }

    // MARK: - 头部

    private var header: some View {
        PageHeader(title: L10n.t("应用瘦身", "App slim"), subtitle: subtitle) {
            Button {
                Task { await scanSelected() }
            } label: {
                Label(state.matchedApp != nil && state.slimMode != nil
                      ? L10n.t("重新扫描", "Rescan")
                      : L10n.t("扫描", "Scan"),
                      systemImage: "arrow.clockwise")
            }
            .controlSize(.small)
            .disabled(selectedApp == nil || isSlimming)
        }
    }

    private func scanSelected() async {
        guard let app = selectedApp else { return }
        await state.slimApp(app, mode: mode)
    }

    // MARK: - 主体

    @ViewBuilder
    private var content: some View {
        if state.matchedApp != nil, state.slimMode != nil {
            slimResult
        } else if !state.fullDiskAccessGranted {
            GuidancePrompt(
                icon: "lock.shield",
                title: L10n.t("需要完全磁盘访问权限", "Full Disk Access needed"),
                detail: L10n.t("瘦身要读取 app 在用户目录里的缓存与数据，请先到系统设置授权，再回来扫描。",
                               "Slimming reads an app's caches and data in your user folder. Grant Full Disk Access in System Settings, then come back.")
            )
        } else {
            pickerArea
        }
    }

    // MARK: - 选择区

    private var pickerArea: some View {
        VStack(spacing: 16) {
            Image(systemName: "scissors")
                .font(.system(size: 46))
                .foregroundStyle(.tertiary)
            Text(L10n.t("给应用瘦个身", "Slim down an app"))
                .font(.title3)
            VStack(spacing: 4) {
                Text(L10n.t("挑一个「缓存 / 数据」越积越多的应用（微信、浏览器、Xcode…），只清它的可再生缓存与用户数据，应用本身和登录态都不动。",
                            "Pick an app whose caches/data keep piling up (WeChat, browsers, Xcode…). Only its rebuildable caches and user data are cleared; the app and your sign-in stay."))
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)

            VStack(spacing: 12) {
                HStack(spacing: 10) {
                    Text(L10n.t("应用", "App"))
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                    Picker(L10n.t("选择应用", "Choose an app"), selection: $selectedApp) {
                        Text(L10n.t("请选择…", "Choose…")).tag(AppIdentity?.none)
                        ForEach(state.allApps) { app in
                            Text(app.displayName).tag(AppIdentity?.some(app))
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 280)
                }
                HStack(spacing: 10) {
                    Text(L10n.t("档位", "Mode"))
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                    Picker("", selection: $mode) {
                        Text(SlimMode.cacheOnly.title).tag(SlimMode.cacheOnly)
                        Text(SlimMode.fullReset.title).tag(SlimMode.fullReset)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 360)
                }
                Button {
                    Task { await scanSelected() }
                } label: {
                    Label(L10n.t("扫描可清理项", "Scan for cleanables"), systemImage: "magnifyingglass")
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .disabled(selectedApp == nil)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - 结果区

    @ViewBuilder
    private var slimResult: some View {
        if isSlimming {
            VStack(spacing: 12) {
                ProgressView()
                Text(L10n.t("正在扫描 \(state.matchedApp?.displayName ?? "") 的缓存与数据…",
                            "Scanning \(state.matchedApp?.displayName ?? "")'s caches and data…"))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if state.artifacts.isEmpty {
            GuidancePrompt(
                icon: "checkmark.seal",
                title: L10n.t("已经很干净了", "Already clean"),
                detail: L10n.t("没找到这个档位下可清理的数据项。换个档位（如「彻底重置」）再试。",
                               "No cleanable data found for this mode. Try the other mode (Full reset).")
            )
        } else {
            VStack(spacing: 0) {
                if let app = state.matchedApp, let m = state.slimMode {
                    banner(app: app, mode: m)
                }
                Divider()
                resultControls
                Divider()
                resultList
                bottomBar
            }
        }
    }

    private func banner(app: AppIdentity, mode: SlimMode) -> some View {
        Text(mode.bannerText(appName: app.displayName))
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.bgCanvas)
    }

    private var resultControls: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.caption)
            TextField(L10n.t("搜索路径或类别…", "Search path or category…"), text: $searchText)
                .textFieldStyle(.plain).font(.callout)
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }.buttonStyle(.plain)
            }
            Spacer(minLength: 8)
            Text(L10n.t("\(state.artifacts.count) 项 · \(SizeFormat.human(state.artifacts.reduce(0){$0+$1.size}))",
                        "\(state.artifacts.count) items · \(SizeFormat.human(state.artifacts.reduce(0){$0+$1.size}))"))
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(Theme.bgCanvas)
    }

    private var resultList: some View {
        List {
            ForEach(filteredArtifacts) { a in
                HStack(alignment: .top, spacing: 8) {
                    Toggle("", isOn: Binding(
                        get: { state.artifacts.first(where: { $0.id == a.id })?.selected ?? false },
                        set: { _ in state.slimToggleSelected(a.id) }
                    ))
                    .labelsHidden()
                    .padding(.top, 3)

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text((a.path as NSString).lastPathComponent)
                                .font(.callout).lineLimit(1)
                            Text(a.category.displayName)
                                .font(.caption2).foregroundStyle(Theme.accent)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Theme.accentSubtle, in: RoundedRectangle(cornerRadius: 4))
                        }
                        Text((a.path as NSString).deletingLastPathComponent)
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(1).truncationMode(.middle)
                            .foregroundStyle(.secondary).textSelection(.enabled)
                        HStack(spacing: 6) {
                            Text(SizeFormat.human(a.size))
                                .font(.caption2.monospacedDigit())
                            if a.risk == .userData {
                                Text(L10n.t("用户数据", "user data"))
                                    .font(.caption2).foregroundStyle(Theme.riskUserDataText)
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(Theme.riskUserDataBg, in: RoundedRectangle(cornerRadius: 4))
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 3)
                .contentShape(Rectangle())
                .contextMenu {
                    Button(L10n.t("在访达中显示", "Reveal in Finder")) {
                        RevealService.revealInFinder(path: a.path)
                    }
                    Button(L10n.t("复制路径", "Copy path")) { RevealService.copyPath(a.path) }
                }
            }
        }
        .listStyle(.inset)
    }

    private var bottomBar: some View {
        BottomActionBar(
            selectedCount: state.slimSelectedCount,
            totalCount: state.artifacts.count,
            selectedSize: state.slimSelectedSize,
            hint: L10n.t("默认全选，用户数据进废纸篓", "All selected by default; user data goes to Trash"),
            onToggleAll: { on in state.slimSetAllSelected(on) }
        ) {
            Button {
                showCleanConfirm = true
            } label: {
                Label(L10n.t("清理选中…", "Clean selected…"), systemImage: "scissors")
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.success)
            .disabled(state.slimSelectedCount == 0)
            .help(state.slimSelectedCount == 0
                  ? L10n.t("先勾选要清理的项", "Select items first")
                  : L10n.t("清理选中项（用户数据进废纸篓）", "Clean selected items (user data goes to Trash)"))
        }
    }
}

/// 通用空态 / 引导提示（瘦身与端口等页面复用）。
private struct GuidancePrompt: View {
    let icon: String
    let title: String
    let detail: String
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 46))
                .foregroundStyle(.tertiary)
            Text(title).font(.title3)
            Text(detail)
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
