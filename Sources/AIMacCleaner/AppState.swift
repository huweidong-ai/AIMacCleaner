import Foundation
import Combine
import AppKit

/// AI 分析条状态。提升到 AppState 是为了切 tab 后不丢失。
enum AIReviewPhase: String, CaseIterable {
    case idle, running, done, needsConfig, failed
}

@MainActor
final class AppState: ObservableObject {
    @Published var searchText: String = ""
    /// 应用页按类别的折叠状态（默认全部折叠）。提升到 AppState 以免切 tab 后
    /// 视图重建丢状态（尤其是 AI 分析后展开的状态）。
    @Published var appsCollapsed: Set<ArtifactCategory> = Set(ArtifactCategory.allCases)
    @Published private(set) var plan: RemovalPlan?
    @Published private(set) var isScanning: Bool = false
    @Published var artifacts: [Artifact] = []  // 可勾选编辑
    @Published var selectedTab: Tab = .askAI
    /// 从应用 / 残留 / 进程页深链进入「问 AI」页时预填的问句；AskAIView 消费后置 nil。
    @Published var askAIPendingPrompt: String?
    /// 深链时残留页所处筛选档的来源（.all 时为 nil）。AskAIView 消费 pendingPrompt 时一并读取，
    /// 用于让 `review_plan` 只分析该来源，消费后置 nil。
    @Published var askAIPendingLeftoverScope: LeftoverSource?
    /// 深链时由入口注入的强制分析范围：`.apps` 或 `.leftovers`。
    /// 非 nil 时 `review_plan` 不再让模型自行选择 scope，消费后置 nil。
    @Published var askAIPendingReviewScope: ReviewScope?

    // MARK: - AI 分析状态（跨 tab 持久，避免切回后丢失）
    @Published var aiReviewPhaseApps: AIReviewPhase = .idle
    @Published var aiReviewPhaseLeftovers: AIReviewPhase = .idle

    @Published var lastError: String?
    @Published var lastResult: RemovalExecutor.Outcome?
    /// 本次扫描锁定到的 app（关键词模式下为 nil）
    @Published var matchedApp: AppIdentity?
    /// 同名候选，供用户改选
    @Published var ambiguousMatches: [AppIdentity] = []

    /// PWA（Chrome / Edge 安装的网页应用）的「应用本体」↔「Library 配置」配对。
    /// key 是 `.app` 的 artifact id，value 是对应 plist 的 artifact id。
    /// 删除 .app 时自动连带删配置，避免留下无主残留（见 `linkPWACompanions()`）。
    @Published private(set) var pwaAppToCompanion: [UUID: UUID] = [:]

    // ── v1.2：app 列表入口 ──
    /// 全部已安装 app，左侧列表用
    @Published var allApps: [AppIdentity] = []
    @Published private(set) var isLoadingApps = false

    // ── v1.2/v1.5 合并：残留（无主 ⊕ AI 工具） ──
    @Published var leftoverGroups: [LeftoverGroup] = []
    @Published private(set) var isScanningLeftovers = false
    /// 是否已经扫过一次（区分「没扫」和「扫了但没有」）
    @Published private(set) var hasScannedLeftovers = false
    @Published var leftoverFilter: LeftoverFilter = .all
    /// 残留分组的折叠状态（按 group id）。提升到 AppState：切 tab 后视图被重建，
    /// 若用页面内 @State 会在初始化时重置为全展开，丢失「默认折叠」设定。
    @Published var leftoverCollapsed: Set<UUID> = []

    // ── 进程管理 ──
    @Published var processes: [LiveProcess] = []
    @Published private(set) var isScanningProcesses = false
    /// 是否已经扫过一次（区分「没扫」和「扫了但没有」）
    @Published private(set) var hasScannedProcesses = false
    @Published var selectedPids: Set<pid_t> = []

    // ── 问 AI 模型配置 ──
    /// 「问 AI」页用的模型仓库：可配置多个档，支持默认 + 对话内下拉切换。
    /// 写入即持久化到 UserDefaults（key `expunge.aimodels`）。
    @Published var modelStore: ModelConfigStore = ModelConfigStore.current {
        didSet { ModelConfigStore.current = modelStore }
    }

    /// 当前用于回答的模型档（选中的 / 默认可用的）。未配置时返回 nil。
    var activeConfig: AIModelConfig? { modelStore.active }

    /// 是否已配置至少一个模型——「问 AI」能跑的前提。
    var modelReady: Bool { modelStore.isConfigured }

