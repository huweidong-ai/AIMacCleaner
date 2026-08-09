import Foundation
import AppKit
import Carbon

/// 全局快捷键：即使 app 在后台也能触发截图（选区）。
///
/// 用 Carbon 的 `RegisterEventHotKey` 而不是 `NSEvent` 监听，
/// 原因有二：
/// 1. 全局生效——app 不在前台时（截图最常见的场景：要截别的窗口）也能触发；
/// 2. 不需要「辅助功能」权限（区别于事件监听 / 事件分流那套要 TCC 授权的方案）。
///
/// 默认绑定 **⌘⇧6 → 选区截图**，与菜单栏「截图 ▸ 选区」一致。
final class ScreenshotHotkey {
    static let shared = ScreenshotHotkey()

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var action: (() -> Void)?
    private var registered = false

    /// 注册全局快捷键。重复调用安全（只注册一次）。
    /// - Parameter action: 快捷键触发时在主线程执行的回调（通常调截图）。
    func register(action: @escaping () -> Void) {
        self.action = action
        guard !registered else { return }
        registered = true

        // 签名 'AIMC'（0x41494D43），id 1 —— 仅用于回调里区分是哪个热键。
        var id = EventHotKeyID()
        id.signature = OSType(0x41494D43)
        id.id = 1

        // Cmd(0x0100) | Shift(0x0200) = 0x0300；键码 0x1F = '6'。
        let modifiers: UInt32 = 0x0100 | 0x0200
        let status = RegisterEventHotKey(0x1F, modifiers, id,
                                         GetApplicationEventTarget(), 0, &hotKeyRef)
        guard status == noErr, hotKeyRef != nil else {
            registered = false
            return
        }

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(),
                            { (_: EventHandlerCallRef?, _: EventRef?,
                               userData: UnsafeMutableRawPointer?) -> OSStatus in
                                guard let userData else { return noErr }
                                let me = Unmanaged<ScreenshotHotkey>.fromOpaque(userData)
                                    .takeUnretainedValue()
                                me.fire()
                                return noErr
                            }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
    }

    /// 热键回调：转到主线程，避免从 Carbon 事件处理里直接碰 SwiftUI 状态。
    private func fire() {
        DispatchQueue.main.async { [weak self] in self?.action?() }
    }

    func unregister() {
        if let ref = hotKeyRef { UnregisterEventHotKey(ref); hotKeyRef = nil }
        if let h = handlerRef { RemoveEventHandler(h); handlerRef = nil }
        action = nil
        registered = false
    }
}
