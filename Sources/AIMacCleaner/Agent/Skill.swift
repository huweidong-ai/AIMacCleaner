import Foundation

/// # Skill 层
///
/// 把 AI Mac Cleaner 的能力切成一组**可被 Agent 调用的原子技能**。
///
/// 设计约束（三条，都是硬的）：
/// 1. **每个 skill 必须对应一条真实存在的 AI Mac Cleaner CLI 命令**。`SkillSpec.cli` 不是
///    装饰性文案，自检会拿它跟 `--help` 对表 —— 写了却不存在的命令属于假成功。
/// 2. **skill 不碰 UI、不隔离到 MainActor**。它是纯逻辑：吃参数、出结果 + 一个
///    `SkillEffect`（数据）。谁来消费 effect 由宿主决定 —— GUI 写进 `AppState`，
///    CLI 直接打印。这样同一套 skill 在两个入口下行为一致。
/// 3. **skill 不删任何东西**。最高危的 `plan_uninstall` 也只做预演汇总。真正的
///    删除永远发生在用户点过确认弹窗之后（GUI）或用户显式敲 `--uninstall`（CLI）。

// MARK: - 风险等级

/// skill 的副作用等级。Agent 运行时按这个决定要不要拦。
enum SkillRisk: String, Codable {
    /// 只读：扫描、枚举、查历史。Agent 可以随便调。
    case readOnly
    /// 会改动应用内状态（勾选项、当前清单），但不碰磁盘。
    case mutating
    /// 涉及删除语义 —— **Agent 只能拿到预演结果**，执行必须由人确认。
    case destructive

    var label: String {
        switch self {
        case .readOnly:    return L10n.t("只读", "read-only")
        case .mutating:    return L10n.t("改状态", "mutates state")
        case .destructive: return L10n.t("需确认", "needs approval")
        }
    }
}

// MARK: - 参数

/// 一个 skill 参数的声明。用于生成给模型看的清单，以及调用前的校验。
struct SkillArg {
    let name: String
    let required: Bool
    /// 给模型看的说明（含取值范围）。
    let desc: String
    /// 枚举型参数的合法值；空表示自由文本。
    var options: [String] = []

    func validate(_ value: String?) -> String? {
        guard let v = value, !v.trimmingCharacters(in: .whitespaces).isEmpty else {
            return required ? L10n.t("缺少必填参数 \(name)", "Missing required argument \(name)") : nil
        }
        if !options.isEmpty, !options.contains(v.lowercased()) {
            return L10n.t("参数 \(name) 只能是 \(options.joined(separator: " / "))",
                          "Argument \(name) must be one of \(options.joined(separator: " / "))")
        }
        return nil
    }
}

/// 一次调用带来的实参。统一按字符串存，取用时再转型 —— 模型给的 JSON
/// 里数字、布尔、字符串混着来，统一成字符串比逐个做类型协商省事得多。
struct SkillArgs {
    private let raw: [String: String]

    init(_ raw: [String: String] = [:]) {
        self.raw = raw.reduce(into: [:]) { $0[$1.key.lowercased()] = $1.value }
    }

    subscript(_ key: String) -> String? {
        let v = raw[key.lowercased()]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (v?.isEmpty ?? true) ? nil : v
    }

    func string(_ key: String, default fallback: String) -> String {
        self[key] ?? fallback
    }

    func bool(_ key: String, default fallback: Bool = false) -> Bool {
        guard let v = self[key]?.lowercased() else { return fallback }
        return ["true", "1", "yes", "y", "是"].contains(v)
    }

    func int(_ key: String, default fallback: Int) -> Int {
        guard let v = self[key], let n = Int(v) else { return fallback }
        return n
    }

    var isEmpty: Bool { raw.isEmpty }

    /// 回显成 CLI 风格，用于 UI 上的「执行了什么」标签。
    var inlineDescription: String {
        raw.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " ")
    }
}

// MARK: - 结果与副作用

/// Agent 层跨越 MainActor 边界时用的 tab 标识。
///
/// 为什么不直接用 `@MainActor` 的 `AppState.Tab`：skill 层是**非隔离**的
/// （CLI 路径不能碰主 actor），而嵌套在 `@MainActor class AppState` 里的
/// `Tab` 类型本身也带主 actor 隔离，非隔离代码引用它会编译失败。
/// 所以这里放一份纯数据的副本，到 `AgentBridge` / `AskAIView`（都是 MainActor）
/// 再映射回 `AppState.Tab`。
enum AgentTab: String, Codable, Sendable {
    case apps, leftovers, processes

    var displayName: String {
        switch self {
        case .apps:      return L10n.t("应用", "Apps")
        case .leftovers: return L10n.t("残留", "Leftovers")
        case .processes: return L10n.t("进程", "Processes")
        }
    }
}

/// skill 产出的界面副作用。**只是数据**，由宿主决定怎么落地：
/// GUI 写进 `AppState` 并跳 tab，CLI 打印。
enum SkillEffect {
    case none
    /// 扫描了某个目标，得到一批痕迹。
    case appScan(target: String, app: AppIdentity?, artifacts: [Artifact])
    /// 残留扫描结果。
    case leftovers([LeftoverGroup])
    /// 进程快照。
    case processes([LiveProcess])
    /// 对当前应用清单跑复核。关联字典是模型判定的「建议保留项」理由（UUID -> reason），
    /// 宿主直接按这个写 aiVerdict 与 selected，**禁止再调一次模型**。
    case reviewApps([UUID: String])
    /// 对当前残留清单跑复核。关联字典是模型判定的「可安全删除项」理由（UUID -> reason）。
    case reviewLeftovers([UUID: String])
}

