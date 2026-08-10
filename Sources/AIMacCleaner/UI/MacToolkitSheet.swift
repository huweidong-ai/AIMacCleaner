import SwiftUI
import AppKit

/// 「macOS 自带能力」参考面板。
///
/// 存在的目的：很多用户不知道系统已经自带截图、录屏、窗口管理、隐私授权等能力，
/// 于是去装一堆第三方小工具。这个面板把常用的系统快捷键与入口摊开，
/// 顺带说明 AI Mac Cleaner 自身尽量不重复造轮子、复用系统能力。
///
/// 纯静态内容：不调任何系统能力（动作按钮除外，那是用户主动点「打开」）。
struct MacToolkitSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var query: String = ""

    /// 系统能力分类的展示顺序。
    private let categoryOrder: [(key: String, title: String)] = [
        ("screenshot", L10n.t("截图与录屏", "Screenshot & Screen Recording")),
        ("window",     L10n.t("窗口与桌面", "Window & Desktop")),
        ("clipboard",  L10n.t("文本与剪贴板", "Text & Clipboard")),
        ("files",      L10n.t("文件与查找", "Files & Search")),
        ("privacy",    L10n.t("隐私与权限", "Privacy & Permissions")),
        ("tools",      L10n.t("系统工具", "System Utilities")),
    ]

    /// 数据来自非隔离的 `MacToolCatalog`，避免 self-test 触碰 @MainActor 的 View。
    private var systemTools: [MacTool] { MacToolCatalog.systemTools }

    // MARK: - 视图

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            searchBar
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(categoryOrder, id: \.key) { cat in
                        let items = applyQuery(systemTools.filter { $0.category == cat.key })
                        if !items.isEmpty {
                            sectionTitle(cat.title)
                            ForEach(items) { toolRow($0) }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
            Divider()
            footer
        }
        .frame(width: 560, height: 600)
        .background(Theme.bgCanvas, in: RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.12), radius: 16, y: 5)
        .blanketDismiss { dismiss() }
        .frame(width: 640, height: 680)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 8)
                .fill(Theme.accentSubtle)
                .frame(width: 30, height: 30)
                .overlay(Image(systemName: "keyboard")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.accent))
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.t("macOS 自带能力", "Built-in macOS capabilities"))
                    .font(.system(size: 14, weight: .semibold))
                Text(L10n.t("系统已经自带这些能力，多数无需安装第三方小工具；本应用也尽量复用它们。",
                            "macOS already ships these. Most need no third-party utility — and this app reuses them too."))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
    }

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
            TextField(L10n.t("搜索快捷键或功能", "Search shortcuts or features"), text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(8)
        .padding(.horizontal, 8)
    }

    private var footer: some View {
        SheetActionBar {
            EmptyView()
        } trailing: {
            SheetCloseButton(title: L10n.t("关闭", "Close")) { dismiss() }
        }
    }

    // MARK: - 行 / 分区

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(Theme.accent)
            .padding(.top, 12)
            .padding(.bottom, 4)
    }

    private func toolRow(_ tool: MacTool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(tool.name)
                        .font(.system(size: 12.5, weight: .medium))
                    ForEach(tool.shortcuts, id: \.self) { sc in
                        Text(sc)
                            .font(.system(size: 11, design: .monospaced))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Theme.bgCanvas, in: RoundedRectangle(cornerRadius: 5))
                            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.divider, lineWidth: 1))
                    }
                }
                Text(tool.description)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let note = tool.note {
                    Text(note)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            if let action = tool.action {
                Button(action.label) { action.run() }
                    .controlSize(.small)
                    .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
    }

    // MARK: - 过滤

    private func applyQuery(_ tools: [MacTool]) -> [MacTool] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return tools }
        return tools.filter {
            $0.name.localizedCaseInsensitiveContains(q)
            || $0.description.localizedCaseInsensitiveContains(q)
            || $0.shortcuts.contains { $0.localizedCaseInsensitiveContains(q) }
        }
    }
}