    // ── 「问 AI」对话（Sprint A）──
    //
    // 不变量：`chatMessages` 恒满足「已裁到 ≤15 轮」且「已落盘」。
    // 因此三处消费者可以无脑信任它：
    //   屏幕   = chatMessages
    //   落盘   = chatMessages
    //   发模型 = ChatPolicy.modelHistory(chatMessages)
    //
    // 状态放在这里而不是 AskAIView 的 @State：MainView.detail 是条件渲染，
    // 切 tab 会销毁重建 AskAIView，@State 随之归零 —— 持久化再完善也救不了
    // 「切走再切回就空了」。
    //
    // 任何修改都必须走下面四个方法（它们统一执行 trim → 落盘），
    // 所以这里是 private(set)：禁止在 View 里直接拼数组，也禁止在 View 里调 ChatStore。
    @Published private(set) var chatMessages: [AIMessage] = []

    /// Agent 是否正在跑。一并上提是为了让它跨 tab 切换存活 ——
    /// 否则用户发完消息切走再切回，标志位归 false 但 Task 还在跑，
    /// 此时能再发一条，两个 Agent 并发、两条回复乱序落地。
    @Published var chatIsThinking: Bool = false

    /// 是否存在真实对话（`.me` / `.ai`）。空态判定的唯一依据 —— 不能用 `isEmpty`，
    /// 否则 `/reset` 后只剩系统消息时首屏引导会消失。
    var chatHasConversation: Bool { ChatPolicy.hasConversation(chatMessages) }

    /// 发往模型的 history：锚点后 → 去 system → 保证 user 开头 → 映射。
    var chatModelHistory: [(role: String, content: String)] {
        ChatPolicy.modelHistory(chatMessages)
    }

    /// 冷启动恢复。由 `init()` 调用 —— 放这里而不是 `onAppear`，是为了让恢复
    /// **只发生一次**：不需要 hasRestored 状态位，也不存在「切 tab 回来又恢复一次
    /// 覆盖了新消息」的竞态。读一个上限 30 条消息的 JSON 是亚毫秒级同步 I/O，
    /// 与既有 `ModelConfigStore.current`（同步读 UserDefaults）同一量级。
    ///
    /// 读盘后仍要 trim：防御手改过的 JSON 或旧版留下的超长文件。
    /// `chatIsThinking` 保持 false —— 恢复出来的历史永远不带「思考中」。
    func restoreChat() {
        chatMessages = ChatPolicy.trim(ChatStore.shared.all())
    }

    /// 追加一条并维护不变量：append → trim → 落盘。
    ///
    /// 落盘时机是**每一次**变更后立即同步写 —— 包括 append user 消息时（不等 AI 回复），
    /// 这样中途崩溃或退出，用户问出去的那句话不丢。
    func appendChat(_ message: AIMessage) {
        var next = chatMessages
        next.append(message)
        chatMessages = ChatPolicy.trim(next)
        persistChat()
    }

    /// `/new` 与「新会话」按钮共用。清空内存 + 清空磁盘。
    func clearChat() {
        chatMessages = []
        ChatStore.shared.clearAll()
    }

    /// `/reset`：打上下文锚点。屏幕记录保留、落盘保留，只是模型看不到锚点之前的内容了。
    ///
    /// 守卫：当前无真实对话、或最后一条已经是锚点时不追加，避免堆叠空分割线。
    func resetChatContext() {
        guard chatHasConversation else { return }
        guard chatMessages.last?.isAnchor != true else { return }
        appendChat(AIMessage.anchor())
    }

    private func persistChat() {
        ChatStore.shared.save(chatMessages)
    }

    // ── 长期记忆 ──
    //
    // 与上面那组的关键区别：`clearChat()` 碰不到这里。记忆存在另一个文件
    // （`memory.json`），15 轮窗口带不走、`/new` 也删不掉 —— 这正是它存在的理由。
    //
    // 记忆有两个下游，缺一不可：
    //   1. 提示词 —— `memoryPromptBlock` 注入 system prompt，影响模型怎么回答
    //   2. 扫描器 —— `MemoryStore.keepPaths()` 喂给 `OrphanScanner`，影响扫出什么
    // 只做 1 的话，用户在对话里说过「这个目录别动」，回头点扫描照样把它列成孤儿，
    // 记忆就是假的。

    @Published private(set) var memoryNotes: [MemoryNote] = []

    /// 冷启动恢复。同 `restoreChat()`，由 `init()` 调用，全进程只跑一次。
    func restoreMemory() {
        memoryNotes = MemoryStore.shared.all()
    }

    /// 写入一条记忆。返回**要展示给用户的那句话** —— 成功是回执，失败是拒绝理由。
    ///
    /// 校验放在 `MemoryPolicy`（纯函数、可自检），存储层不做判断，
    /// 所以拒绝理由能原样端到用户面前，不会在某一层被静默吞掉。
    func rememberNote(_ text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let reason = MemoryPolicy.rejectionReason(for: t, existingCount: memoryNotes.count) {
            return reason
        }
        let note = MemoryNote(text: t)
        memoryNotes = MemoryStore.shared.add(note)
        return MemoryPolicy.receipt(for: note)
    }

