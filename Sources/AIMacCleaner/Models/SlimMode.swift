import Foundation

/// 「应用瘦身 / 重置」的档位。
///
/// 与卸载的本质区别：**app 本体保留**，只清它留在用户目录里的数据与缓存。
/// 之所以拆成两档而不是一个开关，是因为两者的风险差了一个量级：
/// - `cacheOnly`：只清可再生缓存（省空间），不会掉登录，几乎无风险；
/// - `fullReset`：连同配置 / Cookie / 登录态 / 容器一起清，逼近「刚下载装好第一次打开」
///   的状态，会掉登录、未同步的本地数据会丢，因此默认不勾选且必须强确认。
enum SlimMode {
    case cacheOnly
    case fullReset

    var title: String {
        switch self {
        case .cacheOnly: return L10n.t("轻量瘦身（只清缓存）", "Light slim (caches only)")
        case .fullReset: return L10n.t("彻底重置（等同新装）", "Full reset (like a fresh install)")
        }
    }

    /// 确认弹窗 / 主按钮上的动作名。
    var actionTitle: String {
        switch self {
        case .cacheOnly: return L10n.t("瘦身", "Slim")
        case .fullReset: return L10n.t("重置并退出登录", "Reset and sign out")
        }
    }

    /// 这一档是否纳入「用户数据」类项（登录态 / 配置 / 本地数据库…）。
    var includesUserData: Bool {
        switch self {
        case .cacheOnly: return false
        case .fullReset: return true
        }
    }

    /// 瘦身只清「app 留在用户目录里的数据」，绝不碰安装物 / 自启动 / 别的产品。
    ///
    /// 排除项逐条理由：
    /// - `appBundle` / `masApp` / `cliBinary` / `brewFormula` / `brewCask` /
    ///   `npmGlobal` / `pipxVenv` / `pkgReceipt`：这些是**安装物**，瘦身不是卸载。
    /// - `launchAgent` / `runningProcess`：属于「自启动 / 进程」而非数据；在 app 还装着
    ///   的情况下删掉会改变它的开机行为，语义不对。
    /// - `vendorLeftover`：同厂商的**其它入口**（如 ChatGPT 之外的 Codex CLI），
    ///   那是卸载语义，瘦身不该替用户拆掉另一个产品。
    /// - `shellRc`：改的是 shell 配置文本，会影响终端环境，超出「重置这个 app」的范围。
    /// - `aiProposed`：模型对「卸载残留」的提议，与重置一个已装 app 无关，且归属不可靠。
    var eligibleCategories: Set<ArtifactCategory> {
        [.libraryData, .container, .groupContainer, .dotfile,
         .xdgUserData, .authToken, .toolCache]
    }

    /// 某项在这一档下是否默认勾选。
    ///
    /// **默认全勾**，与卸载页「默认全选」保持同一套约定：普通用户不具备判断
    /// 「这条 userData 到底该不该留」的知识，让他自己做默认决策只会导致
    /// 「重置了却什么都没清」的困惑。判断成本不放在勾选框上，而放在**取消勾选时**
    /// 的提示里（见结果页的「未勾选用户数据」横幅）——想保留的人只需取消，
    /// 且当场就能看到「保留下来意味着什么」。
    ///
    /// 安全性不靠这个默认值兜底，而靠两道网：① `userData` 删除走废纸篓
    /// （`ConfirmSheet` 的 `trashByDefault`），误勾也能拖回来；② 白名单 + 活 app
    /// 反查 + `/remember` 豁免仍在删除前逐条校验。
    func defaultSelected(risk: Risk) -> Bool { true }

    /// 结果页顶部的说明横幅：讲清这一档会动什么、不会动什么。
    func bannerText(appName: String) -> String {
        switch self {
        case .cacheOnly:
            return L10n.t(
                "只清可再生数据：缓存、日志、崩溃报告、WebKit 数据。\(appName) 不会被卸载，你也不会被退出登录。",
                "Only rebuildable data: caches, logs, crash reports, WebKit data. \(appName) stays installed and you stay signed in.")
        case .fullReset:
            return L10n.t(
                "会清掉 \(appName) 的配置、Cookie、登录态与容器数据 —— 效果接近「刚下载装好第一次打开」：需要重新登录、重新跑一遍引导流程。这些项默认已勾选，且删除时进废纸篓（清空废纸篓才不可恢复）；不想要某一项就取消勾选，下方会说明保留它的后果。未同步的本地数据（笔记草稿、离线内容、本地数据库）请先确认已同步。钥匙串不会被触碰。",
                "Clears \(appName)'s config, cookies, login state and container data — close to a fresh first launch: you'll be signed out and re-run onboarding. These items are checked by default and go to the Trash (recoverable until you empty it). Uncheck anything you want to keep and the note below explains what that means. Make sure unsynced local data (drafts, offline content, local databases) is synced first. The Keychain is never touched.")
        }
    }

    /// 确认弹窗里那句「不可逆」的强警告（仅 fullReset 需要）。
    func confirmWarning(appName: String) -> String? {
        switch self {
        case .cacheOnly:
            return nil
        case .fullReset:
            return L10n.t(
                "这会让 \(appName) 退出登录并回到首次启动状态。所有用户数据都会进废纸篓（清空废纸篓即不可恢复）。",
                "This signs \(appName) out and returns it to a first-launch state. All user data goes to the Trash — emptying the Trash makes it unrecoverable.")
        }
    }
}