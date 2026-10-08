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
        // AI 分析结束后展开全部分组，方便用户查看每一类 AI 写下的评语。
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
            if let mode = state.slimMode {
                ConfirmSheet(title: confirmTitle(mode: mode),
                             artifacts: state.artifacts.filter(\.selected),
                             warning: mode.confirmWarning(appName: state.matchedApp?.displayName ?? ""),
                             confirmTitle: mode.actionTitle,
                             trashByDefault: true) { userData in
                    runUninstall(userData: userData)
                }
            } else {
                ConfirmSheet(title: L10n.t("确认卸载", "Confirm uninstall"),
                             artifacts: state.artifacts.filter(\.selected)) { userData in
                    runUninstall(userData: userData)
                }
            }
        }
        .sheet(isPresented: $showResult) {
            let elevatable = (state.lastResult?.record.deletedArtifacts ?? [])
                .filter { !$0.success && !($0.requiresManual ?? false) && ($0.needsElevation ?? false) }
            ResultSheet(output: executorOutput,
                        successCount: state.lastResult?.successCount ?? 0,
                        failureCount: state.lastResult?.failureCount ?? 0,
                        manualCount: state.lastResult?.manualCount ?? 0,
                        freedBytes: state.lastResult?.record.freedBytes ?? 0,
                        trashedBytes: state.lastResult?.record.trashedBytes ?? 0,
                        elevatableFailures: elevatable)
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
                // 右键菜单：瘦身的入口放在这里，因为它是一个「针对某个已装 app」的动作，
                // 不该要求用户先做一次完整卸载扫描才能用。菜单里也保留了常规扫描。
                .contextMenu {
                    Button {
                        Task { await state.slim(app: app, mode: .cacheOnly) }
                    } label: {
                        Label(L10n.t("轻量瘦身（只清缓存）", "Light slim (caches only)"),
                              systemImage: "leaf")
                    }
                    Button {
                        Task { await state.slim(app: app, mode: .fullReset) }
                    } label: {
                        Label(L10n.t("彻底重置（等同新装）", "Full reset (like a fresh install)"),
                              systemImage: "arrow.counterclockwise")
                    }
                    Divider()
                    Button {
                        Task { await state.scan(app: app) }
                    } label: {
                        Label(L10n.t("扫描以便卸载", "Scan for uninstall"),
                              systemImage: "magnifyingglass")
                    }
                }
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
            scanningView
        } else if !hasVisibleResults {
            scannerShowcase
        } else {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        summaryCard
                        // 瘦身模式：先讲清这一档会动什么、不会动什么（尤其「不会卸载 app」），
                        // 再让人看清单。放在分组之前，避免用户先看到一堆路径再被告知后果。
                        if let mode = state.slimMode, let app = state.matchedApp {
                            slimBanner(mode: mode, appName: app.displayName)
                            userDataKeptNotice
                        }
                        // AI 分析条与「AI 补充发现」状态条都是**卸载语义**：
                        // 前者的 prompt 写的是「我打算卸载…」，后者只有真的调过模型
                        // 才有意义。瘦身流程两者都不走，show 出来只会误导。
                        if state.slimMode == nil {
                            if !state.artifacts.isEmpty {
                                aiBar
                            }
                            // 只在agent 真的跑过之后才显示结果条。
                            // AI 调查已并入「让 AI 分析」，不再是扫描时自动发生的一步——
                            // 所以「还没跑」时不该显示任何关于它的提示。
                            if state.aiProposeOutcome != .idle {
                                aiProposeStatusBar
                            }
                        }
                        SectionLabel(text: L10n.t("扫描结果 · 按类别分组", "Results · grouped by category"),
                                     onExpand: { expandAllCategories(expanded: true) },
                                     onCollapse: { expandAllCategories(expanded: false) })
                        if hasVendorLeftover {
                            vendorBanner
                        }
                        if hasAIProposed {
                            aiProposedBanner
                        }
                        groupCards
                    }
                    .padding(16)
                }
                .background(Theme.bgCanvas)
                bottomBar
            }
        }
    }

    /// 扫描中：把「正在调用 N 个扫描器」细化成「一个一个跑、每个显示找到了几项」。
    ///
    /// `state.scannerProgress` 是后台线程逐条回传的，主 actor 在每次 await 后让出，
    /// 这里就能逐个刷新——正在跑的扫描器高亮 + 转圈，跑完的打勾并标出命中数。
    private var scanningView: some View {
        ScrollView {
            VStack(spacing: 14) {
                Spacer(minLength: 16)
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(L10n.t("正在调用 \(state.scannerProgress.count) 个扫描器…",
                                "Running \(state.scannerProgress.count) scanners…"))
                        .font(.system(size: 13, weight: .medium))
                }
                .padding(.bottom, 2)

                VStack(spacing: 6) {
                    ForEach(state.scannerProgress) { prog in
                        ScannerRunRow(prog: prog)
                    }
                }
                .frame(maxWidth: 560)

                Spacer(minLength: 16)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            phase: effectiveReviewPhase,
            title: title,
            detail: detail,
            actionTitle: L10n.t("让 AI 分析", "Ask AI"),
            onReview: {
                guard state.modelStore.isConfigured else {
                    state.aiReviewPhaseApps = .needsConfig
                    return
                }
                // 后台跑 AI 分析：把 prompt 发到「问 AI」对话框并运行 Agent，
                // 但不自动跳转到该 tab。分析结论会回写勾选与理由，
                // 等用户点「去看 AI 怎么说」再切到问 AI 页查看完整对话。
                // 分析范围是「当前这个应用扫出来的全部项」，与右侧勾选状态无关——
                // 勾选只是为了最后卸载时决定删哪些，不该缩小 AI 的分析视野。
                // reviewScope: .apps 强制让 review_plan 走 apps 分支，避免被误判成残留。
                // 同时把当前清单直接写进问句：模型看不到 session 注入，必须显式给清单，
                // 否则它不知道具体路径，会重复扫描或反问用户。
                let appName = state.matchedApp?.displayName
                    ?? (state.searchText.isEmpty ? L10n.t("当前应用", "the current app") : state.searchText)
                let list = AgentFormat.promptList(state.artifacts)
                state.runAIReviewInBackground(prompt: L10n.t(
                    "我打算卸载已安装应用 \(appName)。内置扫描器已经扫过一轮，清单在下面（这部分不用你再看一遍）：\n\(list)\n\n请按下面这套办法把这件事做完——重点是**找出内置扫描器漏掉的东西**，而不是复述清单。\n\n第1 步 扫一遍：清单里没有的东西，往往是因为目录名和 app 名对不上。\n- 先 scan_app 锁定 \(appName)（拿到 bundle id 和全部关键词）。\n- 从它的名字里取**一段更短的词**（例如 StoryFab → 搜 story；CC Switch → 搜 ccswitch / switch），调 search_paths。\n- 搜索引擎会自动忽略 - _ . 空格，所以搜 story 能同时命中 story-fab / StoryFab / story_fab —— 内置扫描器正是在这种「形状对不上」上漏项的。\n\n第 2 步 验归属：搜出来的绝大多数是无关的（com.apple.*、别的软件的功能目录）。\n- 对每个**清单里没有**的候选项调 inspect_path，看内容类型和子项名。\n- inspect_path 会告诉你它是否被某个已装应用认领；被认领的一律排除。\n- 归属要以内容为证据，不要凭名字猜。例如 StoryFab 的 Application Support/story-fab 里是 Tauri 崩溃报告，技术栈对得上才算证据。\n\n第 3 步 交候选：确认属于 \(appName) 的，调 propose_paths 提交（逗号分隔多个路径）。\n- 每条都会过本地校验网（系统路径黑名单 / 白名单 / 保护根 / 活 app 反查 / 我的 /remember 豁免 / 必须真实存在），不过就丢弃，所以不用担心被误收。\n- 提交后入库的项**一律不勾选**，删不删由我决定。\n\n第 4 步 下结论：对**完整的清单**（内置扫描结果 + 你新提交的）调用 review_plan(scope: apps)，逐项标「可安全删除」或「建议保留 / 需人工确认」并说明原因。\n\n判定该不该删只看一件事：核实归属，不要删错。\(appName) 自身的主程序、数据、缓存删掉是预期内且安全的；系统文件、被别的应用共享的、以及只存在本机的独有数据才需要标出来。\n\n深度思考从简：只在归属拿不准时才展开推理，每条候选的思考不超过 2 句；不要复述上面的流程步骤，也不要重复清单里已有的已知信息。\n\n不要重新扫描我给你的这份清单——它已经在会话里了。",
                    "I'm about to uninstall the installed app \(appName). The built-in scanners already ran; their list is below (you don't need to review it again):\n\(list)\n\nDo the whole job with this procedure — the point is to FIND WHAT THE SCANNERS MISSED, not to restate the list.\n\nStep 1 — search. What's missing from the list is usually there because the directory name doesn't match the app name.\n- Call scan_app on \(appName) to get its bundle id and keywords.\n- Take a SHORTER fragment of the name (e.g. StoryFab → search \"story\"; CC Switch → search \"ccswitch\" / \"switch\") and call search_paths.\n- search_paths ignores - _ . and spaces on both sides, so \"story\" matches story-fab / StoryFab / story_fab alike — exactly the shape where the built-in scanners miss things.\n\nStep 2 — verify ownership. Most hits are irrelevant (com.apple.*, other apps' feature dirs).\n- For each candidate NOT already in the list, call inspect_path and read its content kind and child names.\n- inspect_path tells you whether an installed app claims it; drop anything that is claimed.\n- Base ownership on content evidence, not names. E.g. StoryFab's Application Support/story-fab holds Tauri crash reports — the stack trace matching is the evidence.\n\nStep 3 — submit. For each path you confirmed belongs to \(appName), call propose_paths (comma-separated).\n- Every path passes local validation (system block-list, allow-list, protected roots, live-app reverse lookup, my /remember exemptions, must exist), so wrong ones are dropped automatically.\n- Accepted entries are NEVER checked by default — I decide what to delete.\n\nStep 4 — conclude. Call review_plan(scope: apps) on the FULL list (scanner results + what you just submitted), marking each item \"safe to delete\" or \"keep / needs human confirmation\" with a reason.\n\nThe only thing that matters is ownership. \(appName)'s own bundle, data and caches are safe — and expected — to delete; only system files, data shared with other apps, and data that exists only on this machine deserve a flag.\n\nKeep your deep-thinking terse: reason at length only when ownership is genuinely uncertain, no more than 2 sentences per candidate; don't restate the procedure steps and don't repeat facts already in the list.\n\nDo not re-scan the list I gave you — it's already in the session."),
                    reviewScope: .apps)
            },
            onViewConclusion: {
                state.selectedTab = .askAI
            },
            onConfigure: { showSettings = true }
        )
    }

    /// AI 条上实际呈现的阶段。
    ///
    /// 不直接照搬 `aiReviewPhaseApps`：那个值靠 `review_plan` / `plan_uninstall`
    /// 这两个 skill 落章，而「让 AI 分析」完全可能没走到那一步（步数用完，
    /// 或只提交了候选就收尾）。那种情况下 phase 会停在 `.idle` / `.failed`，
    /// 但对话里**确实已经有一份结论**——于是界面自相矛盾：下面结果条写着
    /// 「额外找到 1 条」，上面却还在邀请你点「让 AI 分析」，像什么都没发生，
    /// 用户要么重复花一次模型调用，要么根本不知道结论在哪。
    ///
    /// 判定依据用「模型这一轮到底跑通没有」：`.found` / `.none` 都证明跑通了。
    /// `.running` 要原样保留（分析还在进行中，按钮不该半路变脸），
    /// `.needsConfig` 也保留（那是真没配置，跟跑没跑成无关）。
    private var effectiveReviewPhase: AIReviewPhase {
        let phase = state.aiReviewPhaseApps
        if phase == .running || phase == .needsConfig { return phase }
        switch state.aiProposeOutcome {
        case .found, .none: return .done
        case .idle, .timedOut, .failed, .disabled: return phase
        }
    }

    /// 按当前阶段给出提示文案。
    private var aiBarText: (String, String) {
        switch effectiveReviewPhase {
        case .done:
            // 区分「真的走完了 review_plan」和「只是跑通了、没落章」。
            // 后者不能声称「已回写勾选状态」——那是假话，用户会以为勾选框
            // 已经被 AI 调过，从而信任一个其实没被调整过的清单。
            if state.aiReviewPhaseApps == .done {
                return (L10n.t("AI 已分析完毕。", "AI analysis complete."),
                        L10n.t("结论已发到「问 AI」并回写了勾选状态，点右侧按钮查看完整分析。",
                               "The conclusion was sent to Ask AI and the checkboxes were updated. Tap the button to view the full analysis."))
            }
            return (L10n.t("AI 分析已完成。", "AI analysis finished."),
                    L10n.t("结论在「问 AI」里，点右侧按钮查看。注意：这次没有回写勾选状态，请对照结论自行核对清单。",
                           "The conclusion is in Ask AI — tap the button to view it. Note: the checkboxes were NOT updated this time; review the list against the conclusion yourself."))
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
                    L10n.t("点「让 AI 分析」：它会先用更宽的关键词去翻痕迹目录、把内置扫描器漏掉的路径找出来逐个确认归属，再对完整清单给出取舍理由。",
                           "Tap “Ask AI”: it first searches the trace dirs with broader keywords to recover what the built-in scanners missed, verifies ownership, then gives a verdict on the full list."))
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

    /// 结果里是否含有「同厂商残留」类目（同源厂商清理建议）。
    private var hasVendorLeftover: Bool {
        state.artifacts.contains { $0.category == .vendorLeftover }
            || state.artifacts.contains { $0.category == .runningProcess && $0.note?.contains("OpenAI") == true }
    }

    /// 同源厂商残留引导提示：解释为什么卸载 ChatGPT 还会留下 Codex CLI 目录 /
    /// 菜单栏幽灵图标，并建议一并清理。
    private var vendorBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.warning)
                    .font(.system(size: 13))
                Text(L10n.t("发现同厂商残留", "Same-vendor leftovers found"))
                    .font(.system(size: 12.5, weight: .semibold))
                Spacer()
            }
            Text(L10n.t("OpenAI 把 ChatGPT、Codex CLI、浏览器扩展宿主拆成多个独立入口，卸载主 app 不会自动带走它们——这正是卸载后菜单栏图标点不动、文件夹还在的原因。下方「同厂商残留」分组已帮你列出，安全项默认勾选，用户数据项默认不勾（留一线可找回）。",
                           "OpenAI ships ChatGPT, Codex CLI and a browser-extension host as separate entries; uninstalling the main app leaves the others behind — that’s why a dead menu-bar icon or leftover folder remains. The “Same-vendor leftovers” group below lists them: safe items are pre-checked, user-data items are left unchecked (recoverable)."))
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.warningSubtle, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.warning.opacity(0.35), lineWidth: 1))
    }

    /// 瘦身模式顶部横幅：讲清这一档会动什么、不会动什么。
    ///
    /// 最重要的一句话是「app 不会被卸载」——用户从右键菜单点进来的心理预期是
    /// 「清理」而不是「卸载」，必须显式打消「会不会连 app 一起删掉」的顾虑。
    private func slimBanner(mode: SlimMode, appName: String) -> some View {
        let tint = mode == .fullReset ? Theme.warning : Theme.accent
        return HStack(alignment: .top, spacing: 7) {
            Image(systemName: mode == .fullReset ? "arrow.counterclockwise" : "leaf")
                .font(.system(size: 12))
                .foregroundStyle(tint)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(mode.title)
                    .font(.system(size: 12.5, weight: .semibold))
                Text(mode.bannerText(appName: appName))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.bgSurface, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(tint.opacity(0.35), lineWidth: 1))
    }

    /// 「有用户数据被取消勾选」的提示：讲清保留下来会发生什么。
    ///
    /// 为什么要常驻横幅而不是每次取消勾选都弹窗：取消勾选最常发生在「按组取消」，
    /// 一次操作会触发 N 条 item 的取消 → 逐条弹窗等于把用户打断十几次。横幅不打断
    /// 操作、一直挂在清单上方，且只要还有未勾项就在，取消全部后自动消失。
    private var userDataKeptNotice: some View {
        let kept = state.artifacts.filter { $0.risk == .userData && !$0.selected }
        return Group {
            if let mode = state.slimMode, mode.includesUserData, !kept.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 7) {
                        Image(systemName: "info.circle")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.warning)
                        Text(L10n.t("有 \(kept.count) 项用户数据未勾选，将被保留",
                                    "\(kept.count) user-data item(s) unchecked — they will be kept"))
                            .font(.system(size: 12.5, weight: .semibold))
                        Spacer()
                    }
                    Text(keptConsequence(kept))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.bgSurface, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .stroke(Theme.warning.opacity(0.35), lineWidth: 1))
            }
        }
    }

    /// 逐条说明「保留这些用户数据」的后果，要具体到能判断，而不是泛泛说
    /// 「可能无法完全重置」。保留 Cookie 类和保留配置类的后果并不一样。
    private func keptConsequence(_ kept: [Artifact]) -> String {
        let appName = state.matchedApp?.displayName ?? L10n.t("该应用", "the app")
        let byCategory = Dictionary(grouping: kept, by: \.category)
            .sorted { $0.key.displayName < $1.key.displayName }
            .map { "\($0.key.displayName)（\($0.value.count) 项）" }
        var lines = [L10n.t("未勾选：\(byCategory.joined(separator: "、"))",
                           "Unchecked: \(byCategory.joined(separator: ", "))")]

        // 会不会「清完了还是登着的」，取决于 Cookie / 会话数据有没有被保留。
        let keepsSession = kept.contains { a in
            let p = a.path.lowercased()
            return p.contains("/cookies/") || p.contains("/httpstorages/")
        }
        if keepsSession {
            lines.append(L10n.t("• 保留了 Cookie / 会话数据：\(appName) 可能仍保持登录，这次重置不会把你退出登录。",
                                "• Cookie / session data is kept: \(appName) may stay signed in — this reset will not sign you out."))
        }
        lines.append(L10n.t("• 保留了应用配置：设置不会回到默认，偏好（窗口大小、上次选择等）会原样保留。",
                            "• App config is kept: settings won't return to defaults; preferences (window size, last selection…) stay as they are."))
        lines.append(L10n.t("• 保留了本地数据：只存在本机、没同步的内容（笔记、记录、离线文件）不会被清除。",
                            "• Local data is kept: content that exists only on this machine and was never synced (notes, records, offline files) is not removed."))
        lines.append(L10n.t("想完成「等同新装」的重置，就把它们重新勾上。",
                            "Re-check them to complete a fresh-install reset."))
        return lines.joined(separator: "\n")
    }

    /// 确认弹窗标题。瘦身档刻意不说「卸载」——app 本体并不会被删。
    private func confirmTitle(mode: SlimMode) -> String {
        switch mode {
        case .cacheOnly:
            return L10n.t("确认瘦身（只清缓存）", "Confirm slim (caches only)")
        case .fullReset:
            return L10n.t("确认彻底重置", "Confirm full reset")
        }
    }

    /// 结果里是否含有 AI 提议项。
    private var hasAIProposed: Bool {
        state.artifacts.contains { $0.category == .aiProposed }
    }

    /// AI 调查的结果条（agent 跑完之后才出现）。
    ///
    /// **只在跑过之后才显示**：「AI 补充发现」已经并入「让 AI 分析」，
    /// 不再是扫描时自动发生的一步。所以未运行时**什么都不显示** ——
    /// 之前这里常驻一句「未启用（需要在 ⚙ 配置模型，或在设置里打开该开关）」，
    /// 会让人以为还有另一个功能没打开、还得去设置里折腾一遍。
    ///
    /// 跑过之后必须写清楚「跑没跑 / 找到没有」：这一步没产出时结果里不会多出
    /// 任何东西，用户分不清是「它翻了一遍目录确实没找到」还是「它压根没跑成」。
    private var aiProposeStatusBar: some View {
        let icon: String
        let text: String
        let tint: Color
        switch state.aiProposeOutcome {
        case .found(let n):
            icon = "sparkles"
            text = L10n.t("AI 调查：额外找到 \(n) 条内置扫描器漏掉的路径，已加入清单并默认不勾选，请逐条核对后再决定。",
                          "AI investigation: found \(n) path(s) the built-in scanners missed — added to the list, unchecked by default. Review each one before deciding.")
            tint = Theme.accent
        case .none:
            icon = "checkmark.circle"
            text = L10n.t("AI 调查：已翻过全部痕迹目录，本轮没有发现内置扫描器漏掉的路径。",
                          "AI investigation: went through every trace root and found nothing the built-in scanners missed.")
            tint = Theme.success
        case .timedOut:
            icon = "clock.badge.exclamationmark"
            text = L10n.t("AI 调查：模型 30 秒无响应，本轮已跳过（不影响内置扫描结果）。",
                          "AI investigation: the model didn't respond within 30s — skipped this round (built-in results unaffected).")
            tint = Theme.warning
        case .idle:
            // 不会渲染到这里：调用处已按 `.idle` 整体隐藏这条提示。
            // 保留一个中性兜底文案，避免将来有人改了条件后露出「未启用」这种误导说法。
            icon = "sparkles"
            text = ""
            tint = .secondary
        case .failed(let kind):
            icon = "exclamationmark.triangle"
            if kind == .permanent {
                text = L10n.t("AI 调查：模型调用失败（key 失效 / 没额度 / 配置错误），本次会话已停止调用。在设置里修改配置或「测试连接」成功即可恢复。",
                              "AI investigation: the model call failed (bad key / no quota / bad config) — disabled for this session. Fix the config in Settings or pass 'Test connection' to resume.")
            } else {
                text = L10n.t("AI 调查：网络错误（可重试），本轮未获得 AI 补充；下次会再试。",
                              "AI investigation: a network error (retryable) — no AI suggestions this round; it will try again.")
            }
            tint = Theme.warning
        case .disabled:
            icon = "sparkles.slash"
            text = L10n.t("AI 调查：已因 key 失效 / 没额度停用，本轮会话不再调用（不影响内置扫描结果）。修改模型配置或「测试连接」成功后会恢复。",
                          "AI investigation: disabled after a permanent failure (bad key / no quota); not called this session (built-in results unaffected). Resumes after you change the config or pass 'Test connection'.")
            tint = .secondary
        }
        return HStack(alignment: .top, spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(tint)
                .padding(.top, 1)
            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            // 分析跑完后给出「去看结果」的出口。
            //
            // 这一条结果只写了「找到了几条」，而**为什么**是这些、每一条的取舍理由
            // 全在「问 AI」的对话里。没有这个按钮，用户看到一行字之后不知道该去哪，
            // 只能自己想起左边还有个「问 AI」页——那条完整的分析就等于白跑了。
            if hasAIConclusion {
                Button {
                    state.selectedTab = .askAI
                } label: {
                    Text(L10n.t("看结果 →", "View result →"))
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Theme.aiPrimary)
                }
                .buttonStyle(.plain)
                .padding(.top, 1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Theme.bgSurface, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.divider, lineWidth: 1))
    }

    /// 本轮 AI 调查是否产出了一份**可看的分析**（对话里有它的结论）。
    ///
    /// 只认「真的跑过」的两种结局：`.found`（找到并补了几条）与 `.none`（翻过目录没找到）。
    /// 失败 / 超时 / 停用不在此列——那些情况下对话里只有一句错误说明，
    /// 引导用户跳过去不如把「去改配置 / 重试」留在这一屏上。
    private var hasAIConclusion: Bool {
        switch state.aiProposeOutcome {
        case .found, .none: return true
        case .idle, .timedOut, .failed, .disabled: return false
        }
    }

    /// AI 提议项说明横幅：讲清这些项从哪来、过了哪几道闸、以及为什么默认不勾。
    ///
    /// 不写清楚就会出现最坏的情况：用户以为「AI 都说是这个 app 的了」而全选，
    /// 结果删掉的是共享数据。横幅把「模型可能认错归属」这件事摆在勾选之前。
    private var aiProposedBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Image(systemName: "sparkles")
                    .foregroundStyle(Theme.accent)
                    .font(.system(size: 13))
                Text(L10n.t("AI 补充发现的路径", "Extra paths suggested by AI"))
                    .font(.system(size: 12.5, weight: .semibold))
                Spacer()
            }
            Text(L10n.t("这些是内置扫描器没找到、由模型补充提议的路径。每条都已过本地校验：白名单 / 系统路径黑名单 / 活 app 反查（被别的已装 app 认领的直接丢弃）/ 你的 /remember 豁免，且必须真实存在。但模型仍可能认错归属，所以它们一律默认不勾选，删掉后也进废纸篓可找回。",
                           "These are paths the built-in scanners missed and the model suggested. Each one passed local validation: allow-list, system-path block-list, live-app reverse lookup (anything claimed by another installed app is dropped), and your /remember exemptions — and it must actually exist. The model can still misattribute ownership, so none of them are checked by default, and deleting them goes to the Trash so they can be recovered."))
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.accentSubtle, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.accent.opacity(0.3), lineWidth: 1))
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
            // 瘦身模式下换成对应档位的说法与配色：app 本体不会被删，
            // 用红色的「卸载」按钮会让人以为这会把 app 也带走。
            Button {
                showConfirm = true
            } label: {
                if let mode = state.slimMode {
                    Label(mode.actionTitle + L10n.t("…", "…"),
                          systemImage: mode == .fullReset ? "arrow.counterclockwise" : "leaf")
                } else {
                    Label(L10n.t("卸载…", "Uninstall…"), systemImage: "trash")
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(state.slimMode == nil ? Theme.destructive : Theme.accent)
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
            // 用 aliases（文件名、显示名、bundle id、去空格紧凑写法）兜底，确保 ChatGPT 这类
            // helper 进程（名称可能是 "OpenAI Helper" 而不是 "ChatGPT Helper"）也能被终止。
            let keywords = app.aliases
                .filter { $0.count >= 3 && !AppIdentity.genericBundleSuffixes.contains($0) }
                .sorted()
            let n = ProcessTerminator.terminate(targetBundleId: app.bundleId,
                                                targetName: app.displayName,
                                                keywords: keywords)
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
