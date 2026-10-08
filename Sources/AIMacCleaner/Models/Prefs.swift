import Foundation

/// 用户可调的偏好项。
enum Prefs {

    // MARK: - AI 补充发现

    /// 扫描时是否让模型**补充提议**内置扫描器可能漏掉的残留路径
    /// （见 `AIScanProposer`）。
    ///
    /// 默认开启。关掉后扫描行为与未接 AI 时完全一致 —— 纯内置扫描器结果。
    /// 未配置模型时这个开关不起作用（`AIScanProposer` 会整步跳过）。
    ///
    /// 注意：提议项一律默认不勾选，且删除时仍走 `FileDeleter` 的白名单 +
    /// 废纸篓；这个开关只决定「要不要多问模型一句」，不决定删除权限。
    static var aiProposeEnabled: Bool {
        get {
            UserDefaults.standard.object(forKey: Keys.aiPropose) as? Bool ?? true
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Keys.aiPropose)
        }
    }

    private enum Keys {
        static let aiPropose = "expunge.aiPropose"
    }
}
