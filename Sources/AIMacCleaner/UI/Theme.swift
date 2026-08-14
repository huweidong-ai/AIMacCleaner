import SwiftUI

/// AI Mac Cleaner 设计令牌（与 `docs/archive/design-prototype/design-tokens.md` 逐一对应）。
///
/// 配方：Linear(Light) 为骨 · Stripe 为魂 · Apple HIG 为地。
/// 配色源自原型：Petrol Blue 强调色 + 锁定的风险语义色 + 系统语义色。
/// 这些色值是视觉语言的一部分，**不要为「统一成系统色」去改**——
/// 风险映射的语义（用户数据=橙 / 不确定=黄 / 安全=灰）更是一条硬规则。
enum Theme {
    // MARK: - 品牌强调色 — Petrol Blue（沉静蓝，微偏青）

    /// 主强调。比系统蓝更深沉，去掉消费级气息，呼应「精密仪器」气质；
    /// 与暖端的风险色在色相上拉开最大距离，绝不串扰。
    static let accent       = Color(red: 0.0549, green: 0.4235, blue: 0.6196) // #0E6C9E
    static let accentHover  = Color(red: 0.0431, green: 0.3647, blue: 0.5333) // #0B5D88
    static let accentActive = Color(red: 0.0353, green: 0.3059, blue: 0.4510) // #094E73
    /// 选中态淡底（sidebar 选中、候选切换条当前项）。
    static let accentSubtle = Color(red: 0.9059, green: 0.9451, blue: 0.9686) // #E7F1F7
    static let accentBorder = Color(red: 0.7333, green: 0.8471, blue: 0.9098) // #BBD8E8

    // MARK: - 风险语义色（语义锁定，不可改映射）

    /// 可能含用户数据：聊天记录 / 账号 / 配置，删除后需重登或重配。
    static let riskUserData        = Color(red: 0.9098, green: 0.5137, blue: 0.2275) // #E8833A
    static let riskUserDataText    = Color(red: 0.6588, green: 0.3373, blue: 0.0588) // #A8560F
    static let riskUserDataBg       = Color(red: 0.9922, green: 0.9412, blue: 0.8941) // #FDF0E4
    static let riskUserDataBorder  = Color(red: 0.9529, green: 0.8275, blue: 0.6902) // #F3D3B0

    /// 启发式判断，无法确认归属。
    static let riskUncertain        = Color(red: 0.8784, green: 0.7098, blue: 0.2275) // #E0B53A
    static let riskUncertainText    = Color(red: 0.5412, green: 0.3961, blue: 0.0863) // #8A6516
    static let riskUncertainBg      = Color(red: 0.9843, green: 0.9529, blue: 0.8627) // #FBF3DC
    static let riskUncertainBorder = Color(red: 0.9294, green: 0.8627, blue: 0.6510) // #EDDCA6

    /// 明确属于这个 app，可直接删。
    static let riskSafe        = Color(red: 0.5412, green: 0.5412, blue: 0.5569) // #8A8A8E
    static let riskSafeText    = Color(red: 0.3608, green: 0.3608, blue: 0.3804) // #5C5C61
    static let riskSafeBg      = Color(red: 0.9451, green: 0.9451, blue: 0.9529) // #F1F1F3
    static let riskSafeBorder = Color(red: 0.8706, green: 0.8706, blue: 0.8863) // #DEDEE2

    // MARK: - AI 分析（紫）

    /// AI 是「第二意见」而不是风险等级，所以刻意跳出橙/黄/灰的风险色系，
    /// 单独占一个紫色调 —— 用户一眼能分清「这是 AI 说的」和「这是扫描器判的」。
    static let aiPrimary   = Color(red: 0.5451, green: 0.3608, blue: 0.7804) // #8B5CC7
    static let aiDeep      = Color(red: 0.3569, green: 0.2784, blue: 0.7216) // #5B47B8
    static let aiText      = Color(red: 0.4196, green: 0.2471, blue: 0.6275) // #6B3FA0
    static let aiBg        = Color(red: 0.9490, green: 0.9255, blue: 0.9804) // #F2ECFA
    static let aiBorder    = Color(red: 0.8510, green: 0.7804, blue: 0.9373) // #D9C7EF
    /// AI 分析条底色（近白的淡紫）。
    static let aiBarBg     = Color(red: 0.9843, green: 0.9725, blue: 1.0)    // #FBF8FF
    static let aiBarBorder = Color(red: 0.8863, green: 0.8392, blue: 0.9490) // #E2D6F2
    /// 被 AI 判为「不建议删除」的行底色。
    static let aiRowBg     = Color(red: 0.9882, green: 0.9804, blue: 1.0)    // #FCFAFF

    /// 分析完成后 AI 条转绿。
    static let aiDoneBorder = Color(red: 0.7961, green: 0.9059, blue: 0.8314) // #CBE7D4
    static let aiDoneBg     = Color(red: 0.9647, green: 0.9882, blue: 0.9725) // #F6FCF8

