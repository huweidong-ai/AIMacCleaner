import SwiftUI

/// 明暗双值动态色：同一枚令牌在浅色/深色外观下各有一套校准值，
/// 跟随系统外观自动切换（与 macOS 控件行为一致）。
private func dyn(_ light: (Double, Double, Double),
                 _ dark: (Double, Double, Double)) -> Color {
    Color(nsColor: NSColor(name: nil) { ap in
        let isDark = ap.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let (r, g, b) = isDark ? dark : light
        return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
    })
}

/// AI Mac Cleaner 设计令牌（与 `docs/archive/design-prototype/design-tokens.md` 逐一对应）。
///
/// 配方：Linear(Light) 为骨 · Stripe 为魂 · Apple HIG 为地。
/// 配色源自原型：Petrol Blue 强调色 + 锁定的风险语义色 + 系统语义色。
/// 这些色值是视觉语言的一部分，**不要为「统一成系统色」去改**——
/// 风险映射的语义（用户数据=橙 / 不确定=黄 / 安全=灰）更是一条硬规则。
/// 每个令牌均为明暗双值：浅色值沿用原设计，深色值按同一语义重新校准
/// （底色压暗、文字提亮，保证对比度与可读性）。
enum Theme {
    // MARK: - 品牌强调色 — Petrol Blue（沉静蓝，微偏青）

    /// 主强调。比系统蓝更深沉，去掉消费级气息，呼应「精密仪器」气质；
    /// 与暖端的风险色在色相上拉开最大距离，绝不串扰。
    /// 深色下提亮一档，避免在深底上发闷。
    static let accent       = dyn((0.0549, 0.4235, 0.6196), (0.3059, 0.6627, 0.8392)) // #0E6C9E / #4EA9D6
    static let accentHover  = dyn((0.0431, 0.3647, 0.5333), (0.2353, 0.5882, 0.7647)) // #0B5D88 / #3C96C3
    static let accentActive = dyn((0.0353, 0.3059, 0.4510), (0.1961, 0.5098, 0.6627)) // #094E73 / #3282A9
    /// 选中态淡底（sidebar 选中、候选切换条当前项）。
    static let accentSubtle = dyn((0.9059, 0.9451, 0.9686), (0.1216, 0.2353, 0.3255)) // #E7F1F7 / #1F3C53
    static let accentBorder = dyn((0.7333, 0.8471, 0.9098), (0.1725, 0.3255, 0.4314)) // #BBD8E8 / #2C536E

    // MARK: - 风险语义色（语义锁定，不可改映射）

    /// 可能含用户数据：聊天记录 / 账号 / 配置，删除后需重登或重配。
    static let riskUserData       = dyn((0.9098, 0.5137, 0.2275), (0.9412, 0.5765, 0.2941)) // #E8833A / #F0934B
    static let riskUserDataText   = dyn((0.6588, 0.3373, 0.0588), (0.9412, 0.6392, 0.3922)) // #A8560F / #F0A364
    static let riskUserDataBg     = dyn((0.9922, 0.9412, 0.8941), (0.2392, 0.1569, 0.0784)) // #FDF0E4 / #3D2814
    static let riskUserDataBorder = dyn((0.9529, 0.8275, 0.6902), (0.3569, 0.2392, 0.1216)) // #F3D3B0 / #5B3D1F

    /// 启发式判断，无法确认归属。
    static let riskUncertain       = dyn((0.8784, 0.7098, 0.2275), (0.8941, 0.7451, 0.3137)) // #E0B53A / #E3BF50
    static let riskUncertainText   = dyn((0.5412, 0.3961, 0.0863), (0.8980, 0.7608, 0.4078)) // #8A6516 / #E5C268
    static let riskUncertainBg     = dyn((0.9843, 0.9529, 0.8627), (0.1961, 0.1608, 0.0627)) // #FBF3DC / #32290F
    static let riskUncertainBorder = dyn((0.9294, 0.8627, 0.6510), (0.3294, 0.2824, 0.1216)) // #EDDCA6 / #54481F

    /// 明确属于这个 app，可直接删。
    static let riskSafe       = dyn((0.5412, 0.5412, 0.5569), (0.5882, 0.5882, 0.6118)) // #8A8A8E / #96969C
    static let riskSafeText   = dyn((0.3608, 0.3608, 0.3804), (0.7216, 0.7216, 0.7451)) // #5C5C61 / #B8B8BE
    static let riskSafeBg     = dyn((0.9451, 0.9451, 0.9529), (0.1647, 0.1647, 0.1765)) // #F1F1F3 / #2A2A2D
    static let riskSafeBorder = dyn((0.8706, 0.8706, 0.8863), (0.2706, 0.2706, 0.2902)) // #DEDEE2 / #45454A

