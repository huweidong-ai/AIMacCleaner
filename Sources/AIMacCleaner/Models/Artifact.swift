import Foundation

/// 11 类基础痕迹 + 3 个包管理器专属类。v1 全部启用。
///
/// **raw value 是持久化标识，不要本地化它。** `HistoryStore` 把
/// `category.rawValue` 写进 `history.jsonl`，改动会让旧记录对不上。
/// 界面文案走 `displayName`。
enum ArtifactCategory: String, CaseIterable, Codable, Hashable {
    case appBundle      = "App bundle"
    case cliBinary      = "CLI binary"
    case brewFormula    = "Brew formula"
    case brewCask       = "Brew cask"
    case launchAgent    = "Launch agent"
    case runningProcess = "Running process"
    case xdgUserData    = "XDG user data"
    case libraryData    = "Library user data"
    // 这两个的 raw value 是中文，是 v1.1 就写进历史记录的既成事实。
    // 别为了「统一成英文」去改 —— 那会让 v1.1/v1.2 的历史记录解不出来。
    case container      = "沙箱容器"
    case groupContainer = "共享容器"
    case dotfile        = "Dotfile"
    case shellRc        = "Shell rc 污染"
    case authToken      = "Auth token"
    case npmGlobal      = "npm global"
    case pipxVenv       = "pipx venv"
    case masApp         = "Mac App Store"
    case toolCache      = "Tool cache"
    /// pkg 安装收据（/var/db/receipts 下的 *.plist / *.bom）。root 所有，
    /// app 无权限直接删除（也无提权机制），只能提示用户用 sudo 手动清理。
    case pkgReceipt     = "Pkg receipt"

    /// 界面显示名（双语）。
    var displayName: String {
        switch self {
        case .appBundle:      return L10n.t("App bundle", "App bundle")
        case .cliBinary:      return L10n.t("命令行程序", "CLI binary")
        case .brewFormula:    return L10n.t("Brew formula", "Brew formula")
        case .brewCask:       return L10n.t("Brew cask", "Brew cask")
        case .launchAgent:    return L10n.t("启动项", "Launch agent")
        case .runningProcess: return L10n.t("运行中的进程", "Running process")
        case .xdgUserData:    return L10n.t("XDG 用户数据", "XDG user data")
        case .libraryData:    return L10n.t("Library 用户数据", "Library user data")
        case .container:      return L10n.t("沙箱容器", "Sandbox container")
        case .groupContainer: return L10n.t("共享容器", "Group container")
        case .dotfile:        return L10n.t("Dotfile", "Dotfile")
        case .shellRc:        return L10n.t("Shell rc 污染", "Shell rc pollution")
        case .authToken:      return L10n.t("认证凭据", "Auth token")
        case .npmGlobal:      return L10n.t("npm 全局包", "npm global")
        case .pipxVenv:       return L10n.t("pipx 虚拟环境", "pipx venv")
        case .masApp:         return L10n.t("Mac App Store", "Mac App Store")
        case .toolCache:      return L10n.t("工具缓存", "Tool cache")
        case .pkgReceipt:     return L10n.t("pkg 安装收据", "Pkg receipt")
        }
    }

    var symbolName: String {
        switch self {
        case .appBundle:      return "app.bundle"
        case .cliBinary:      return "terminal"
        case .brewFormula:    return "shippingbox"
        case .brewCask:       return "shippingbox.fill"
        case .launchAgent:    return "play.circle"
        case .runningProcess: return "bolt.fill"
        case .xdgUserData:    return "folder"
        case .libraryData:    return "doc.on.doc"
        case .container:      return "shippingbox.circle"
        case .groupContainer: return "square.stack.3d.up"
        case .dotfile:        return "doc.text"
        case .shellRc:        return "text.append"
        case .authToken:      return "key"
        case .npmGlobal:      return "n.square"
        case .pipxVenv:       return "p.square"
        case .masApp:         return "storefront"
        case .toolCache:      return "internaldrive"
        case .pkgReceipt:     return "doc.badge.ellipsis"
        }
    }
}

enum Risk: String, Codable, Hashable {
    case safe      // 明确属于这个 app，可直接删
    case userData  // 可能含用户数据，默认不勾选
    case uncertain // 无法判断

    /// 稳定标识，写进 history.jsonl 和 CLI 输出，**不本地化**。
    var label: String {
        switch self {
        case .safe:      return "safe"
        case .userData:  return "user-data"
        case .uncertain: return "uncertain"
        }
    }

    /// 界面显示名（双语）。
    var displayName: String {
        switch self {
        case .safe:      return L10n.t("可安全删除", "Safe to remove")
        case .userData:  return L10n.t("含用户数据", "Contains user data")
        case .uncertain: return L10n.t("无法判断", "Uncertain")
        }
    }

    /// 一句话解释「为什么是这个等级」。一些工具把这个放进 UI 逐项可展开，
    /// 我们的保守取舍原先只写在 README 里，用户看不到。
    var explanation: String {
        switch self {
        case .safe:
            return L10n.t("路径能明确对应到这个 app，且内容可再生。",
                          "Path clearly belongs to this app and its contents are rebuildable.")
        case .userData:
            return L10n.t("可能含聊天记录、登录态等不可再生的数据，默认不勾选。",
                          "May hold unrecoverable data such as chat history or login state. Unchecked by default.")
        case .uncertain:
            return L10n.t("启发式判断，无法确认归属。请自行核对后再决定。",
                          "Heuristic match — ownership unconfirmed. Verify before removing.")
        }
    }
}

/// AI 对单个痕迹的复核结论。
/// - keep: AI 认为不应删除（应用页自动取消勾选 / 残留页保持不勾），附带理由。
/// - safe: AI 认为可以放心删除（主要给残留页用，自动勾选），附带理由。
enum AIVerdict: Hashable {
    case keep(reason: String)
    case safe(reason: String)
}

struct Artifact: Identifiable, Hashable {
    let id = UUID()
    let category: ArtifactCategory
    let path: String
    let size: Int64
    let risk: Risk
    /// 用于进程/launch agent 等不需要删路径而是需要 action 的项，填 nil
    let meta: String?
    var selected: Bool
    /// AI 复核结论。nil 表示尚未复核。
    var aiVerdict: AIVerdict?
    /// 行内辅助说明（仅 UI 展示，不参与删除 / 历史）。
    /// 目前用于 PWA：给「随应用一起卸载」的 Library 配置项标注一句跟随提示。
    var note: String?
    /// 若该项是某个 PWA 应用本体的跟随配置（如 Chrome PWA 的 Library plist），
    /// 这里记应用本体的 id。UI 据此禁用其勾选框（勾选跟随 app）；
    /// 删除逻辑据此把两者作为「卸载单元」一起处理。nil 表示独立项。
    var companionOf: UUID?

    init(category: ArtifactCategory, path: String, size: Int64, risk: Risk,
         meta: String? = nil, selected: Bool? = nil, aiVerdict: AIVerdict? = nil,
         note: String? = nil, companionOf: UUID? = nil) {
        self.category = category
        self.path = path
        self.size = size
        self.risk = risk
        self.meta = meta
        // 保留 risk-based 默认 primarily 给 CLI / SelfTest 兼容。
        // UI 层（应用页、残留页）会按页面策略显式覆盖 selected。
        self.selected = selected ?? (risk == .safe)
        self.aiVerdict = aiVerdict
        self.note = note
        self.companionOf = companionOf
    }
}
