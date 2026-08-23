import AppKit

/// 全局纠正一个 SwiftUI 的「坑」：
///
/// SwiftUI 的 `.sheet` 底层会用 AppKit 的 modal session 来呈现，而
/// `NSWindow.preventsApplicationTerminationWhenModal` 默认是 `true` ——
/// 只要弹窗（小弹窗/面板/确认框）还开着，系统就不允许通过菜单栏「退出」、
/// Dock 右键「退出」、或 Cmd+Q 来关闭 app，必须先把弹窗关掉才行。
///
/// 对清理工具这类「弹窗随时可能开着、用户想直接关 app」的场景很反直觉，
/// 用户会以为 app 卡死。这里在 AppDelegate 里把所有可见窗口的该标记置为
/// `false`，让终止（退出）在弹窗开着时也能正常进行；至于「未保存内容要不要拦」
/// 由各自的 sheet 自己决定（本 app 的弹窗都是只读或带确认按钮，无需拦退出）。
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidUpdate(_ notification: Notification) {
        for window in NSApp.windows where window.isVisible {
            if window.preventsApplicationTerminationWhenModal {
                window.preventsApplicationTerminationWhenModal = false
            }
        }
    }
}
