import Foundation

/// 扫描 ~/Library 下的用户数据子目录。
struct LibraryDataScanner: Scanner {
    let name = "LibraryDataScanner"

    struct DirSpec {
        let path: String
        let risk: Risk
    }

    /// 要扫的 ~/Library 子目录。
    ///
    /// v1.3 从 5 个扩到 12 个。补齐的实证：`~/Library/HTTPStorages` 下发现一个
    /// **早已卸载的 CLI 工具**留下的目录 —— `--orphans` 也报告清理完了，痕迹却一直留着，
    /// 因为这个目录没在扫描范围里。一台日常使用的机器上实测的量级：
    /// HTTPStorages ~90 项 / 数十 MB、WebKit ~15 项 / 20+ MB、Application Scripts ~千项。
    ///
    /// **risk 的判断依据是「删掉会不会丢用户不可再生的东西」，不是目录大小：**
    /// - `Application Support` / `HTTPStorages` / `Cookies` / `Services` 存的是
    ///   配置、登录态、Cookie、用户自己写的 workflow —— 删了要重新登录或重配，
    ///   算 userData（默认不勾选）。
    /// - `Preferences`（*.plist）通常含登录态与配置，同样算 userData。
    /// - `Caches` / `WebKit` / `Application Scripts` / `Internet Plug-Ins` / `PreferencePanes`
    ///   是可再生的缓存和 app 自带资源，删了最多重新生成，算 safe（默认勾选）。
    let baseDirs: [DirSpec] = [
        DirSpec(path: "\(NSHomeDirectory())/Library/Application Support", risk: .userData),
        DirSpec(path: "\(NSHomeDirectory())/Library/Preferences",        risk: .userData),
        DirSpec(path: "\(NSHomeDirectory())/Library/Caches",              risk: .safe),
        DirSpec(path: "\(NSHomeDirectory())/Library/Logs",                risk: .safe),
        DirSpec(path: "\(NSHomeDirectory())/Library/Saved Application State", risk: .userData),
        // ── v1.3 新增 ──
        DirSpec(path: "\(NSHomeDirectory())/Library/HTTPStorages",        risk: .userData),
        DirSpec(path: "\(NSHomeDirectory())/Library/Cookies",             risk: .userData),
        DirSpec(path: "\(NSHomeDirectory())/Library/Services",            risk: .userData),
        DirSpec(path: "\(NSHomeDirectory())/Library/WebKit",              risk: .safe),
        DirSpec(path: "\(NSHomeDirectory())/Library/Application Scripts", risk: .safe),
        DirSpec(path: "\(NSHomeDirectory())/Library/Internet Plug-Ins",   risk: .safe),
        DirSpec(path: "\(NSHomeDirectory())/Library/PreferencePanes",     risk: .safe)
    ]

    func scan(query: ScanQuery) async -> [Artifact] {
        guard !query.isEmpty else { return [] }
        var results: [Artifact] = []

        for spec in baseDirs {
            let url = URL(fileURLWithPath: spec.path)
            guard let contents = try? FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for item in contents {
                let name = item.lastPathComponent
                // 用 app 的全部别名匹配：WeChat 的残留可能叫 WeChat、com.tencent.xinWeChat 或「微信」
                if query.matches(name) {
                    let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                    let size: Int64
                    if isDir {
                        size = (try? item.directorySize()) ?? 0
                    } else {
                        size = Int64((try? item.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                    }
                    results.append(Artifact(
                        category: .libraryData,
                        path: item.path,
                        size: size,
                        risk: spec.risk
                    ))
                }
            }
        }
        return results
    }
}
