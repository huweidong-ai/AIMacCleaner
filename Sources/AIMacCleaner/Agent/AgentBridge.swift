import Foundation
import Combine

/// GUI 侧的 Agent 宿主。
///
/// skill 本身是纯逻辑、不隔离到 MainActor（否则 CLI 路径会在信号量上死锁）。
/// 副作用怎么落地由宿主决定 —— 这个类就是「落到界面上」的那一半：
/// 把 `SkillEffect` 写进 `AppState`，并把执行进度暴露给「问 AI」页。
///
/// CLI 不创建它，于是整条 Agent 链在命令行下完全不碰 MainActor。
@MainActor
final class AgentBridge: ObservableObject {
    /// 由「问 AI」页在 onAppear 时注入。设计成后注入而非构造注入，
    /// 是为了让视图能用 `@StateObject` 持有它 —— 只有这样 `@Published`
    /// 的进度更新才会真正驱动界面刷新。
    private weak var state: AppState?

    /// 当前正在执行的命令（形如 `ai-mac-cleaner --scan Cursor`），nil 表示空闲。
    @Published private(set) var runningCommand: String?
    /// 本次运行已完成的步骤，供 UI 实时展开。
    @Published private(set) var steps: [AgentStep] = []

    init() {}

    func attach(_ state: AppState) {
        self.state = state
    }

    /// 清掉**本次运行的实时进度**（正在跑的命令 + 已完成的步骤）。
    ///
    /// ⚠️ 语义边界，别再误会一次：它跟「对话上下文」**毫无关系**。
    /// `send()` 在请求前后各调一次，本来就是幂等的运行态清理。
    /// `/reset` 的上下文语义由 `AppState.resetChatContext()`（打锚点）承担 ——
    /// `/reset` 路径上两者**都要调**，但职责不同，不要把其中一个删掉。
    func reset() {
        runningCommand = nil
        steps = []
    }

    /// skill 即将执行 —— 让用户马上看到「它在干什么」，而不是干等一个转圈。
    func willRun(spec: SkillSpec, command: String) {
        runningCommand = command
    }

    func finish(_ step: AgentStep) {
        steps.append(step)
        runningCommand = nil
    }

    /// 把 skill 的副作用落到界面状态上。
    func apply(_ effect: SkillEffect) async {
        guard let state else { return }
        switch effect {
        case .none:
            break
        case .appScan(let target, let app, let artifacts):
            state.applyScanResult(target: target, app: app, artifacts: artifacts)
        case .slimPlan(let target, let app, let mode, let artifacts):
            state.applySlimPlan(target: target, app: app, mode: mode, artifacts: artifacts)
        case .leftovers(let groups):
            state.applyLeftovers(groups)
        case .processes(let list):
            state.applyProcesses(list)
        case .reviewApps(let verdicts):
            state.applyAIReviewApps(verdicts: verdicts)
        case .reviewLeftovers(let verdicts):
            state.applyAIReviewLeftovers(verdicts: verdicts)
        case .proposedArtifacts(_, let artifacts):
            state.applyAIProposals(artifacts)
        }
    }

    /// 把界面上「当前这份清单」交给会话 —— 用户说「分析我现在选的这些」时，
    /// 分析的必须是他眼前的勾选状态，不是 Agent 自己扫出来的另一份。
    /// 应用清单走 `hostArtifacts`、残留清单走 `lastLeftovers`，两者都从当前界面注入，
    /// 这样从任一 tab 深链进来都能让 Agent 直接分析「眼前这份」，不必先重新扫描。
    ///
    /// - Parameters:
    ///   - leftoverScope: 残留深链时传入的「当前筛选档来源」。
    ///     `nil` 表示判断全部；非 nil（如 `.aiTool`）让 `review_plan` 只分析该类，
    ///     实现「看哪一档就判断哪一档」。
    ///   - reviewScope: 强制分析范围。非 nil 时 `review_plan` 不再让模型猜
    ///     apps / leftovers，而是直接按此执行，避免应用页被误判为残留。
    func makeSession(leftoverScope: LeftoverSource? = nil,
                     reviewScope: ReviewScope? = nil) -> AgentSession {
        let session = AgentSession()
        session.hostArtifacts = state?.artifacts ?? []
        session.lastLeftovers = state?.leftoverGroups ?? []
        // 把用户在残留页主动勾选的项单独拎出来：点「让 AI 帮我判断」时，
        // AI 应该只分析这些已勾选项；没有勾选时才退而分析当前范围全部。
        session.reviewableLeftovers = state?.leftoverGroups.flatMap { group in
            group.artifacts.filter { $0.selected }
        } ?? []
        session.reviewLeftoverFilter = leftoverScope
        session.reviewScope = reviewScope
        // 应用清单已就绪就直接用；为空（首次启动还没进过应用页）留给
        // `fillInstalledAppNames` 在后台现取，避免在这里卡主线程。
        if !state.allApps.isEmpty {
            session.installedAppNames = state.allApps.map(\.displayName)
        }
        return session
    }

    /// 给 session 补上本机已装应用名单。`InventoryCache` 带缓存，
    /// 首次冷启动之外只是一次读盘。
    func fillInstalledAppNames(_ session: AgentSession) async {
        if let existing = session.installedAppNames, !existing.isEmpty { return }
        let names = await Task.detached(priority: .utility) {
            InventoryCache.shared.allApps().map(\.displayName)
        }.value
        session.installedAppNames = names
    }
}
