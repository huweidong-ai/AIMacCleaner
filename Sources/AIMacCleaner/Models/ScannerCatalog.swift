import Foundation

/// 扫描器展示目录：给每个扫描器一个面向用户的中文名、简介和图标。
///
/// 注意：这里只维护「展示元数据」，不影响扫描逻辑；新增扫描器时
/// 只要往 `entries` 里加一条即可，不需要改 Scanner 协议。
struct ScannerCatalog {
    struct Entry {
        let name: String           // 与 Scanner.name 对应
        let displayName: String    // 用户可见名
        let description: String    // 一句话简介
        let icon: String           // SF Symbols
        let tint: ScannerTint      // 图标底色分组
    }

    enum ScannerTint: String, CaseIterable {
        case blue, green, orange, purple, teal, coral
    }

    /// 当前 `AppState.scanners` 中 14 个扫描器的展示信息。
    /// 顺序与 AppState.scanners 大致对应，方便用户理解扫描流程。
    static let entries: [Entry] = [
        Entry(name: "AppBundleScanner",
              displayName: L10n.t("应用包", "App bundle"),
              description: L10n.t("/Applications 与 ~/Applications 下的 .app 本体", "/Applications and ~/Applications .app bundles"),
              icon: "app.fill",
              tint: .blue),
        Entry(name: "BrewScanner",
              displayName: L10n.t("Homebrew", "Homebrew"),
              description: L10n.t("formula 与 cask 安装记录", "formula and cask installations"),
              icon: "mug.fill",
              tint: .orange),
        Entry(name: "RawBinaryScanner",
              displayName: L10n.t("二进制文件", "Binary files"),
              description: L10n.t("~/Downloads、~/.local/bin 等处的可执行文件", "Executables in Downloads and ~/.local/bin"),
              icon: "terminal.fill",
              tint: .purple),
        Entry(name: "XDGUserDataScanner",
              displayName: L10n.t("XDG 用户数据", "XDG user data"),
              description: L10n.t("~/.local/share、~/.config 等 Linux 风格目录", "~/.local/share, ~/.config and other XDG paths"),
              icon: "folder.fill",
              tint: .teal),
        Entry(name: "LaunchAgentScanner",
              displayName: L10n.t("启动项", "Launch agents"),
              description: L10n.t("~/Library/LaunchAgents 中的自动启动 plist", "Auto-start plists in LaunchAgents"),
              icon: "power",
              tint: .green),
        Entry(name: "ProcessScanner",
              displayName: L10n.t("运行进程", "Running processes"),
              description: L10n.t("目标进程及其 helper / GPU / Renderer 进程", "Target process and its helper processes"),
              icon: "cpu.fill",
              tint: .coral),
        Entry(name: "LibraryDataScanner",
              displayName: L10n.t("Library 数据", "Library data"),
              description: L10n.t("~/Library 下的用户数据、偏好设置、缓存与日志", "User data, prefs, caches and logs in ~/Library"),
              icon: "archivebox.fill",
              tint: .blue),
        Entry(name: "ContainerScanner",
              displayName: L10n.t("沙箱容器", "Sandbox containers"),
              description: L10n.t("~/Library/Containers 与 Group Containers", "Containers and Group Containers"),
              icon: "cube.fill",
              tint: .teal),
        Entry(name: "DotfileScanner",
              displayName: L10n.t("点文件", "Dotfiles"),
              description: L10n.t("用户目录下以 . 开头的配置文件/目录", "Dotfiles and dot-directories in home"),
              icon: "doc.text.fill",
              tint: .purple),
        Entry(name: "ShellConfigScanner",
              displayName: L10n.t("Shell 配置", "Shell config"),
              description: L10n.t(".zshrc / .bash_profile 中的 alias 与 PATH", "Aliases and PATH entries in shell configs"),
              icon: "command",
              tint: .green),
        Entry(name: "AuthTokenScanner",
              displayName: L10n.t("认证凭证", "Auth tokens"),
              description: L10n.t("已知目录中的 token、key、auth 文件", "Token, key and auth files in known dirs"),
              icon: "key.fill",
              tint: .orange),
        Entry(name: "NpmScanner",
              displayName: L10n.t("npm", "npm"),
              description: L10n.t("npm 全局包", "npm global packages"),
              icon: "number",
              tint: .coral),
        Entry(name: "PipxScanner",
              displayName: L10n.t("pipx", "pipx"),
              description: L10n.t("pipx 安装的 Python 工具", "pipx-installed Python tools"),
              icon: "chevron.left.forwardslash.chevron.right",
              tint: .blue),
        Entry(name: "MASScanner",
              displayName: L10n.t("Mac App Store", "Mac App Store"),
              description: L10n.t("通过 mas list 检测 MAS 安装记录", "MAS purchases via mas list"),
              icon: "bag.fill",
              tint: .purple)
    ]

    /// 按 Scanner.name 查找展示信息；未命中时返回一个中性兜底条目。
    static func entry(for scannerName: String) -> Entry {
        entries.first(where: { $0.name == scannerName })
            ?? Entry(name: scannerName,
                     displayName: scannerName,
                     description: "",
                     icon: "questionmark.circle.fill",
                     tint: .blue)
    }

    /// 把一条痕迹的「来源标识」翻成用户看得懂的名字 + 一句话说明。
    ///
    /// UI 里存的是代码里的稳定标识（`Artifact.source`），但直接显示
    /// `AppBundleScanner` 用户根本看不懂，所以展示一律走这里。
    /// 除内置扫描器外，还有两个非扫描器来源：AI 提议与同厂商残留探测。
    static func sourceLabel(for source: String) -> (name: String, detail: String) {
        switch source {
        case ArtifactSource.aiProposer:
            return (L10n.t("AI 补充发现", "AI extra findings"),
                    L10n.t("内置扫描器没找到、由模型补充提议的路径，已过本地校验",
                           "Paths the built-in scanners missed and the model suggested — locally validated"))
        case ArtifactSource.vendorRegistry:
            return (L10n.t("同厂商残留探测", "Same-vendor detection"),
                    L10n.t("卸载本 app 时额外探测到的同厂商其他入口",
                           "Other entries from the same vendor, probed when uninstalling this app"))
        default:
            let e = entry(for: source)
            return (e.displayName, e.description)
        }
    }
}
