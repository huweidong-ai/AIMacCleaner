import SwiftUI
import AppKit

/// 「应用」页：左侧已装 app 列表 + 搜索，右侧扫描结果与卸载操作。
///
/// v1.6 起合并了原来的「扫描」tab —— 两者的差别只有左侧面板，
/// 却让用户要先想清楚「我是要搜还是要浏览」。现在搜索框就在列表上方，
/// 输入即过滤左侧已装应用列表，回车不再触发关键词全盘扫描。
struct AppsView: View {
    @EnvironmentObject var state: AppState
    @State private var showConfirm = false
    @State private var showResult = false
    @State private var showFeedback = false
    @State private var executorOutput: [String] = []
    @State private var showSelfUninstalled = false
    @State private var showSettings = false

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(
                title: L10n.t("应用", "Apps"),
                subtitle: L10n.t("从列表选择应用，或在搜索框输入名称过滤",
                                 "Pick an app from the list, or type a name to filter")
            ) {
                Button {
                    state.invalidateInventory()
                } label: {
                    Label(L10n.t("刷新清单", "Refresh"), systemImage: "arrow.clockwise")
                }
                .controlSize(.small)
            }
            Divider()
            HSplitView {
                appListPane
                    .frame(minWidth: 230, idealWidth: 270, maxWidth: 360)
                resultPane
                    .frame(minWidth: 440, maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task { await state.loadAppList() }
        // AI 复核结束后展开全部分组，方便用户查看每一类 AI 写下的评语。
        .onChange(of: state.aiReviewPhaseApps) { _, phase in
            if phase == .done { state.appsCollapsed = [] }
        }
        // 换了扫描目标就把上一轮 AI 结论清掉，否则会显示上一个 app 的判断。
        .onChange(of: state.matchedApp?.bundlePath) { _, _ in state.aiReviewPhaseApps = .idle }
        // 用退格键把搜索框删空，语义上等同于点 x：右侧回到首屏空态。
        // 守卫 artifacts 非空，既避免重复清、也断掉 clear() 再次触发本回调的递归。
        .onChange(of: state.searchText) { _, newValue in
            let q = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if q.isEmpty && !state.artifacts.isEmpty {
                state.clear()
                state.aiReviewPhaseApps = .idle
            }
        }
        .sheet(isPresented: $showConfirm) {
            ConfirmSheet(title: L10n.t("确认卸载", "Confirm uninstall"),
                         artifacts: state.artifacts.filter(\.selected)) { userData in
                runUninstall(userData: userData)
            }
        }
        .sheet(isPresented: $showResult) {
            ResultSheet(output: executorOutput,
                        successCount: state.lastResult?.successCount ?? 0,
                        failureCount: state.lastResult?.failureCount ?? 0,
                        manualCount: state.lastResult?.manualCount ?? 0,
                        freedBytes: state.lastResult?.record.freedBytes ?? 0,
                        trashedBytes: state.lastResult?.record.trashedBytes ?? 0)
        }
        .sheet(isPresented: $showFeedback) {
            FeedbackSheet(target: state.artifacts.first)
        }
        .sheet(isPresented: $showSettings) {
            AIModelSettingsSheet()
        }
        .alert(L10n.t("AI Mac Cleaner 已卸载", "AI Mac Cleaner uninstalled"),
               isPresented: $showSelfUninstalled) {
            Button(L10n.t("退出 AI Mac Cleaner", "Quit AI Mac Cleaner")) {
                Self.cleanupSelfPreferences()
                NSApp.terminate(nil)
            }
        } message: {
            Text(L10n.t("应用已移到废纸篓。清空废纸篓即可彻底移除本程序。",
                        "The app has been moved to the Trash. Empty the Trash to remove it completely."))
        }
    }

    // MARK: - 左：搜索 + app 列表

    private var appListPane: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()
            HStack {
                Text(L10n.t("已安装 · \(state.allApps.count)", "Installed · \(state.allApps.count)"))
                Spacer()
                if !state.searchText.isEmpty {
                    Text(L10n.t("匹配 \(state.filteredApps.count)", "\(state.filteredApps.count) matched"))
                }
            }
            .font(.system(size: 10.5))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(Theme.bgCanvas)
            Divider()

            if state.isLoadingApps && state.allApps.isEmpty {
                VStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(L10n.t("读取已装 app…", "Reading installed apps…"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                appList
            }
        }
        .background(Theme.bgSurface)
    }

    private var appList: some View {
        List(selection: Binding(
            get: { state.matchedApp?.bundlePath },
            set: { path in
                guard let path, let app = state.allApps.first(where: { $0.bundlePath == path }) else { return }
                Task { await state.scan(app: app) }
            }
        )) {
            ForEach(state.filteredApps) { app in
                HStack(spacing: 8) {
                    if let icon = AppIconLoader.icon(forBundlePath: app.bundlePath) {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 26, height: 26)
                    } else {
                        Image(systemName: "app.dashed")
                            .frame(width: 26, height: 26)
                            .foregroundStyle(.tertiary)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(app.displayName)
                            .font(.system(size: 12.5))
                            .lineLimit(1)
                        HStack(spacing: 4) {
                            if let v = app.version { Text("v\(v)") }
                            if let bid = app.bundleId {
                                Text("· \(bid)").lineLimit(1).truncationMode(.middle)
                            }
                        }
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 2)
                .tag(app.bundlePath)
                .help(app.bundlePath)
            }
        }
        .listStyle(.sidebar)
    }

    private var searchBar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 11))
                // 搜索框只负责过滤左侧已装应用列表；
                // 不再支持回车按关键词全盘扫描系统/CLI 工具。
                TextField(L10n.t("搜索应用", "Search apps"),
                          text: $state.searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                if !state.searchText.isEmpty {
                    // 只置空 searchText 不够：右侧还留着上一轮结果、侧栏还在报可回收量。
                    // clear() 一次把「回到首屏」需要的状态全清掉。
                    Button {
                        state.clear()
                        state.aiReviewPhaseApps = .idle
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 26)
            .background(Theme.bgCanvas, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.divider, lineWidth: 1))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    // MARK: - 右：扫描结果

    /// 右侧是否有结果可展示。
    ///
    /// 除了「没结果」，还要挡住「搜索框已空但异步扫描才刚回来」这一帧 ——
    /// 用户已经清空了输入，结果不该自己冒出来。
    private var hasVisibleResults: Bool {
        !state.artifacts.isEmpty
            && !state.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @ViewBuilder
    private var resultPane: some View {
        if state.isScanning {
            VStack(spacing: 12) {
                ProgressView()
                Text(L10n.t("正在调用 \(state.scanners.count) 个扫描器…",
                            "Running \(state.scanners.count) scanners…"))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !hasVisibleResults {
            scannerShowcase
        } else {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        summaryCard
                        if !state.artifacts.isEmpty {
                            aiBar
                        }
                        SectionLabel(text: L10n.t("扫描结果 · 按类别分组", "Results · grouped by category"),
                                     onExpand: { expandAllCategories(expanded: true) },
                                     onCollapse: { expandAllCategories(expanded: false) })
                        groupCards
                    }
                    .padding(16)
                }
                .background(Theme.bgCanvas)
                bottomBar
            }
        }
    }

    private var summaryCard: some View {
        HStack(spacing: 13) {
            if let app = state.matchedApp,
               let icon = AppIconLoader.icon(forBundlePath: app.bundlePath) {
                Image(nsImage: icon).resizable().frame(width: 44, height: 44)
            } else {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Theme.accentSubtle)
                    .frame(width: 44, height: 44)
                    .overlay(Image(systemName: "terminal").foregroundStyle(Theme.accent))
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(state.plan?.targetName ?? state.searchText)
                    .font(.system(size: 15, weight: .semibold))
                if let app = state.matchedApp {
                    Text([app.bundleId, app.version.map { L10n.t("版本 \($0)", "version \($0)") }]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Text(app.bundlePath)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 8)

            HStack(spacing: 16) {
                metric(value: "\(state.artifacts.count)", label: L10n.t("关联项", "Items"), tint: .primary)
                metric(value: SizeFormat.human(state.totalSelectedSize),
                       label: L10n.t("可回收", "Reclaimable"), tint: Theme.accent)
            }
        }
        .padding(14)
        .background(Theme.bgSurface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.divider, lineWidth: 1))
        .overlay(alignment: .topTrailing) {
            // 同名候选切换：搜「微信」可能想删微信，也可能想删微信开发者工具，
            // 不该由我们替他猜死。
            if state.ambiguousMatches.count > 1 {
                Menu {
                    ForEach(state.ambiguousMatches) { app in
                        Button(app.displayName) { Task { await state.scan(app: app) } }
                    }
                } label: {
                    Label(L10n.t("\(state.ambiguousMatches.count) 个同名", "\(state.ambiguousMatches.count) matches"),
                          systemImage: "arrow.triangle.branch")
                        .font(.system(size: 10.5))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .padding(8)
            }
        }
    }

    private func metric(value: String, label: String, tint: Color) -> some View {
        VStack(spacing: 1) {
            Text(value)
                .font(.system(size: 16, weight: .semibold, design: .monospaced))
                .foregroundStyle(tint)
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
    }

    private var aiBar: some View {
        let (title, detail) = aiBarText
        return AIReviewBar(
            phase: state.aiReviewPhaseApps,
            title: title,
            detail: detail,
            actionTitle: L10n.t("让 AI 分析", "Ask AI"),
            onReview: {
                guard state.modelStore.isConfigured else {
                    state.aiReviewPhaseApps = .needsConfig
                    return
                }
                // 不再原地跑复核，改为深链到「问 AI」页：预填诊断问句，复用 review_plan
                // skill 回写勾选与理由，过程在对话里可见、可追加追问。
                // 复核范围是「当前这个应用扫出来的全部项」，与右侧勾选状态无关——
                // 勾选只是为了最后卸载时决定删哪些，不该缩小 AI 的复核视野。
                // reviewScope: .apps 强制让 review_plan 走 apps 分支，避免被误判成残留。
                // 同时把当前清单直接写进问句：模型看不到 session 注入，必须显式给清单，
                // 否则它不知道具体路径，会重复扫描或反问用户。
                let appName = state.matchedApp?.displayName
                    ?? (state.searchText.isEmpty ? L10n.t("当前应用", "the current app") : state.searchText)
                let list = AgentFormat.promptList(state.artifacts)
                state.jumpToAskAI(L10n.t(
                    "我打算卸载已安装应用 \(appName)。下面是扫描器找出的全部相关文件/目录清单：\n\(list)\n\n请帮我完成三件事：\n1. 逐项确认清单中的文件/目录是否确实属于 \(appName)（主程序、用户数据、缓存），还是被扫描器误识别——例如其实是系统级文件、或属于其他已装应用、或别的 App 正在引用/共享它。\n2. 评估删除每一项的风险。重点不是「会不会让 \(appName) 无法使用」（卸载本身就是目的），而是：它是否属于系统级文件/目录、删除会否破坏系统稳定性；是否被其他应用引用或共享、删除会否导致别的 App 瘫痪；是否属于重要用户数据（凭据、登录态、项目文件等）、删了是否不可逆或需要人工确认。\n3. 给出最终建议：每一项是「可安全删除」还是「建议保留 / 需人工确认」，并说明原因。对「建议保留」的项，务必点明它为什么不能删（系统文件 / 其他应用共享 / 重要数据）。\n\n清单已经给出，不要重新扫描，请直接调用 review_plan(scope: apps) 把结论标记出来。",
                    "I plan to uninstall the installed app \(appName). Below is the full list of related files/directories the scanner found:\n\(list)\n\nPlease do three things:\n1. For each item, confirm whether it truly belongs to \(appName) (main bundle, user data, cache), or is a false positive — e.g. actually a system-level file, belongs to another installed app, or is referenced/shared by another app.\n2. Assess the risk of deleting each item. The point is NOT whether it breaks \(appName) (uninstalling is the goal) — instead: is it a system-level file whose deletion destabilizes the OS; is it referenced/shared by other apps whose deletion would break them; is it important user data (credentials, login state, project files) that is irreversible or needs a human decision.\n3. Give a final recommendation per item: \"safe to delete\" or \"keep / needs human confirmation\", with the reason. For \"keep\" items, state explicitly why it must not be deleted (system file / shared by other apps / important data).\n\nThe list is already provided — do not scan again. Call review_plan(scope: apps) directly to mark the verdicts."),
                    reviewScope: .apps)
            },
            onUndo: {
                state.undoAIReview()
                state.aiReviewPhaseApps = .idle
            },
            onConfigure: { showSettings = true }
        )
    }

    /// 按当前阶段给出提示文案。
    private var aiBarText: (String, String) {
        switch state.aiReviewPhaseApps {
        case .done:
            return (L10n.t("AI 已分析完毕。", "AI analysis complete."),
                    L10n.t("被判为不建议删除的项已自动取消勾选，理由写在对应行下方。结论仅供参考，最终由你决定。",
                           "Items it advises keeping were unchecked, with the reason under each row. It’s a second opinion — the call is yours."))
        case .needsConfig:
            return (L10n.t("还没配置模型", "Model not configured"),
                    L10n.t("「让 AI 分析」需要先在 ⚙ 里填好 API Key（OpenAI / Anthropic 兼容都行）。",
                           "“Ask AI” needs an API key first (OpenAI- or Anthropic-compatible, set in ⚙)."))
        case .failed:
            return (L10n.t("AI 分析失败", "AI analysis failed"),
                    L10n.t("模型调用失败，请检查 API Key / 网络，或点右侧重试。",
                           "The model call failed — check the API key / network, or tap Retry."))
        default:
            return (L10n.t("默认已全选，包含用户数据。", "Everything is selected by default, including user data."),
                    L10n.t("删除前可以让 AI 分析一遍——它会结合路径、文件特征和其它已装应用，把不该删的自动取消勾选并写明理由。",
                           "Let AI review first — it weighs the path, file traits and your other installed apps, then unchecks what shouldn’t go and says why."))
        }
    }

    private var groupCards: some View {
        let grouped = Dictionary(grouping: state.artifacts, by: \.category)
        return VStack(spacing: 8) {
            ForEach(ArtifactCategory.allCases, id: \.self) { category in
                if let items = grouped[category], !items.isEmpty {
                    ArtifactGroupCard(
                        title: category.displayName,
                        badge: nil,
                        entries: items,
                        expanded: !state.appsCollapsed.contains(category),
                        onToggleGroup: { on in
                            for a in items { setSelected(a.id, on) }
                        },
                        onToggleItem: { id, on in setSelected(id, on) },
                        onToggleExpanded: {
                            if state.appsCollapsed.contains(category) { state.appsCollapsed.remove(category) }
                            else { state.appsCollapsed.insert(category) }
                        },
                        lockedIds: Set(state.pwaAppToCompanion.values)
                    )
                }
            }
        }
    }

    private var bottomBar: some View {
        BottomActionBar(
            selectedCount: state.selectedCount,
            totalCount: state.artifacts.count,
            selectedSize: state.totalSelectedSize,
            hint: L10n.t("默认全选，含用户数据", "Selected by default, user data included"),
            onToggleAll: { on in on ? state.selectAll() : state.deselectAll() }
        ) {
            Button {
                showFeedback = true
            } label: {
                Label(L10n.t("反馈", "Report"), systemImage: "flag")
                    .font(.system(size: 11.5))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            // 卸载包含「直接删除」的不可逆部分，主按钮用红色强调。
            Button {
                showConfirm = true
            } label: {
                Label(L10n.t("卸载…", "Uninstall…"), systemImage: "trash")
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.destructive)
            .keyboardShortcut(.delete, modifiers: [.command])
            .disabled(state.selectedCount == 0)
            .help(state.selectedCount == 0
                  ? L10n.t("先勾选要删除的项", "Select items first")
                  : L10n.t("按风险分流删除所选项", "Remove the selected items, split by risk"))
        }
    }

    // MARK: - 扫描器展示

    /// 未选中应用时，右侧空白处展示 14 个扫描器的能力，
    /// 让用户知道「点一个 app 后会发生什么」。
    private var scannerShowcase: some View {
        ScrollView {
            VStack(spacing: 16) {
                Spacer(minLength: 20)
                Image(systemName: "hand.point.left")
                    .font(.system(size: 36))
                    .foregroundStyle(.secondary)
                Text(L10n.t("在左侧点选一个应用", "Pick an app on the left"))
                    .font(.system(size: 15, weight: .medium))
                Text(L10n.t("14 个扫描器会协同检查以下痕迹", "14 scanners will check the following traces"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    ForEach(ScannerCatalog.entries, id: \.name) { entry in
                        ScannerCard(entry: entry)
                    }
                }
                .frame(maxWidth: 520)

                Text(L10n.t("包含沙箱容器 · 启动项 · 点文件 · Shell 配置 · 认证凭证",
                            "Includes sandbox containers, launch agents, dotfiles, shell config and auth tokens"))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                Spacer(minLength: 20)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
    }

    // MARK: - 动作

    private func setSelected(_ id: UUID, _ on: Bool) {
        // PWA 配对：应用本体与其 Library 配置是「卸载单元」，勾选不可拆开。
        // 改动任一（本体或配置），另一项都强制同步——配置项的勾选框在 UI 上
        // 已禁用，用户只有一个操作点（应用本体），但这里仍做双向同步，
        // 以覆盖「分组全选 / 全不选」等会遍历到配置项的路径。
        let ids: [UUID]
        if let companionId = state.pwaAppToCompanion[id] {
            ids = [id, companionId]                 // id 是应用本体
        } else if let appId = state.pwaAppToCompanion.first(where: { $0.value == id })?.key {
            ids = [appId, id]                        // id 是跟随配置
        } else {
            ids = [id]
        }
        for tid in ids {
            if let idx = state.artifacts.firstIndex(where: { $0.id == tid }) {
                state.artifacts[idx].selected = on
            }
        }
    }

    private func expandAllCategories(expanded: Bool) {
        let grouped = Dictionary(grouping: state.artifacts, by: \.category)
        for category in grouped.keys {
            if expanded {
                state.appsCollapsed.remove(category)
            } else {
                state.appsCollapsed.insert(category)
            }
        }
    }

    private func runUninstall(userData: UserDataDisposition) {
        guard let plan = state.plan else { return }
        let selected = state.artifacts.filter(\.selected)
        // 目标是否就是 AI Mac Cleaner 自己（自卸载场景）。
        let isSelf = (state.matchedApp?.bundleId == Bundle.main.bundleIdentifier)
        var output: [String] = []
        // 先停掉目标 app 的运行进程：否则 .app 移进废纸篓后进程仍占着内存，
        // 表现就是「删了还在用」。按 bundle id / 显示名匹配，绝不终止自身。
        if let app = state.matchedApp {
            // 关键词只接「强标识」：helper 进程靠 bundle id 前缀 / 名称前缀兜底（见 ProcessTerminator.isTarget），
            // 不再下发 bundle id 末段这种弱片段（com.qoder.work 的 "work" 曾误杀 WorkBuddy）。
            let n = ProcessTerminator.terminate(targetBundleId: app.bundleId,
                                                targetName: app.displayName,
                                                keywords: [])
            if n > 0 {
                output.append(L10n.t("已终止 \(n) 个运行中的进程：\(app.displayName)",
                                      "Terminated \(n) running process(es): \(app.displayName)"))
            }
        }
        // 自卸载：历史库文件本身会被移到废纸篓，写了反而重新创建支持目录，
        // 所以跳过历史写入；删除完成后统一退出应用。
        let executor = RemovalExecutor(plan: plan, selected: selected,
                                       trashUserData: userData == .toTrash,
                                       skipHistory: isSelf)
        executor.onProgress = { line in output.append(line) }
        let outcome = executor.execute()
        executorOutput = output
        state.lastResult = outcome

        if isSelf && outcome.failureCount == 0 {
            // 文件已移到废纸篓，但进程仍在内存里跑。直接提示并退出应用，
            // 用户清空废纸篓即彻底移除。不再重新扫描（app 已在废纸篓）。
            showSelfUninstalled = true
            return
        }
        showResult = true
        // 文件系统变了：缓存的 app 列表和包管理器输出都失效了，
        // 不刷新的话左侧还会显示刚删掉的 app。
        state.invalidateInventory()
        Task { await state.scan() }
    }

    /// 自卸载时清除本应用的 UserDefaults 持久化文件。
    ///
    /// RemovalExecutor 已经把 `~/Library/Preferences/<bundle-id>.plist` 删了，
    /// 但 `cfprefsd` 守护进程仍在内存中缓存着这个域，会在 app 退出前重建 plist 文件。
    /// 先 `removePersistentDomain` 通知 cfprefsd 丢弃该域，再短暂等待让它处理完毕，
    /// 最后补删一次文件做双保险 —— 这样 app 退出后 plist 不会再复活。
    private static func cleanupSelfPreferences() {
        guard let bid = Bundle.main.bundleIdentifier else { return }
        UserDefaults.standard.removePersistentDomain(forName: bid)
        // cfprefsd 处理 removePersistentDomain 是异步的，给一点时间。
        Thread.sleep(forTimeInterval: 0.3)
        let plist = "\(NSHomeDirectory())/Library/Preferences/\(bid).plist"
        if FileManager.default.fileExists(atPath: plist) {
            try? FileManager.default.removeItem(atPath: plist)
        }
    }
}

// MARK: - 页头

/// 每个 tab 顶部统一的标题条：标题 + 一句说明 + 右侧操作区。
struct PageHeader<Trailing: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.bgSurface)
    }
}
