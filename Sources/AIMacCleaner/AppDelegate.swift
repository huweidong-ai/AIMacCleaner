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
    /// 持有主题监听的 observer，避免被释放。
    private var themeObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 监听 UserDefaults 主题键变化，切换时即时同步所有窗口 appearance。
        // apply() 不在这里调用：finishLaunching 时窗口尚未完成创建，
        // 提前设置 appearance 可能阻塞窗口出现；首屏同步放到 MainView.onAppear。
        themeObserver = ThemeManager.startObserving()
    }

    func applicationDidUpdate(_ notification: Notification) {
        for window in NSApp.windows where window.isVisible {
            if window.preventsApplicationTerminationWhenModal {
                window.preventsApplicationTerminationWhenModal = false
            }
        }
    }
}
