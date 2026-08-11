import SwiftUI

/// 「残留」页：无主残留（反查已卸载 app 的痕迹）⊕ 已知 AI 工具残留。
///
/// 这两类过去是两个独立 tab，但对用户来说是同一件事——「硬盘上还有谁的东西没清干净」。
/// 分两个菜单只会让人来回切。合并成一页，用筛选档区分来源。
///
/// 与应用页的关键区别：这里的判定是启发式的（没有明确的 app 可锁定），
/// 所以默认全不勾选，且顶部明确说明不确定性。AI 复核在这一页是**反向**用的：
/// 帮你勾出可以放心删的，而不是取消不该删的。
struct LeftoversView: View {
    @EnvironmentObject var state: AppState
    @State private var showConfirm = false
    @State private var showResult = false
    @State private var showFeedback = false
    @State private var executorOutput: [String] = []
    @State private var showSettings = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        // 让整块内容严格贴合窗口，避免子视图的理想高度把页头/底栏顶出可视区。
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // 刻意不自动扫描：进这个页面就递归读 Group Containers 会立刻弹出
        // 「AI Mac Cleaner 想访问其他 App 的数据」授权框 —— 用户只是点了个菜单，
        // 不该被弹框拦住。改成用户按「开始扫描」才动手。
        .sheet(isPresented: $showConfirm) {
            ConfirmSheet(title: L10n.t("确认删除残留", "Confirm removal"),
                         artifacts: state.leftoverSelectedArtifacts) { userData in
                runRemoval(userData: userData)
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
            FeedbackSheet(target: state.leftoverGroups.first?.artifacts.first)
        }
        .sheet(isPresented: $showSettings) {
            AIModelSettingsSheet()
        }
    }

    // MARK: - 页头

    private var header: some View {
        PageHeader(title: L10n.t("残留", "Leftovers"), subtitle: subtitleText) {
            if state.hasScannedLeftovers && !state.leftoverGroups.isEmpty {
                filterPicker
            }
            Button {
                Task { await rescan() }
            } label: {
                Label(state.hasScannedLeftovers
                      ? L10n.t("重新扫描", "Rescan")
                      : L10n.t("开始扫描", "Scan"), systemImage: "arrow.clockwise")
            }
            .controlSize(.small)
            .disabled(state.isScanningLeftovers)
        }
    }

    private var subtitleText: String {
        guard state.hasScannedLeftovers, !state.leftoverGroups.isEmpty else {
            return L10n.t("已卸载应用留下的孤儿数据 ⊕ AI 与开发工具残留（含模型/缓存）",
                          "Orphaned data from uninstalled apps ⊕ AI & dev-tool leftovers (models / caches)")
        }
        return L10n.t("已卸载应用留下的孤儿数据 ⊕ AI 与开发工具残留 · 合计 \(SizeFormat.human(state.leftoverTotalSize))",
                      "Orphaned data from uninstalled apps ⊕ AI & dev-tool leftovers · \(SizeFormat.human(state.leftoverTotalSize)) total")
    }