    func forgetNote(_ id: UUID) {
        memoryNotes = MemoryStore.shared.delete(id)
    }

    func forgetAllNotes() {
        MemoryStore.shared.clearAll()
        memoryNotes = []
    }

    /// 注入 system prompt 的记忆块。无记忆时是空串。
    var memoryPromptBlock: String {
        MemoryPolicy.promptBlock(memoryNotes)
    }

    /// 「关于 AI Mac Cleaner」面板是否打开（由菜单栏 Help → 关于 AI Mac Cleaner 触发）。
    @Published var showAbout: Bool = false
    /// AI 模型设置面板（菜单栏 设置 → 配置 AI 模型… 触发）。
    @Published var showAIModelSettings: Bool = false

    /// 是否拥有完全磁盘访问权限（FDA）。冷启动检测一次，app 激活时重测。
    /// 没它扫不了 `~/Library` 下其他 app 的数据，扫描入口会据此改弹引导页。
    @Published private(set) var fullDiskAccessGranted: Bool = false
    /// 是否展示「需要完全磁盘访问权限」引导页（替代系统硬弹窗）。
    @Published var showFDAGuidance: Bool = false


    /// 监听语言切换，触发整棵视图树重建，使 L10n.t() 重新求值。
    private var cancellables = Set<AnyCancellable>()
    private var lastLanguage: String = L10n.override.rawValue