/// skill 的执行结果。
struct SkillResult {
    let ok: Bool
    /// 一句话结论，直接给人看。
    let summary: String
    /// 回喂给模型的观测文本。比 summary 详细，但要控制长度 —— 每一轮都会
    /// 进 prompt，扫描结果动辄几百项，全塞进去只会挤爆上下文。
    let observation: String
    var effect: SkillEffect = .none
    /// 建议跳转的 tab（GUI 用）。
    var redirect: AgentTab? = nil
    /// 是否在等用户确认（destructive skill 恒为 true）。
    var awaitingApproval: Bool = false

    static func failure(_ message: String) -> SkillResult {
        SkillResult(ok: false, summary: message, observation: "ERROR: \(message)")
    }
}

// MARK: - 协议

/// 一个可被 Agent 调用的技能。
protocol AgentSkill {
    var spec: SkillSpec { get }
    /// 执行。**实现里不得触发任何删除**。
    func invoke(_ args: SkillArgs, session: AgentSession) async -> SkillResult
}

/// skill 的静态声明部分。注册表靠它生成模型清单和 `--skills` 输出。
///
/// `summaryZh` / `summaryEn` 是双语原文，`summary` 按当前语言取 —— 不能直接
/// 存 `summary: String` 然后在 init 里调 `L10n.t()`，那会在 struct 首次实例化
/// 时把一种语言固化成 String，再切换语言也不变。
struct SkillSpec {
    let name: String
    /// 对应的真实 AI Mac Cleaner CLI 命令（自检会核对它确实被 `--help` 收录）。
    let cli: String
    let summaryZh: String
    let summaryEn: String
    var args: [SkillArg] = []
    var risk: SkillRisk = .readOnly

    /// 跟随客户端语言取文案。其他读取处请用这个，不要直接读 `summaryZh` / `summaryEn`。
    var summary: String { L10n.t(summaryZh, summaryEn) }

    /// 生成给模型看的一行声明。
    var manifestLine: String {
        var line = "- \(name)"
        if !args.isEmpty {
            let sig = args.map { $0.required ? "<\($0.name)>" : "[\($0.name)]" }.joined(separator: " ")
            line += " \(sig)"
        }
        line += "：\(summary)"
        for a in args {
            var detail = "\(a.name)"
            if !a.options.isEmpty { detail += "(\(a.options.joined(separator: "|")))" }
            line += "\n    · \(detail) — \(a.desc)"
        }
        if risk == .destructive {
            line += "\n    · " + L10n.t("高危：只会返回预演结果，实际删除必须由用户确认",
                                        "destructive: returns a preview only; the user must approve the real removal")
        }
        return line
    }
}

// MARK: - 复核范围

/// 深链进入「问 AI」页时由界面入口注入的复核目标：
/// `.apps` 表示复核当前已安装应用的扫描清单，`.leftovers` 表示复核残留清单。
/// 显式注入后 `review_plan` 不再依赖模型自行推断 scope，避免应用页被误判为残留。
enum ReviewScope: String, CaseIterable, Identifiable, Hashable {
    case apps = "apps"
    case leftovers = "leftovers"

    var id: String { rawValue }
}

// MARK: - 会话状态

/// 一次 Agent 会话里跨 skill 共享的中间状态。
///
/// 存在的理由很实际：扫描是这个 app 里最慢的操作（几秒到十几秒）。
/// 模型说「扫 Cursor，然后复核一下」时，`review_plan` 必须能拿到
/// 上一步 `scan_app` 的结果，而不是再扫一遍。
/// 单条 Agent 运行里只会有一个 session、被同一个 async 任务串行访问，
/// 不存在并发写，因此用 `@unchecked Sendable` 跨 MainActor 边界传递
/// （GUI 入口把 session 交给 `AgentRuntime.run`，CLI 入口在 detached task 内自建）。
final class AgentSession: @unchecked Sendable {
    /// 上一次 `scan_app` 锁定的目标名。
    var lastTarget: String?
    /// 上一次 `scan_app` 的痕迹清单。
    var lastArtifacts: [Artifact] = []
    /// 上一次残留扫描结果。
    var lastLeftovers: [LeftoverGroup] = []
    /// 残留深链时由「残留」页当前筛选档注入的来源约束：
    /// 非 nil 时 `review_plan` 只复核该类残留（如 .aiTool），nil 表示判断全部。
    /// 这样「我在看哪一档，AI 就帮我判断哪一档」，既不重复扫、也不会被迫全量判断。
    var reviewLeftoverFilter: LeftoverSource? = nil
    /// 用户在残留页主动勾选后点「让 AI 帮我判断」时传入的清单。
    /// `review_plan(scope: leftovers)` 优先复核这些项，而不是当前范围的全部残留。
    var reviewableLeftovers: [Artifact] = []
    /// 宿主注入的「当前界面上的清单」。GUI 打开时是应用页的实时勾选状态，
    /// CLI 下为空 —— skill 通过它实现「复核我当前的删除清单」。
    var hostArtifacts: [Artifact] = []
    /// 深链注入的复核范围。非 nil 时，`review_plan` 强制按此范围执行，
    /// 不再让模型自行选择 apps / leftovers，避免应用页被误判为残留。
    var reviewScope: ReviewScope? = nil

    init() {}

    /// 复核作用的清单：优先用界面上的，其次用本会话扫出来的。
    var reviewableArtifacts: [Artifact] {
        hostArtifacts.isEmpty ? lastArtifacts : hostArtifacts
    }
}
