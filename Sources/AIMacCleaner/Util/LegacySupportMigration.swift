import Foundation

/// 一次性把旧版 `~/Library/Application Support/Expunge` 数据目录迁移到
/// `~/Library/Application Support/AIMacCleaner`，避免改名后老用户的
/// 对话历史 / 长期记忆 / 反馈 / 卸载历史读不到。
///
/// 设计要点（与 App 启动顺序解耦）：
/// - `done` 静态标志保证整进程只真正迁移一次。
/// - 若新目录已被某个 Store 的 `createDirectory` 提前建好（空目录），
///   走「复制旧文件进新目录」分支；否则走「整体 move」分支。
///   两种分支都幂等，因此无论本函数与各个 Store 的初始化谁先谁后都安全。
enum LegacySupportMigration {
    private static var done = false

    static func migrateIfNeeded() {
        guard !done else { return }
        done = true

        migrateApplicationSupport()
        migrateUserDefaults()
    }

    /// 把旧版 `~/Library/Application Support/Expunge` 数据目录迁移到
    /// `~/Library/Application Support/AIMacCleaner`，避免改名后老用户的
    /// 对话历史 / 长期记忆 / 反馈 / 卸载历史读不到。
    ///
    /// 设计要点（与 App 启动顺序解耦）：
    /// - 若新目录已被某个 Store 的 `createDirectory` 提前建好（空目录），
    ///   走「复制旧文件进新目录」分支；否则走「整体 move」分支。
    ///   两种分支都幂等，因此无论本函数与各个 Store 的初始化谁先谁后都安全。
    private static func migrateApplicationSupport() {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let old = base.appendingPathComponent("Expunge", isDirectory: true)
        let new = base.appendingPathComponent("AIMacCleaner", isDirectory: true)

        guard fm.fileExists(atPath: old.path) else { return }

        do {
            if fm.fileExists(atPath: new.path) {
                // 新目录已存在（被某个 Store 先建了空目录）：把旧文件复制进去，再删旧目录。
                let items = try fm.contentsOfDirectory(at: old, includingPropertiesForKeys: nil)
                for item in items {
                    let dest = new.appendingPathComponent(item.lastPathComponent)
                    try? fm.removeItem(at: dest)
                    try fm.copyItem(at: item, to: dest)
                }
                try fm.removeItem(at: old)
            } else {
                try fm.moveItem(at: old, to: new)
            }
        } catch {
            // 迁移失败不致命：旧数据留在原地，新 app 用新目录正常工作。
        }
    }

    /// 跨 bundle id 迁移 UserDefaults 偏好。
    ///
    /// 模型配置（key `expunge.aimodels` / 历史 `expunge.aimodel`）、语言
    /// （`expunge.language`）都写在 `UserDefaults.standard` 里，而 macOS 会按
    /// 当前 app 的 bundle id 把它落盘到 `~/Library/Preferences/<bundle-id>.plist`。
    /// 改名后 bundle id 从 `com.expunge.app` 变成 `com.aicleaner.app`，于是新 app
    /// 读自己的空 plist，旧配置被锁在 `com.expunge.app.plist` 里 —— 表现就是
    /// 「改名后配置不见了」。
    ///
    /// 这里在启动时把旧域里这几个 `expunge.` 前缀的键搬到当前域，再删除旧域，
    /// 让配置无缝回归，并顺手清掉旧 plist（卸载 .app 不会删 Preferences，会一直残留）。
    ///
    /// 注意：必须按 key 逐个用**类型安全**的 `set` 搬，不能直接把
    /// `dictionaryRepresentation()` 的 `Any` 值喂给 `set(_:forKey:)` ——
    /// 那样 `Data`（模型配置就是 `Data`）会被静默丢弃，只有 `String` 之类的
    /// 能成功写入，导致模型配置「搬了个寂寞」。
    private static func migrateUserDefaults() {
        guard let old = UserDefaults(suiteName: "com.expunge.app") else { return }
        let cur = UserDefaults.standard

        let keys = ["expunge.aimodels", "expunge.aimodel",
                    "expunge.language"]
        for key in keys {
            guard old.object(forKey: key) != nil else { continue }
            if let data = old.data(forKey: key) {
                cur.set(data, forKey: key)
            } else if let str = old.string(forKey: key) {
                cur.set(str, forKey: key)
            } else if let num = old.object(forKey: key) as? Bool {
                cur.set(num, forKey: key)
            } else if let obj = old.object(forKey: key) {
                cur.set(obj, forKey: key)
            }
        }
        cur.synchronize()

        // 整域删除：旧域里只剩这一个 app 的数据（含窗口 frame 等），新 app 用不上。
        old.removePersistentDomain(forName: "com.expunge.app")
        old.synchronize()
    }
}