    // MARK: - 系统语义色

    /// 真正不可逆的操作才用（清空历史、删除选中记录）。其余「可恢复」动作一律用 accent。
    static let destructive = Color(red: 0.7843, green: 0.2157, blue: 0.1843) // #C8372F
    static let success     = Color(red: 0.1020, green: 0.4784, blue: 0.3294) // #1A7A54
    /// 警示（免责声明、确认弹窗标题）。与用户数据橙同源——同属「需要人类判断」。
    static let warning     = riskUserData // #E8833A

    // MARK: - 中性色（浅色 macOS）

    static let bgWindow  = Color.white
    static let bgSidebar = Color(red: 0.9569, green: 0.9569, blue: 0.9686) // #F4F4F7
    static let bgCanvas  = Color(red: 0.9686, green: 0.9686, blue: 0.9765) // #F7F7F9
    static let bgSurface = Color.white
    static let divider   = Color(red: 0.9137, green: 0.9137, blue: 0.9294) // #E9E9ED
    static let border    = Color(red: 0.8235, green: 0.8235, blue: 0.8431) // #D2D2D7

    // MARK: - 间距（8px 网格）

    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 20
        static let xxl: CGFloat = 24
    }
}

// MARK: - 风险 pill（色 + 图标 + 文字，三重编码）

/// 把「风险等级」做成可辨识的徽章：颜色、图标、文字三者同时编码，
/// 不靠纯色彩传达风险（色盲也可用图标/文字读出）。
struct RiskPill: View {
    let risk: Risk

    private struct Config {
        let icon: String
        let text: Color
        let bg: Color
        let border: Color
    }

    private var config: Config {
        switch risk {
        case .userData:
            return Config(icon: "person.crop.circle.badge.exclamationmark",
                          text: Theme.riskUserDataText,
                          bg: Theme.riskUserDataBg,
                          border: Theme.riskUserDataBorder)
        case .uncertain:
            return Config(icon: "questionmark.circle",
                          text: Theme.riskUncertainText,
                          bg: Theme.riskUncertainBg,
                          border: Theme.riskUncertainBorder)
        case .safe:
            return Config(icon: "checkmark.shield",
                          text: Theme.riskSafeText,
                          bg: Theme.riskSafeBg,
                          border: Theme.riskSafeBorder)
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: config.icon)
                .font(.system(size: 10, weight: .semibold))
            Text(risk.displayName)
                .font(.system(size: 10, weight: .semibold))
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .foregroundStyle(config.text)
        .background(config.bg, in: Capsule())
        .overlay(Capsule().stroke(config.border, lineWidth: 1))
    }
}

// MARK: - 通用小徽章

/// 和 `RiskPill` 同一套视觉规格的通用徽章，用于风险之外的标注
/// （残留来源、AI 建议保留、系统受保护进程…）。
///
/// 单独抽出来而不是往 `Risk` 里塞更多 case：这些标注和风险等级是
/// **正交**的两个维度，一行可以同时有「AI 工具」+「可能含用户数据」。
struct TagPill: View {
    let icon: String
    let text: String
    let fg: Color
    let bg: Color
    let border: Color

    /// 残留来源（无主 / AI 工具）。
    static func source(_ s: LeftoverSource) -> TagPill {
        switch s {
        case .aiTool:
            return TagPill(icon: "sparkles", text: s.displayName,
                           fg: Theme.aiText, bg: Theme.aiBg, border: Theme.aiBorder)
        case .orphan:
            return TagPill(icon: "questionmark.folder", text: s.displayName,
                           fg: Theme.accentActive, bg: Theme.accentSubtle, border: Theme.accentBorder)
        case .devCache:
            return TagPill(icon: "internaldrive", text: s.displayName,
                           fg: Theme.riskSafeText, bg: Theme.riskSafeBg, border: Theme.riskSafeBorder)
        }
    }

    /// AI 判定「不建议删除」。
    static var keep: TagPill {
        TagPill(icon: "hand.raised.fill", text: L10n.t("AI 建议保留", "AI says keep"),
                fg: Theme.aiText, bg: Theme.aiBg, border: Theme.aiBorder)
    }

    /// AI 判定「可以放心删」。
    static var aiSafe: TagPill {
        TagPill(icon: "checkmark.seal.fill", text: L10n.t("AI 判定可删", "AI says safe"),
                fg: Theme.success, bg: Theme.aiDoneBg, border: Theme.aiDoneBorder)
    }

    /// 系统进程等受保护、不可操作的项。
    static var locked: TagPill {
        TagPill(icon: "lock.fill", text: L10n.t("受保护", "Protected"),
                fg: Theme.riskSafeText, bg: Theme.riskSafeBg, border: Theme.riskSafeBorder)
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
            Text(text)
                .font(.system(size: 10, weight: .semibold))
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .foregroundStyle(fg)
        .background(bg, in: Capsule())
        .overlay(Capsule().stroke(border, lineWidth: 1))
    }
}
