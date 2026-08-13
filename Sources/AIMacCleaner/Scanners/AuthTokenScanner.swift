import Foundation

/// 在已知数据目录中搜索鉴权文件（token、key、auth、*-client 等命名）。
///
/// **这些文件是用户凭据 / 隐私令牌（如 Chromium 的 `Trust Tokens`、各类
/// `auth*.json` / `*-token`），删了要重新登录或影响站点隐私凭证，不可再生 ——
/// 一律标 `userData`、默认不勾选。** 之前的实现误标成 `safe`，导致
/// `Trust Tokens` 这类认证数据被当成「可安全删除」默认勾选，存在误删凭据风险。
struct AuthTokenScanner: Scanner {
    let name = "AuthTokenScanner"

    /// 搜索根目录（只扫这些地方，不全盘扫）
    let searchRoots: [String] = [
        "\(NSHomeDirectory())/.local/share",
        "\(NSHomeDirectory())/.local/state",
        "\(NSHomeDirectory())/.config",
        "\(NSHomeDirectory())/Library/Application Support"
    ]

    let patterns: [String] = [
        "token", "auth", "-client", "credential", "secret", "apikey", "api_key"
    ]

    func scan(query: ScanQuery) async -> [Artifact] {
        guard !query.isEmpty else { return [] }
        var results: [Artifact] = []
        let maxDepth = 3

        for root in searchRoots {
            let url = URL(fileURLWithPath: root)
            guard FileManager.default.fileExists(atPath: root) else { continue }
            walk(url: url, depth: 0, maxDepth: maxDepth, query: query, results: &results)
        }
        return results
    }

    private func walk(url: URL, depth: Int, maxDepth: Int, query: ScanQuery, results: inout [Artifact]) {
        guard depth <= maxDepth else { return }
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for item in contents {
            let name = item.lastPathComponent.lowercased()
            // 只在已识别为该 app 的目录树下找
            guard query.matches(name) || query.matches(item.deletingLastPathComponent().lastPathComponent) else { continue }

            let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir {
                walk(url: item, depth: depth + 1, maxDepth: maxDepth, query: query, results: &results)
            } else {
                for p in patterns where name.contains(p) {
                    let size = Int64((try? item.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                    results.append(Artifact(
                        category: .authToken,
                        path: item.path,
                        size: size,
                        risk: .userData,
                        meta: "matched: \(p)"
                    ))
                    break
                }
            }
        }
    }
}