    // MARK: - AI 分析（紫）

    /// AI 是「第二意见」而不是风险等级，所以刻意跳出橙/黄/灰的风险色系，
    /// 单独占一个紫色调 —— 用户一眼能分清「这是 AI 说的」和「这是扫描器判的」。
    static let aiPrimary   = dyn((0.5451, 0.3608, 0.7804), (0.6392, 0.4706, 0.8588)) // #8B5CC7 / #A377DB
    static let aiDeep      = dyn((0.3569, 0.2784, 0.7216), (0.5020, 0.4157, 0.8392)) // #5B47B8 / #8069D6
    static let aiText      = dyn((0.4196, 0.2471, 0.6275), (0.7882, 0.6588, 0.9373)) // #6B3FA0 / #C9A8F0
    static let aiBg        = dyn((0.9490, 0.9255, 0.9804), (0.1647, 0.1294, 0.2510)) // #F2ECFA / #2A2140
    static let aiBorder    = dyn((0.8510, 0.7804, 0.9373), (0.2902, 0.2275, 0.4196)) // #D9C7EF / #4A3A6B
    /// AI 分析条底色（近白的淡紫）。
    static let aiBarBg     = dyn((0.9843, 0.9725, 1.0), (0.1333, 0.1098, 0.1961)) // #FBF8FF / #221C32
    static let aiBarBorder = dyn((0.8863, 0.8392, 0.9490), (0.2392, 0.1961, 0.3294)) // #E2D6F2 / #3D3254
    /// 被 AI 判为「不建议删除」的行底色。
    static let aiRowBg     = dyn((0.9882, 0.9804, 1.0), (0.1412, 0.1176, 0.2118)) // #FCFAFF / #241E36

    /// 分析完成后 AI 条转绿。
    static let aiDoneBorder = dyn((0.7961, 0.9059, 0.8314), (0.2078, 0.4353, 0.2980)) // #CBE7D4 / #356F4C
    static let aiDoneBg     = dyn((0.9647, 0.9882, 0.9725), (0.0824, 0.1608, 0.1176)) // #F6FCF8 / #15291E

    // MARK: - 系统语义色

    /// 真正不可逆的操作才用（清空历史、删除选中记录）。其余「可恢复」动作一律用 accent。
    static let destructive = dyn((0.7843, 0.2157, 0.1843), (0.8784, 0.3137, 0.2706)) // #C8372F / #E05045
    static let success     = dyn((0.1020, 0.4784, 0.3294), (0.2353, 0.6275, 0.4392)) // #1A7A54 / #3CA070
    /// 警示（免责声明、确认弹窗标题）。与用户数据橙同源——同属「需要人类判断」。
    static let warning       = riskUserData
    /// 警示浅底（同厂商残留提示卡等）。
    static let warningSubtle = riskUserDataBg

    // MARK: - 中性色（明暗双值）

    static let bgWindow  = dyn((1.0, 1.0, 1.0),                (0.1176, 0.1176, 0.1333)) // #FFFFFF / #1E1E22
    static let bgSidebar = dyn((0.9569, 0.9569, 0.9686),       (0.1333, 0.1333, 0.1490)) // #F4F4F7 / #222226
    static let bgCanvas  = dyn((0.9686, 0.9686, 0.9765),       (0.0902, 0.0902, 0.1020)) // #F7F7F9 / #17171A
    static let bgSurface = dyn((1.0, 1.0, 1.0),                (0.1451, 0.1451, 0.1608)) // #FFFFFF / #252529
    static let divider   = dyn((0.9137, 0.9137, 0.9294),       (0.2196, 0.2196, 0.2392)) // #E9E9ED / #38383D
    static let border    = dyn((0.8235, 0.8235, 0.8431),       (0.2863, 0.2863, 0.3098)) // #D2D2D7 / #49494F

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

/// 和「RiskPill」同一套视觉规格的通用徽章，用于风险之外的标注
/// （残留来源、AI 建议保留、系统受保护进程…）。
///
/// 单独抽出来而不是往「Risk」里塞更多 case：这些标注和风险等级是
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
