import Foundation

/// 扫描 XDG 规范下的用户数据目录。
/// 典型案例：mimo 留下 ~/.local/share/mimocode/、~/.cache/mimocode/、~/.config/mimocode/、~/.local/state/mimocode/。
struct XDGUserDataScanner: Scanner {
    let name = "XDGUserDataScanner"

    struct DirSpec {
        let path: String
        let risk: Risk
    }

    let baseDirs: [DirSpec] = [
        DirSpec(path: "\(NSHomeDirectory())/.local/share", risk: .userData),
        DirSpec(path: "\(NSHomeDirectory())/.cache",       risk: .safe),
        DirSpec(path: "\(NSHomeDirectory())/.config",      risk: .safe),
        DirSpec(path: "\(NSHomeDirectory())/.local/state", risk: .userData)
    ]

    func scan(query: ScanQuery) async -> [Artifact] {
        guard !query.isEmpty else { return [] }
        var results: [Artifact] = []

        for spec in baseDirs {
            let url = URL(fileURLWithPath: spec.path)
            guard let contents = try? FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for item in contents {
                let name = item.lastPathComponent
                // mimo 命中 mimocode、mimo-config 等
                if query.matches(name) {
                    let size = (try? item.directorySize()) ?? 0
                    results.append(Artifact(
                        category: .xdgUserData,
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
