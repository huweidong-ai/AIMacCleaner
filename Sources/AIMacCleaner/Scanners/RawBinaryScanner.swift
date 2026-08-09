import Foundation

/// 扫描用户下载或自安装的命令行二进制（不在 /Applications，也不在 brew）。
/// 典型案例：~/.local/bin/mimo、~/Downloads/mimo。
struct RawBinaryScanner: Scanner {
    let name = "RawBinaryScanner"

    /// 要扫的目录。
    ///
    /// 手动下载的 CLI 二进制（如 `~/Downloads/mimo`）也可能需要被卸载，
    /// 因此 `~/Downloads` 现在默认加入扫描范围。它受 TCC 保护，首次扫描会
    /// 弹一次「想访问「下载」文件夹中的文件」授权框。
    /// `~/.local/bin` 不受 TCC 管，一直照扫。
    var searchPaths: [String] {
        ["\(NSHomeDirectory())/.local/bin",
         "\(NSHomeDirectory())/Downloads"]
    }

    func scan(query: ScanQuery) async -> [Artifact] {
        guard !query.isEmpty else { return [] }
        var results: [Artifact] = []

        for dir in searchPaths {
            let url = URL(fileURLWithPath: dir)
            guard let contents = try? FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
            ) else { continue }

            for item in contents {
                let name = item.lastPathComponent.lowercased()
                // 二进制保持严格匹配（精确/前缀），避免删错同名前缀的其他工具
                let hit = query.keywords.contains { kw in
                    name == kw || name.hasPrefix(kw + ".") || name == "\(kw).app"
                }
                if hit {
                    let size = Int64((try? item.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                    results.append(Artifact(
                        category: .cliBinary,
                        path: item.path,
                        size: size,
                        risk: .safe
                    ))
                }
            }
        }
        return results
    }
}