    private var filterPicker: some View {
        Picker("", selection: $state.leftoverFilter) {
            ForEach(AppState.LeftoverFilter.allCases) { f in
                Text("\(f.displayName) \(count(for: f))").tag(f)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }

    private func count(for f: AppState.LeftoverFilter) -> Int {
        guard let src = f.source else { return state.leftoverGroups.count }
        return state.leftoverGroups.filter { $0.source == src }.count
    }

    // MARK: - 主体

    @ViewBuilder
    private var content: some View {
        if state.isScanningLeftovers {
            VStack(spacing: 12) {
                ProgressView()
                Text(L10n.t("正在反查所有痕迹目录…", "Reverse-scanning all trace directories…"))
                    .foregroundStyle(.secondary)
                Text(L10n.t("需要递归读取每个 app 的嵌套组件，约几秒",
                            "Recursing into each app’s nested components — takes a few seconds"))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !state.hasScannedLeftovers {
            unscannedState
        } else if state.leftoverGroups.isEmpty {
            EmptyStateView(
                icon: "checkmark.seal",
                title: L10n.t("没有发现残留", "No leftovers found"),
                message: L10n.t("所有痕迹都能对应到已安装的应用，已知 AI 工具清单也没有命中。",
                                "Every trace maps to an installed app, and nothing matched the known AI-tool list."),
                tint: Theme.success
            )
        } else {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Banner(kind: .warn,
                               title: L10n.t("这些是启发式推断的结果，默认全部不勾选。",
                                             "These are heuristic results — nothing is checked by default."),
                               message: L10n.t("AI Mac Cleaner 通过反查「有没有活着的已安装应用认领这份数据」来判断残留，可能存在误判。删除前请确认路径你认得——不确定就先跳过。",
                                               "AI Mac Cleaner decides by checking whether any installed app still claims the data, so misjudgements are possible. Make sure you recognise each path — when in doubt, skip it."))
                        if !state.visibleLeftoverGroups.flatMap(\.artifacts).isEmpty {
                            aiBar
                        }
                        groupSections
                    }
                    .padding(16)
                }
                .onChange(of: state.aiReviewPhaseLeftovers) { _, phase in
                    if phase == .done { state.leftoverCollapsed = [] }
                }
                .background(Theme.bgCanvas)
                bottomBar
            }
        }
    }

    private var unscannedState: some View {
        EmptyStateView(
            icon: "questionmark.folder",
            title: L10n.t("查找残留", "Find leftovers"),
            message: L10n.t("找出主应用已经卸载、痕迹还留在硬盘上的目录，以及已知 AI 编程工具留下的隐藏配置。\n这类残留搜索框永远找不到 —— 你没法搜一个已经忘掉的应用名。",
                            "Find directories left behind after an app was uninstalled, plus hidden config from known AI coding tools.\nA search box can never find these — you can’t search for an app name you’ve forgotten.")
        ) {
            VStack(spacing: 10) {
                Button {
                    Task { await rescan() }
                } label: {
                    Label(L10n.t("开始扫描", "Start scan"), systemImage: "magnifyingglass")
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)

                Text(L10n.t("扫描时 macOS 可能弹出「想访问其他 App 的数据」——\n这是读取 ~/Library/Group Containers 所需，允许后才能算出残留大小。",
                            "macOS may ask to access other apps’ data during the scan —\nthat permission is needed to read ~/Library/Group Containers and size the leftovers."))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private var aiBar: some View {
        let (title, detail) = aiBarText
        return AIReviewBar(
            phase: state.aiReviewPhaseLeftovers,
            title: title,
            detail: detail,
            actionTitle: L10n.t("让 AI 帮我判断", "Ask AI"),
            onReview: {
                guard state.modelStore.isConfigured else {
                    state.aiReviewPhaseLeftovers = .needsConfig
                    return
                }
                // 不再原地跑判断，改为深链到「问 AI」页：预填诊断问句（按当前筛选档限定范围），
                // 复用 review_plan skill 回写勾选与理由，过程在对话里可见、可追加追问。
                // scope 跟随当前档：看哪一档就判断哪一档，不强制全量判断。
                // 如果用户已经勾选了若干项，问句会明确点名这些项，让 AI 只复核它们。
                // reviewScope: .leftovers 强制让 review_plan 走 leftovers 分支。
                let (prompt, scope) = reviewPrompt(for: state.leftoverFilter)
                state.jumpToAskAI(prompt, leftoverScope: scope, reviewScope: .leftovers)
            },
            onUndo: {
                state.undoAIReview()
                state.aiReviewPhaseLeftovers = .idle
            },
            onConfigure: { showSettings = true }
        )
    }

    /// 按当前筛选档生成「让 AI 帮我判断」的预填问句与对应的来源约束。
    ///
    /// 关键：问句里直接点名当前档（如「AI 编程工具残留」），`scope` 也一并传下去，
    /// 让 `review_plan` 只复核这一类 —— 用户看哪一档，AI 就判断哪一档。
    /// 如果用户已经勾选了若干项，问句会明确点名「我已勾选 X 项」，引导 AI 直接复核这些项。
    private func reviewPrompt(for filter: AppState.LeftoverFilter) -> (prompt: String, scope: LeftoverSource?) {
        let scope = filter.source
        let groups: [LeftoverGroup] = {
            guard let src = filter.source else { return state.leftoverGroups }
            return state.leftoverGroups.filter { $0.source == src }
        }()
        let selected = groups.flatMap { $0.artifacts.filter { $0.selected } }
        let selectedSize = selected.reduce(Int64(0)) { $0 + $1.size }

        let subject: String
        switch filter {
        case .all:
            subject = L10n.t("当前列出的残留文件（含无主残留、AI 编程工具、开发缓存）",
                             "the leftover files currently listed (orphaned, AI coding tools, and dev caches)")
        case .orphan:
            subject = L10n.t("当前列出的**无主残留**",
                             "the **orphaned leftovers** currently listed")
        case .aiTool:
            subject = L10n.t("当前列出的 **AI 编程工具残留**",
                             "the **AI coding-tool leftovers** currently listed")
        case .devCache:
            subject = L10n.t("当前列出的 **开发工具缓存**",
                             "the **dev-tool caches** currently listed")
        }

        // 把清单直接写进问句：模型看不到 session 注入，必须显式给清单，
        // 否则它不知道具体路径，会重复扫描或反问用户。
        let targetArtifacts = !selected.isEmpty ? selected : groups.flatMap(\.artifacts)
        let list = AgentFormat.promptList(targetArtifacts)

        let prompt: String
        if !selected.isEmpty {
            prompt = L10n.t(
                "我已勾选 \(subject) 中的 \(selected.count) 项（共 \(SizeFormat.human(selectedSize))）。\n\(list)\n\n请直接调用 review_plan(scope: leftovers) 复核这些已勾选项，逐项判断哪些可以放心删除、哪些建议保留，并说明原因。清单已经给出，不要重新扫描。",
                "I have selected \(selected.count) items (\(SizeFormat.human(selectedSize))) from \(subject).\n\(list)\n\nPlease call review_plan(scope: leftovers) directly to review only these selected items. For each, tell me which are safe to delete and which are better kept, with the reason. The list is already provided — do not scan again.")
        } else {
            prompt = L10n.t(
                "请帮我复核\(subject)。\n\(list)\n\n逐项判断哪些可以放心删除、哪些建议保留，并说明原因。清单已经给出，不要重新扫描，请直接调用 review_plan(scope: leftovers) 帮我标记出来。",
                "Please review \(subject).\n\(list)\n\nFor each, tell me which are safe to delete and which are better kept, with the reason. The list is already provided — do not scan again; please call review_plan(scope: leftovers) directly to mark them.")
        }
        return (prompt, scope)
    }

    /// 按当前阶段给出提示文案。
    private var aiBarText: (String, String) {        switch state.aiReviewPhaseLeftovers {
        case .done:
            return (L10n.t("AI 已判断完毕。", "AI is done."),
                    L10n.t("能放心删的已替你勾上，理由写在对应行下方；没勾的说明它也拿不准，请自己判断。",
                           "What it considers safe is now checked, with the reason under each row. Anything left unchecked is a call it couldn’t make for you."))
        case .needsConfig:
            return (L10n.t("还没配置模型", "Model not configured"),
                    L10n.t("「让 AI 帮我判断」需要先在 ⚙ 里填好 API Key（OpenAI / Anthropic 兼容都行）。",
                           "“Ask AI” needs an API key first (OpenAI- or Anthropic-compatible, set in ⚙)."))
        case .failed:
            return (L10n.t("AI 判断失败", "AI judgment failed"),
                    L10n.t("模型调用失败，请检查 API Key / 网络，或点右侧重试。",
                           "The model call failed — check the API key / network, or tap Retry."))
        default:
            return (L10n.t("不确定这些残留能不能删？", "Not sure whether these can go?"),
                    L10n.t("让 AI 逐项判断——能放心删的它替你勾上，有风险的保持不勾并写明原因，你只需要复核结论。",
                           "Let AI go item by item — it checks what’s safe, leaves risky ones alone with a reason, and you just review the verdict."))
        }
    }

    /// 按来源分区：AI 工具残留一区、无主残留一区。
    /// 「全部」档下两区都显示，单档下只显示对应区。
    @ViewBuilder
    private var groupSections: some View {
        ForEach(LeftoverSource.allCases) { source in
            let groups = state.visibleLeftoverGroups.filter { $0.source == source }
            if !groups.isEmpty {
                SectionLabel(
                    text: sectionTitle(source),
                    onExpand: { expandSection(source, expanded: true) },
                    onCollapse: { expandSection(source, expanded: false) }
                )
                VStack(spacing: 8) {
                    ForEach(groups) { group in
                        ArtifactGroupCard(
                            title: group.owner,
                            badge: .source(group.source),
                            artifacts: group.artifacts,
                            expanded: Binding(
                                get: { !state.leftoverCollapsed.contains(group.id) },
                                set: { open in
                                    if open { state.leftoverCollapsed.remove(group.id) } else { state.leftoverCollapsed.insert(group.id) }
                                }
                            ),
                            onToggleGroup: { on in
                                state.setLeftoverGroupSelected(groupId: group.id, selected: on)
                            },
                            onToggleItem: { id, on in
                                state.setLeftoverSelected(groupId: group.id, artifactId: id, selected: on)
                            }
                        )
                    }
                }
                .padding(.bottom, 4)
            }
        }
    }

    private func sectionTitle(_ s: LeftoverSource) -> String {
        switch s {
        case .aiTool:   return L10n.t("AI 编程工具残留 · 已知清单比对", "AI coding tools · matched against a known list")
        case .orphan:   return L10n.t("无主残留 · 反查无人认领", "Orphaned · no installed app claims them")
        case .devCache: return L10n.t("模型与开发缓存 · 编辑器/包管理器/运行时", "Models & dev caches · editors / package managers / runtimes")
        }
    }

    private func setSection(_ source: LeftoverSource, selected: Bool) {
        for g in state.leftoverGroups where g.source == source {
            state.setLeftoverGroupSelected(groupId: g.id, selected: selected)
        }
    }

    private func expandSection(_ source: LeftoverSource, expanded: Bool) {
        for g in state.leftoverGroups where g.source == source {
            if expanded {
                state.leftoverCollapsed.remove(g.id)
            } else {
                state.leftoverCollapsed.insert(g.id)
            }
        }
    }

    private var bottomBar: some View {
        BottomActionBar(
            selectedCount: state.leftoverVisibleSelectedCount,
            totalCount: state.leftoverVisibleCount,
            selectedSize: state.leftoverSelectedSize,
            hint: L10n.t("默认全不选，逐项确认", "Nothing selected by default — confirm item by item"),
            onToggleAll: { on in
                for g in state.visibleLeftoverGroups {
                    state.setLeftoverGroupSelected(groupId: g.id, selected: on)
                }
            }
        ) {
            Button {
                showFeedback = true
            } label: {
                Label(L10n.t("反馈", "Report"), systemImage: "flag")
                    .font(.system(size: 11.5))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            Button {
                showConfirm = true
            } label: {
                Label(L10n.t("删除所选…", "Remove selected…"), systemImage: "trash")
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.destructive)
            .disabled(state.leftoverSelectedCount == 0)
            .help(state.leftoverSelectedCount == 0
                  ? L10n.t("先勾选要删除的项", "Select items first")
                  : L10n.t("按风险分流删除所选项", "Remove the selected items, split by risk"))
        }
    }

    // MARK: - 动作

    private func rescan() async {
        await state.scanLeftovers()
        state.aiReviewPhaseLeftovers = .idle
    }

    private func runRemoval(userData: UserDataDisposition) {
        let selected = state.leftoverSelectedArtifacts
        guard !selected.isEmpty else { return }
        // 残留的归属 app 可能还有 helper 在跑（主 app 没了但进程活着），先退掉。
        // 启发式判定的 owner 作为关键词去匹配运行进程；杀不到也不影响删除。
        let owners = Set(state.leftoverGroups.filter { $0.selectedCount > 0 }.map { $0.owner.lowercased() })
        if !owners.isEmpty {
            _ = ProcessTerminator.terminate(keywords: Array(owners))
        }
        // 复用现有执行器：备份 + 白名单保护 + 历史全都走同一条路径，
        // 不为残留删除另开一套逻辑。
        let plan = RemovalPlan(targetName: L10n.t("残留清理", "Leftovers"), artifacts: selected)
        let executor = RemovalExecutor(plan: plan, selected: selected,
                                       runPackageUninstallers: false,
                                       trashUserData: userData == .toTrash)
        var output: [String] = []
        executor.onProgress = { output.append($0) }
        let outcome = executor.execute()
        executorOutput = output
        state.lastResult = outcome
        showResult = true
        state.invalidateInventory()
        Task { await state.scanLeftovers() }
    }
}