    enum Tab: String, CaseIterable, Identifiable {
        // raw value 当稳定 id 用（`Identifiable`、选中态持久化），不本地化。
        case askAI = "askAI"
        case apps = "apps"
        case leftovers = "leftovers"
        case processes = "processes"
        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .askAI:     return L10n.t("问 AI", "Ask AI")
            case .apps:      return L10n.t("应用", "Apps")
            case .leftovers: return L10n.t("残留", "Leftovers")
            case .processes: return L10n.t("进程", "Processes")
            }
        }
    }

    /// 残留 tab 的筛选档。
    enum LeftoverFilter: String, CaseIterable, Identifiable {
        case all = "all"
        case orphan = "orphan"
        case aiTool = "aiTool"
        case devCache = "devCache"
        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .all:      return L10n.t("全部", "All")
            case .orphan:   return L10n.t("无主残留", "Orphaned")
            case .aiTool:   return L10n.t("AI 编程工具", "AI coding tools")
            case .devCache: return L10n.t("开发工具缓存", "Dev-tool caches")
            }
        }

        var source: LeftoverSource? {
            switch self {
            case .all:      return nil
            case .orphan:   return .orphan
            case .aiTool:   return .aiTool
            case .devCache: return .devCache
            }
        }
    }

    /// 进程 tab 的筛选档：决定列表中显示哪些进程。
    /// 当前可见进程：仅后台（无 GUI、非系统的用户进程）。
    var visibleProcesses: [LiveProcess] {
        processes.filter { $0.kind == .background }
    }

    let scanners: [any Scanner] = [
        AppBundleScanner(),
        BrewScanner(),
        RawBinaryScanner(),
        XDGUserDataScanner(),
        LaunchAgentScanner(),
        ProcessScanner(),
        LibraryDataScanner(),
        ContainerScanner(),
        DotfileScanner(),
        ShellConfigScanner(),
        AuthTokenScanner(),
        NpmScanner(),
        PipxScanner(),
        MASScanner()
    ]

    var totalSelectedSize: Int64 {
        artifacts.filter(\.selected).reduce(0) { $0 + $1.size }
    }

    var selectedCount: Int {
        artifacts.filter(\.selected).count
    }

    func scan() async {
        let target = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return }

        // 没 FDA 不硬扫——改弹引导页，避免 macOS 每次都硬弹「想访问其他App的数据」。
        guard fullDiskAccessGranted else { showFDAGuidance = true; return }

        isScanning = true
        lastError = nil
        plan = nil
        defer { isScanning = false }

        // 先把用户输入解析成具体 app：搜「微信」要能定位到 WeChat.app。
        // 搜索框不再支持无匹配 app 时的关键词全盘扫描（CLI 工具走 Ask AI / CLI 入口）。
        let query = Self.resolveQuery(from: target)
        matchedApp = query.app
        ambiguousMatches = Self.candidates(for: target)
        guard query.app != nil else {
            artifacts = []
            plan = nil
            return
        }

        var allArtifacts: [Artifact] = []
        for scanner in scanners {
            let results = await scanner.scan(query: query)
            allArtifacts.append(contentsOf: results)
        }
        // 去重（按 path）
        var seen = Set<String>()
        allArtifacts = allArtifacts.filter { seen.insert($0.path).inserted }
        // 应用页默认全选（含用户数据），把选择权交给用户。
        for i in allArtifacts.indices { allArtifacts[i].selected = true }
        artifacts = allArtifacts
        plan = RemovalPlan(targetName: query.displayTarget, artifacts: allArtifacts)
        linkPWACompanions()
        aiReviewPhaseApps = .idle
    }

    /// 把用户输入解析成扫描条件。
    /// `nonisolated`：Agent 的 skill 层跑在 MainActor 之外（CLI 路径不碰主 actor），
    /// 需要直接调用它来解析目标。它只依赖非隔离的 `InventoryCache` / `AppInventory`，
    /// 不碰任何 MainActor 状态，所以可以安全放开隔离。
    nonisolated static func resolveQuery(from target: String) -> ScanQuery {
        let allApps = InventoryCache.shared.allApps()
        let hits = AppInventory.search(target, in: allApps)
        if let best = hits.first {
            return ScanQuery(raw: target, app: best, others: allApps)
        }
        return ScanQuery(raw: target)
    }

    /// 扫描完一个 app 后调用：若该 app 是 Chrome / Edge 的 PWA，把它的 `.app`
    /// 与 `~/Library/Preferences/com.google.Chrome.app.<hash>.plist` 配对，
    /// 并给配置项打上「随应用一起卸载」的提示。
    ///
    /// 为什么需要它：PWA 的偏好/登录态存在 Library 里这份 plist 中，扫出来的
    /// `.app`（appBundle 组）和 plist（libraryData 组）是两项独立 artifact。
    /// 用户若只删 .app，plist 就变成无主残留。配对后 UI 联动勾选（删 app 必删配置），
    /// 保证卸载干净。配置项单独改不影响 app —— 删配置保留 app 是合理的（清空登录态）。
    private func linkPWACompanions() {
        pwaAppToCompanion = [:]
        guard let app = matchedApp, app.isPWA,
              let pwaID = app.bundleId?.split(separator: ".").last.map({ String($0).lowercased() }),
              pwaID.count >= 8 else { return }

        guard let appIdx = artifacts.firstIndex(where: { $0.category == .appBundle }),
              let cfgIdx = artifacts.firstIndex(where: {
                  $0.category == .libraryData &&
                  pwaPlistNames(for: pwaID).contains(
                      ($0.path as NSString).lastPathComponent.lowercased()
                  )
              }) else { return }

        pwaAppToCompanion[artifacts[appIdx].id] = artifacts[cfgIdx].id
        artifacts[cfgIdx].note = L10n.t("PWA 配置 · 随应用一起卸载",
                                        "PWA config · removed together with the app")
    }

    /// Chrome / Edge PWA 在 ~/Library/Preferences 下常见的 plist 文件名。
    /// app bundleId 末段就是 <hash>，用 hash 而不是完整 bundleId 去配对，
    /// 因为 PWA 的 bundleId 可能被签名/分发者改写（如 com.citrolabs.ego.lite.app.<hash>），
    /// 但对应的 plist 文件名仍是 com.google.Chrome.app.<hash>.plist。
    private func pwaPlistNames(for pwaID: String) -> Set<String> {
        return [
            "com.google.chrome.app.\(pwaID).plist",
            "com.microsoft.edgemac.app.\(pwaID).plist"
        ]
    }

    /// 同名候选（用于提示用户"你是不是想找另一个"）。
    ///
    /// 只保留别名里**完整包含 target 作为独立词**的 app，避免模糊子串匹配
    /// 把无关 app（如搜 "AI Mac Cleaner" 却列出 ChatGPT）也塞进来。
    /// `nonisolated`：同上，skill 层在 MainActor 之外调用它。
    nonisolated static func candidates(for target: String) -> [AppIdentity] {
        let q = target.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return [] }
        let apps = InventoryCache.shared.allApps()
        let separators = CharacterSet(charactersIn: " -_.")
        return apps.filter { app in
            app.aliases.contains { alias in
                alias == q || alias.components(separatedBy: separators).contains(q)
            }
        }
        .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    /// 用户从候选列表里改选了另一个 app，按它重扫。
    func scan(app: AppIdentity) async {
        guard fullDiskAccessGranted else { showFDAGuidance = true; return }
        isScanning = true
        lastError = nil
        plan = nil
        defer { isScanning = false }

        matchedApp = app
        searchText = app.displayName
        let query = ScanQuery(raw: app.displayName, app: app, others: InventoryCache.shared.allApps())

        var allArtifacts: [Artifact] = []
        for scanner in scanners {
            allArtifacts.append(contentsOf: await scanner.scan(query: query))
        }
        var seen = Set<String>()
        allArtifacts = allArtifacts.filter { seen.insert($0.path).inserted }
        // 应用页默认全选（含用户数据）。
        for i in allArtifacts.indices { allArtifacts[i].selected = true }
        artifacts = allArtifacts
        plan = RemovalPlan(targetName: app.displayName, artifacts: allArtifacts)
        linkPWACompanions()
        aiReviewPhaseApps = .idle
    }

    // MARK: - v1.2 app 列表

    /// 加载左侧 app 列表。
    func loadAppList() async {
        guard allApps.isEmpty, !isLoadingApps else { return }
        isLoadingApps = true
        defer { isLoadingApps = false }
        let apps = await Task.detached { InventoryCache.shared.allApps() }.value
        allApps = apps
    }

    /// 按搜索框过滤 app 列表。空串时返回全部。
    var filteredApps: [AppIdentity] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return allApps }
        return AppInventory.search(q, in: allApps)
    }

    // MARK: - 残留扫描（v1.2 孤儿 + v1.5 AI 工具合并）

    func scanLeftovers() async {
        guard fullDiskAccessGranted else { showFDAGuidance = true; return }
        isScanningLeftovers = true
        defer {
            isScanningLeftovers = false
            hasScannedLeftovers = true
        }
        // 整段丢到后台线程：两个扫描器内部都是同步阻塞调用（递归读盘 + 起 du 子进程）。
        let groups = await Task.detached(priority: .userInitiated) {
            let live = InventoryCache.shared.liveBundleIds()
            async let orphanGroups = OrphanScanner.scanAll(liveIds: live)
            async let aiGroups = AIAgentScanner.scanAll()
            async let toolGroups = AIToolLeftovers.scanGroups()
            async let orphanCacheGroups = OrphanCacheScanner.scanGroups()
            let pkgGroups = PkgReceiptScanner.scanAll(liveIds: live)
            return await orphanGroups + aiGroups + toolGroups + orphanCacheGroups + pkgGroups
        }.value
        leftoverGroups = groups
        // 每次扫描完默认全部折叠：group id 是本次新生成的，按默认折叠让用户逐一点开。
        // 折叠状态提升到 AppState（见 leftoverCollapsed），切 tab 后视图重建也不会重置。
        leftoverCollapsed = Set(groups.map(\.id))
        aiReviewPhaseLeftovers = .idle
    }

    /// 引导页点「我已授权」后调用：重测 FDA，若已授权则按当前 tab 重扫。
    ///
    /// - 返回是否已获得授权（false 时引导页应提示「仍未检测到授权」）。
    /// - 重扫走原扫描入口：apps tab 用 searchText 重扫、leftovers tab 扫残留。
    ///   processes tab 本就不需要 FDA，这里也兜住；askAI 不需要扫描。
    @discardableResult
    func recheckFullDiskAccessAndResume() -> Bool {
        fullDiskAccessGranted = PrivacyAccess.hasFullDiskAccess()
        guard fullDiskAccessGranted else { return false }
        showFDAGuidance = false
        let tab = selectedTab
        let term = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            switch tab {
            case .apps:
                if !term.isEmpty { await scan() }
            case .leftovers:
                await scanLeftovers()
            case .processes:
                await scanProcesses()
            case .askAI:
                break
            }
        }
        return true
    }

    /// 当前筛选档下可见的残留分组。
    var visibleLeftoverGroups: [LeftoverGroup] {
        switch leftoverFilter {
        case .all:      return leftoverGroups
        case .orphan:   return leftoverGroups.filter { $0.source == .orphan }
        case .aiTool:   return leftoverGroups.filter { $0.source == .aiTool }
        case .devCache: return leftoverGroups.filter { $0.source == .devCache }
        }
    }

    var leftoverSelectedArtifacts: [Artifact] {
        leftoverGroups.flatMap { $0.artifacts.filter(\.selected) }
    }

    var leftoverTotalSize: Int64 {
        leftoverGroups.reduce(0) { $0 + $1.totalSize }
    }

    var leftoverSelectedSize: Int64 {
        leftoverGroups.reduce(0) { $0 + $1.selectedSize }
    }

    var leftoverSelectedCount: Int {
        leftoverGroups.reduce(0) { $0 + $1.selectedCount }
    }

    /// 当前筛选档下可见项总数（BottomActionBar 用它判断「是否已全选」）。
    var leftoverVisibleCount: Int {
        visibleLeftoverGroups.reduce(0) { $0 + $1.artifacts.count }
    }

    /// 当前筛选档下已选项数。
    var leftoverVisibleSelectedCount: Int {
        visibleLeftoverGroups.reduce(0) { $0 + $1.selectedCount }
    }

    /// 更新某个残留分组的某一项勾选状态。
    func setLeftoverSelected(groupId: UUID, artifactId: UUID, selected: Bool) {
        guard let gi = leftoverGroups.firstIndex(where: { $0.id == groupId }),
              let ai = leftoverGroups[gi].artifacts.firstIndex(where: { $0.id == artifactId })
        else { return }
        leftoverGroups[gi].artifacts[ai].selected = selected
    }

    func setLeftoverGroupSelected(groupId: UUID, selected: Bool) {
        guard let gi = leftoverGroups.firstIndex(where: { $0.id == groupId }) else { return }
        for i in leftoverGroups[gi].artifacts.indices {
            leftoverGroups[gi].artifacts[i].selected = selected
        }
    }

    // MARK: - Agent skill 结果落地

    /// 把 `scan_app` / `plan_uninstall` 的扫描结果搬到「应用」页。
    ///
    /// 存在的理由：skill 层跑在 MainActor 之外（CLI 路径不能碰主 actor），
    /// 拿到的是纯数据。这几个方法是数据回到界面的唯一入口，顺带补上
    /// `plan`、`hasScanned*` 这些 `private(set)` 的派生状态 ——
    /// 少设一个，界面就会停在「还没扫过」的空态上，而结果其实已经有了。
    func applyScanResult(target: String, app: AppIdentity?, artifacts: [Artifact]) {
        searchText = target
        matchedApp = app
        ambiguousMatches = Self.candidates(for: target)
        self.artifacts = artifacts
        plan = RemovalPlan(targetName: target, artifacts: artifacts)
        lastError = nil
    }

    func applyLeftovers(_ groups: [LeftoverGroup]) {
        leftoverGroups = groups
        hasScannedLeftovers = true
    }

    func applyProcesses(_ list: [LiveProcess]) {
        processes = list
        hasScannedProcesses = true
        selectedPids.removeAll()
    }

    // MARK: - AI 分析

    /// 从应用 / 残留 / 进程页的「问 AI」入口深链到问 AI 页：写入预填问句并切到该 tab。
    /// AskAIView 在 onAppear / onChange 时读取它、灌入输入框并聚焦，消费后置 nil。
    /// 预填问句会引导 Agent 走 `review_plan` skill，结论通过 SkillEffect 回写勾选与理由。
    ///
    /// - Parameter scope: 残留页深链时传入的当前筛选档来源（`.all` 传 nil）。
    ///   非 nil 时 Agent 只分析该来源，实现「看哪一档就判断哪一档」。
    func jumpToAskAI(_ prompt: String, leftoverScope: LeftoverSource? = nil, reviewScope: ReviewScope? = nil) {
        // 从应用 / 残留 / 进程页深链过来是为了做一次独立的 AI 分析，旧对话上下文对
        // 分析毫无用处（模型分析读的是 session 里的清单，不是 chat 历史）。
        // 打一条上下文锚点：屏幕记录保留可见，但模型历史截断到锚点之后，
        // 这样本次注入的分析 prompt 不会带上之前的噪音。
        resetChatContext()
        askAIPendingPrompt = prompt
        askAIPendingLeftoverScope = leftoverScope
        askAIPendingReviewScope = reviewScope
        selectedTab = .askAI
    }

    /// 在后台触发一次 AI 分析：把 prompt 发到「问 AI」对话框并运行 Agent，
    /// 但不切换 `selectedTab`。分析结论会写入对应清单，AI 总结消息会出现在 chat 里。
    /// 完成后 banner 显示「去看 AI 怎么说」，用户手动切到问 AI 页查看结论。
    func runAIReviewInBackground(prompt: String,
                                  leftoverScope: LeftoverSource? = nil,
                                  reviewScope: ReviewScope? = nil) {
        guard modelStore.isConfigured, let cfg = activeConfig else {
            if reviewScope == .leftovers { aiReviewPhaseLeftovers = .needsConfig }
            else { aiReviewPhaseApps = .needsConfig }
            return
        }

        // 独立上下文：旧对话对这次分析无意义，打锚点截断。
        resetChatContext()

        if reviewScope == .leftovers { aiReviewPhaseLeftovers = .running }
        else { aiReviewPhaseApps = .running }
        chatIsThinking = true

        let history = chatModelHistory
        appendChat(AIMessage(role: .me, text: prompt))

        Task { @MainActor in
            let bridge = AgentBridge()
            bridge.attach(self)
            let runtime = AgentRuntime(config: cfg, bridge: bridge, memory: memoryPromptBlock)
            let run = await runtime.run(goal: prompt, history: history,
                                        session: bridge.makeSession(leftoverScope: leftoverScope,
                                                                     reviewScope: reviewScope))

            var body = run.answer
            if let note = run.note { body += "\n\n" + note }
            appendChat(AIMessage(role: .ai, text: body,
                                 steps: run.steps,
                                 redirect: run.redirect,
                                 awaitingApproval: run.awaitingApproval))
            chatIsThinking = false
            // skill 的 effect 已通过 bridge.apply 设置对应 phase = .done；
            // 这里兜底：若模型调用失败没走到 skill，把 still-running 标记为失败。
            if reviewScope == .leftovers {
                if aiReviewPhaseLeftovers == .running { aiReviewPhaseLeftovers = .failed }
            } else {
                if aiReviewPhaseApps == .running { aiReviewPhaseApps = .failed }
            }
        }
    }

    /// 把模型对应用清单的分析结论落到界面：
    /// - 被判定为「建议保留」的项取消勾选并写入理由；
    /// - 被判定为「可安全删除」的项保持勾选并写入 AI 可删标签。
    /// 这是 SkillEffect.reviewApps 的落地点，**不得在此再次调用模型**。
    func applyAIReviewApps(verdicts: [UUID: AIVerdict]) {
        for i in artifacts.indices {
            guard let verdict = verdicts[artifacts[i].id] else { continue }
            artifacts[i].aiVerdict = verdict
            switch verdict {
            case .keep:
                artifacts[i].selected = false
            case .safe:
                artifacts[i].selected = true
            }
        }
        aiReviewPhaseApps = .done
        // 分析结论写在每行下方，分组折叠时用户看不到；自动展开所有分类。
        appsCollapsed = []
        // PWA「卸载单元」：配置项的去留必须跟随应用本体，否则删 app 会留孤儿。
        // AI 是逐项判定的，可能给配置单独下了结论，这里强制把它拉回本体的状态。
        syncPWAAfterReview()
    }

    /// AI 分析落盘后，把 PWA 跟随配置项的选中态强制对齐到应用本体。
    /// 配置随 app 一起删 / 一起留——它自身被单独判 keep 也不会保留下来，
    /// 因为本体要删时它必然一起删；本体保留时它自然也保留。
    private func syncPWAAfterReview() {
        for (appId, companionId) in pwaAppToCompanion {
            guard let appIdx = artifacts.firstIndex(where: { $0.id == appId }),
                  let cfgIdx = artifacts.firstIndex(where: { $0.id == companionId }) else { continue }
            artifacts[cfgIdx].selected = artifacts[appIdx].selected
        }
    }

    /// 把模型对残留清单的分析结论落到界面：被判定为「可安全删除」的项勾选并写入理由。
    /// 这是 SkillEffect.reviewLeftovers 的落地点，**不得在此再次调用模型**。
    func applyAIReviewLeftovers(verdicts: [UUID: AIVerdict]) {
        for gi in leftoverGroups.indices {
            for ai in leftoverGroups[gi].artifacts.indices {
                let id = leftoverGroups[gi].artifacts[ai].id
                guard let verdict = verdicts[id] else { continue }
                leftoverGroups[gi].artifacts[ai].aiVerdict = verdict
                switch verdict {
                case .safe:
                    leftoverGroups[gi].artifacts[ai].selected = true
                case .keep:
                    leftoverGroups[gi].artifacts[ai].selected = false
                }
            }
        }
        aiReviewPhaseLeftovers = .done
        // 分析结论需要让用户逐条看到，自动展开所有残留分组。
        leftoverCollapsed = []
    }

    /// 撤销 AI 分析结论，恢复默认选中状态。
    func undoAIReview() {
        for i in artifacts.indices { artifacts[i].aiVerdict = nil }
        for gi in leftoverGroups.indices {
            for ai in leftoverGroups[gi].artifacts.indices {
                leftoverGroups[gi].artifacts[ai].aiVerdict = nil
            }
        }
        // 应用页恢复默认全选；残留页恢复默认全不选。
        for i in artifacts.indices { artifacts[i].selected = true }
        for gi in leftoverGroups.indices {
            for ai in leftoverGroups[gi].artifacts.indices {
                leftoverGroups[gi].artifacts[ai].selected = false
            }
        }
        aiReviewPhaseApps = .idle
        aiReviewPhaseLeftovers = .idle
    }

    // MARK: - 进程管理

    /// 枚举全部进程并分类（含 0.25s CPU 采样）。整段丢后台线程：
    /// 采样中间有停顿，且 proc_pidinfo 虽是 syscall，但几百个进程两遍调用
    /// 加上停顿不能干在主线程。
    func scanProcesses() async {
        isScanningProcesses = true
        defer {
            isScanningProcesses = false
            hasScannedProcesses = true
        }
        let list = await Task.detached(priority: .userInitiated) {
            ProcessLister.snapshot()
        }.value
        processes = list
        // 重扫后旧的 pid 集合大概率失效，清空重选，避免误杀不认识的进程。
        selectedPids.removeAll()
    }

    /// 已勾选且可杀的进程（系统 / 自身会被 isKillable 拦掉）。
    var selectedProcesses: [LiveProcess] {
        processes.filter { selectedPids.contains($0.pid) && $0.isKillable }
    }

    var selectedProcessCount: Int { selectedProcesses.count }

    /// 选中进程占用的常驻内存合计（约可释放量）。
    var selectedMemoryBytes: Int64 {
        selectedProcesses.reduce(0) { $0 + $1.memoryBytes }
    }

    func toggleProcessSelected(_ pid: pid_t) {
        if selectedPids.contains(pid) { selectedPids.remove(pid) }
        else { selectedPids.insert(pid) }
    }

    /// 勾选 / 取消勾选当前可见且可杀的全部进程。
    func setAllVisibleSelected(_ selected: Bool) {
        let visible = visibleProcesses.filter(\.isKillable)
        for p in visible {
            if selected { selectedPids.insert(p.pid) }
            else { selectedPids.remove(p.pid) }
        }
    }

    /// 结束选中的进程，返回实际结束的数量。调用方负责先弹二次确认。
    @discardableResult
    func killSelectedProcesses() -> Int {
        let targets = selectedProcesses
        guard !targets.isEmpty else { return 0 }
        let pids = targets.map(\.pid)
        let n = ProcessTerminator.terminate(pids: pids)
        selectedPids.removeAll()
        return n
    }

    /// 进程被 AI 判定过的「结束后果」，按 pid 索引。进程页用于逐行展示。
    @Published var processVerdicts: [pid_t: ProcessVerdict] = [:]

    /// 让 AI 判断结束这些进程的后果，写入 `processVerdicts`。
    /// 低风险进程自动勾选，中/高风险自动取消勾选。
    /// 返回 true = 模型已响应；false = 未配置模型或调用失败。
    @discardableResult
    func aiJudgeProcesses(_ targets: [LiveProcess]) async -> Bool {
        guard let cfg = modelStore.active else { return false }
        let verdicts = await AIJury.judgeProcesses(targets, config: cfg)
        guard let verdicts else { return false }
        processVerdicts = verdicts
        // 低风险 → 勾选；中/高风险 → 取消勾选
        for (pid, v) in verdicts {
            if v.level == .low {
                selectedPids.insert(pid)
            } else {
                selectedPids.remove(pid)
            }
        }
        return true
    }

    /// 清空 AI 进程判定（比如杀完进程后 pid 已失效）。
    func clearProcessVerdicts() {
        processVerdicts = [:]
    }

    /// 卸载完成后：文件系统变了，缓存和列表都要重建。
    func invalidateInventory() {
        InventoryCache.shared.invalidate()
        allApps = []
        Task { await loadAppList() }
    }

    /// 把「应用」页恢复成刚进页面的样子：搜索框、扫描结果、锁定的 app 一起清掉。
    ///
    /// 为什么不能只清 `searchText`：右侧仍会挂着上一轮结果，
    /// 侧栏「本次可回收」也还在报一个已经不在屏幕上的数字 ——
    /// 用户看到的和他刚做的动作对不上。
    func clear() {
        searchText = ""
        plan = nil
        artifacts = []
        lastError = nil
        matchedApp = nil
        ambiguousMatches = []
        pwaAppToCompanion = [:]
        aiReviewPhaseApps = .idle
    }

    func selectAll() {
        for i in artifacts.indices { artifacts[i].selected = true }
    }

    func deselectAll() {
        for i in artifacts.indices { artifacts[i].selected = false }
    }

    func setPlanWithSelections() {
        guard let plan = plan else { return }
        self.plan = RemovalPlan(targetName: plan.targetName, artifacts: artifacts)
    }

    init() {
        lastLanguage = L10n.override.rawValue
        NotificationCenter.default
            .publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                let current = L10n.override.rawValue
                guard current != self.lastLanguage else { return }
                self.lastLanguage = current
                // 语言变化时主动推一把 objectWillChange，确保所有依赖
                // @EnvironmentObject(state) 的视图都重建，从而重新取文案。
                self.objectWillChange.send()
            }
            .store(in: &cancellables)

        // 「问 AI」历史恢复。放在 init 末尾 —— 全进程只跑一次。
        restoreChat()
        restoreMemory()

        // 完全磁盘访问权限：冷启动检测一次。
        fullDiskAccessGranted = PrivacyAccess.hasFullDiskAccess()
        // app 从后台回到前台（用户在系统设置里授权完切回来）时重测，
        // 这样引导页点「我已授权」后无需手动刷新即可继续。
        NotificationCenter.default
            .publisher(for: NSApplication.didBecomeActiveNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.fullDiskAccessGranted = PrivacyAccess.hasFullDiskAccess()
            }
            .store(in: &cancellables)
    }
}