/// 系统自带能力 + AI Mac Cleaner 自身快捷键的静态数据。
///
/// 独立成非 `View` 类型，避免 self-test 触碰 `@MainActor` 的 `MacToolkitSheet`。
enum MacToolCatalog {
    static var systemTools: [MacTool] {
        [
            // 截图与录屏
            MacTool(category: "screenshot",
                    name: L10n.t("全屏截图", "Capture entire screen"),
                    shortcuts: ["⌘⇧3"],
                    description: L10n.t("捕获整个屏幕并存为文件",
                                        "Capture the whole screen to a file")),
            MacTool(category: "screenshot",
                    name: L10n.t("选区截图", "Capture a selected area"),
                    shortcuts: ["⌘⇧4"],
                    description: L10n.t("拖拽选择区域截图",
                                        "Drag to select an area to capture")),
            MacTool(category: "screenshot",
                    name: L10n.t("窗口截图", "Capture a window"),
                    shortcuts: ["⌘⇧4", L10n.t("空格", "Space")],
                    description: L10n.t("先按 ⌘⇧4，再按空格点选窗口",
                                        "Press ⌘⇧4, then Space to pick a window")),
            MacTool(category: "screenshot",
                    name: L10n.t("截图 / 录屏工具条", "Screenshot & recording toolbar"),
                    shortcuts: ["⌘⇧5"],
                    description: L10n.t("打开系统截图与录屏工具条，可定时、可录屏",
                                        "Open the system toolbar: timed capture and screen recording")),
            MacTool(category: "screenshot",
                    name: L10n.t("截图存到剪贴板", "Capture to clipboard"),
                    shortcuts: ["⌘⇧⌃4", "⌘⇧⌃3"],
                    description: L10n.t("在截图快捷键上多按 Control：⌘⇧⌃4 选区、⌘⇧⌃3 全屏，图片进剪贴板而非存成文件",
                                        "Add Control to the capture shortcut: ⌘⇧⌃4 selects an area, ⌘⇧⌃3 captures the screen — the image goes to the clipboard instead of a file")),

            // 窗口与桌面
            MacTool(category: "window",
                    name: L10n.t("最小化窗口", "Minimize window"),
                    shortcuts: ["⌘M"],
                    description: L10n.t("收起当前窗口到 Dock",
                                        "Minimize the current window to the Dock")),
            MacTool(category: "window",
                    name: L10n.t("隐藏应用", "Hide application"),
                    shortcuts: ["⌘H"],
                    description: L10n.t("隐藏当前应用的所有窗口（⌥⌘H 隐藏其他应用）",
                                        "Hide all windows of the current app (⌥⌘H hides others)")),
            MacTool(category: "window",
                    name: L10n.t("切换应用", "Switch applications"),
                    shortcuts: ["⌘⇥"],
                    description: L10n.t("在最近使用的应用间切换（⌘⇧⇥ 反向）",
                                        "Cycle recent apps (⌘⇧⇥ reverses)")),
            MacTool(category: "window",
                    name: L10n.t("切换窗口", "Switch windows"),
                    shortcuts: ["⌘`"],
                    description: L10n.t("同一应用内多个窗口间切换",
                                        "Cycle windows within the same app")),
            MacTool(category: "window",
                    name: L10n.t("切换桌面空间", "Switch desktops"),
                    shortcuts: ["⌃←", "⌃→"],
                    description: L10n.t("左右切换全屏 / 桌面空间",
                                        "Move between full-screen spaces / desktops")),
            MacTool(category: "window",
                    name: L10n.t("调度中心", "Mission Control"),
                    shortcuts: ["⌃↑"],
                    description: L10n.t("查看所有窗口与空间（部分键盘为 F3）",
                                        "View all windows and spaces (F3 on some keyboards)")),
            MacTool(category: "window",
                    name: L10n.t("强制退出", "Force Quit"),
                    shortcuts: ["⌥⌘⎋"],
                    description: L10n.t("弹出不响应 app 的列表（⎋ = Esc）",
                                        "Open the unresponsive-app list (⎋ = Esc)")),
            MacTool(category: "window",
                    name: L10n.t("退出应用", "Quit application"),
                    shortcuts: ["⌘Q"],
                    description: L10n.t("完全退出当前应用", "Fully quit the current app")),

            // 文本与剪贴板
            MacTool(category: "clipboard",
                    name: L10n.t("复制 / 粘贴 / 剪切", "Copy / Paste / Cut"),
                    shortcuts: ["⌘C", "⌘V", "⌘X"],
                    description: L10n.t("基础编辑三连", "The basic editing trio")),
            MacTool(category: "clipboard",
                    name: L10n.t("撤销 / 重做", "Undo / Redo"),
                    shortcuts: ["⌘Z", "⌘⇧Z"],
                    description: L10n.t("撤销与上一步", "Undo and redo")),
            MacTool(category: "clipboard",
                    name: L10n.t("全选", "Select all"),
                    shortcuts: ["⌘A"],
                    description: L10n.t("选中全部内容", "Select everything")),
            MacTool(category: "clipboard",
                    name: L10n.t("匹配样式粘贴", "Paste matching style"),
                    shortcuts: ["⌥⇧⌘V"],
                    description: L10n.t("多数 app 中粘贴为纯文本、去掉原格式",
                                        "Paste as plain text in most apps, dropping original styling")),
            MacTool(category: "clipboard",
                    name: L10n.t("聚焦搜索", "Spotlight"),
                    shortcuts: ["⌘空格"],
                    description: L10n.t("全局搜索 app / 文件 / 网页",
                                        "Global search for apps, files and the web")),
            MacTool(category: "clipboard",
                    name: L10n.t("表情符号面板", "Emoji picker"),
                    shortcuts: ["⌃⌘空格"],
                    description: L10n.t("插入 emoji 与特殊符号",
                                        "Insert emoji and special characters")),

            // 文件与查找
            MacTool(category: "files",
                    name: L10n.t("前往文件夹", "Go to folder"),
                    shortcuts: ["⌘⇧G"],
                    description: L10n.t("在访达 / 打开对话框里直接输入路径跳转",
                                        "Type a path to jump to it in Finder / open dialogs")),
            MacTool(category: "files",
                    name: L10n.t("快速查看", "Quick Look"),
                    shortcuts: ["空格"],
                    description: L10n.t("选中文件后按空格预览，无需打开",
                                        "Preview a selected file without opening it")),
            MacTool(category: "files",
                    name: L10n.t("显示简介", "Get info"),
                    shortcuts: ["⌘I"],
                    description: L10n.t("查看文件信息、修改权限",
                                        "Show file info and edit permissions")),
            MacTool(category: "files",
                    name: L10n.t("移到废纸篓", "Move to Trash"),
                    shortcuts: ["⌘⌫"],
                    description: L10n.t("删除选中文件（⌥⌘⌫ 立即清空废纸篓）",
                                        "Delete selected files (⌥⌘⌫ empties Trash immediately)")),
            MacTool(category: "files",
                    name: L10n.t("重命名", "Rename"),
                    shortcuts: ["↵"],
                    description: L10n.t("选中文件按回车进入重命名",
                                        "Press Return on a selected file to rename it")),

            // 隐私与权限（带「打开系统设置」按钮）
            MacTool(category: "privacy",
                    name: L10n.t("屏幕录制授权", "Screen Recording"),
                    shortcuts: ["—"],
                    description: L10n.t("第三方 app 调用截图 / 录屏时需要",
                                        "Required when third-party apps capture screen"),
                    note: L10n.t("系统设置 → 隐私与安全性 → 屏幕录制",
                                "System Settings → Privacy & Security → Screen Recording"),
                    action: .openSettings(anchor: "com.apple.preference.security?Privacy_ScreenCapture",
                                          label: L10n.t("打开系统设置", "Open System Settings"))),
            MacTool(category: "privacy",
                    name: L10n.t("完全磁盘访问权限", "Full Disk Access"),
                    shortcuts: ["—"],
                    description: L10n.t("访问其他 app 的 ~/Library 数据所需的授权（本应用扫描依赖它）",
                                        "Required to read other apps' ~/Library data — this app's scan depends on it"),
                    note: L10n.t("系统设置 → 隐私与安全性 → 完全磁盘访问权限",
                                "System Settings → Privacy & Security → Full Disk Access"),
                    action: .openSettings(anchor: "com.apple.preference.security?Privacy_AllFiles",
                                          label: L10n.t("打开系统设置", "Open System Settings"))),
            MacTool(category: "privacy",
                    name: L10n.t("辅助功能授权", "Accessibility"),
                    shortcuts: ["—"],
                    description: L10n.t("部分自动化 / 控制类工具需要",
                                        "Needed by some automation / control utilities"),
                    note: L10n.t("系统设置 → 隐私与安全性 → 辅助功能",
                                "System Settings → Privacy & Security → Accessibility"),
                    action: .openSettings(anchor: "com.apple.preference.security?Privacy_Accessibility",
                                          label: L10n.t("打开系统设置", "Open System Settings"))),
            MacTool(category: "privacy",
                    name: L10n.t("隐私与安全性（总入口）", "Privacy & Security"),
                    shortcuts: ["—"],
                    description: L10n.t("所有隐私类授权都在这一个面板里",
                                        "All privacy grants live in this one pane"),
                    action: .openSettings(anchor: "com.apple.preference.security",
                                          label: L10n.t("打开系统设置", "Open System Settings"))),

            // 系统工具（带「打开 app」按钮）
            MacTool(category: "tools",
                    name: L10n.t("活动监视器", "Activity Monitor"),
                    shortcuts: ["—"],
                    description: L10n.t("查看 CPU / 内存 / 进程，结束卡死进程",
                                        "View CPU, memory and processes; quit hung apps"),
                    action: .openApp(path: "/System/Applications/Utilities/Activity Monitor.app",
                                     label: L10n.t("打开活动监视器", "Open Activity Monitor"))),
            MacTool(category: "tools",
                    name: L10n.t("磁盘工具", "Disk Utility"),
                    shortcuts: ["—"],
                    description: L10n.t("磁盘急救、分区、制作映像",
                                        "First Aid, partition, create disk images"),
                    action: .openApp(path: "/System/Applications/Utilities/Disk Utility.app",
                                     label: L10n.t("打开磁盘工具", "Open Disk Utility"))),
            MacTool(category: "tools",
                    name: L10n.t("终端", "Terminal"),
                    shortcuts: ["—"],
                    description: L10n.t("命令行；本应用的 CLI 也在这里运行",
                                        "Command line; this app's CLI runs here too"),
                    action: .openApp(path: "/System/Applications/Utilities/Terminal.app",
                                     label: L10n.t("打开终端", "Open Terminal"))),
            MacTool(category: "tools",
                    name: L10n.t("控制台", "Console"),
                    shortcuts: ["—"],
                    description: L10n.t("查看系统日志，排查崩溃",
                                        "Read system logs and debug crashes"),
                    action: .openApp(path: "/System/Applications/Utilities/Console.app",
                                     label: L10n.t("打开控制台", "Open Console"))),
            MacTool(category: "tools",
                    name: L10n.t("系统信息", "System Information"),
                    shortcuts: ["—"],
                    description: L10n.t("查看硬件 / 软件 / 存储详情",
                                        "Inspect hardware, software and storage"),
                    action: .openApp(path: "/System/Applications/Utilities/System Information.app",
                                     label: L10n.t("打开系统信息", "Open System Information"))),
        ]
    }

}

/// 单条能力。
struct MacTool: Identifiable {
    let id = UUID()
    let category: String
    let name: String
    let shortcuts: [String]
    let description: String
    var note: String?
    var action: MacToolAction?
}

/// 行尾的「打开」动作：跳系统设置对应隐私面板，或打开某个系统实用工具。
enum MacToolAction: Identifiable {
    case openSettings(anchor: String, label: String)
    case openApp(path: String, label: String)

    var id: String {
        switch self {
        case .openSettings(let a, _): return "settings:\(a)"
        case .openApp(let p, _):      return "app:\(p)"
        }
    }

    var label: String {
        switch self {
        case .openSettings(_, let l): return l
        case .openApp(_, let l):      return l
        }
    }

    /// 用户主动点击时执行。失败静默（系统设置 URL 偶尔不识别锚点时退回常规面板）。
    func run() {
        switch self {
        case .openSettings(let anchor, _):
            if let url = URL(string: "x-apple.systempreferences:\(anchor)") {
                NSWorkspace.shared.open(url)
            }
        case .openApp(let path, _):
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        }
    }
}
