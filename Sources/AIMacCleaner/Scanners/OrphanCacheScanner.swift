import Foundation

// ───────────────────────────────────────────────────────────────────────────
// 动态「孤儿依赖 / 构建缓存」扫描器
//
// 与 `AIToolLeftovers` 的本质区别：那张表是**写死的静态路径清单**；
// 本扫描器**动态遍历** scratch 根目录（默认 `~/Downloads`、`~/Desktop`，
// 都在 `FileDeleter` 白名单内），找出「已经没有源清单」的依赖 / 构建缓存目录。
//
// 目标类型（目录名 → 判定「活项目」所需的源清单）：
//   • node_modules  → package.json / 各类 lock 文件
//   • .build        → Package.swift（SwiftPM）
//   • Pods          → Podfile（CocoaPods）
//   • target        → Cargo.toml（Rust/Cargo）
//   • .venv / .tox  → pyproject.toml / setup.py / requirements / Pipfile …
//   • .next / .nuxt / .svelte-kit → package.json（JS 框架构建产物）
//   • .dart_tool    → pubspec.yaml（Dart/Flutter）
//   • .gradle       → build.gradle（本地 Gradle）
//
// 「孤儿」判定：目标目录所在的**父目录**里没有对应的源清单文件，
// 即视为可清理。活项目（有清单）自动跳过，避免误删在用的依赖。
//
// 安全网：
//   • 只报、不删；删除走统一 `FileDeleter`（默认废纸篓，可恢复）。
//   • 体积低于阈值（默认 5 MB）的目录不列出，避免噪声。
//   • 命中项风险映射为 `.uncertain`（默认不勾选），由用户确认。
//   • 扫描根可配置，默认仅限两个 scratch 目录，不碰 `~/Documents` 等项目区。
// ───────────────────────────────────────────────────────────────────────────

enum OrphanCacheScanner {

    /// 可配置扫描根（默认两个 scratch 目录，均在 FileDeleter 白名单内）。
    static var scanRoots: [String] = [
        "~/Downloads",
        "~/Desktop",
    ]

    /// 目标目录名 → 判定「活项目」所需的源清单文件名。
    static let manifestByTarget: [String: [String]] = [
        "node_modules": ["package.json", "package-lock.json", "yarn.lock",
                         "pnpm-lock.yaml", "bun.lockb", "bun.lock"],
        ".build":       ["Package.swift", "Package.resolved"],
        "Pods":         ["Podfile", "Podfile.lock"],
        "target":       ["Cargo.toml", "Cargo.lock"],
        ".venv":        ["pyproject.toml", "setup.py", "requirements.txt",
                         "Pipfile", "environment.yml"],
        ".tox":         ["pyproject.toml", "setup.py", "tox.ini"],
        ".next":        ["package.json"],
        ".nuxt":        ["package.json"],
        ".svelte-kit":  ["package.json"],
        ".dart_tool":   ["pubspec.yaml"],
        ".gradle":      ["build.gradle", "build.gradle.kts",
                         "settings.gradle", "settings.gradle.kts"],
    ]

    /// 命中结构（一个孤儿目录）。
    struct Hit: Identifiable {
        let id = UUID()
        let path: String
        let kind: String      // 友好名：Node Modules / SwiftPM Build …
        let size: Int64
    }

    /// 体积下限，避免把几 KB 的空目录也列出来刷屏。
    static let minSizeBytes: Int64 = 5 * 1024 * 1024

    /// 遍历深度上限（相对扫描根）。
    static let maxDepth = 5

    // MARK: - 扫描

    /// 动态遍历扫描根，返回所有孤儿依赖 / 构建缓存目录（按体积从大到小）。
    static func scan() -> [Hit] {
        let fm = FileManager.default
        var hits: [Hit] = []
        for root in scanRoots {
            let expanded = (root as NSString).expandingTildeInPath
            guard fm.fileExists(atPath: expanded) else { continue }
            var stack: [(path: String, depth: Int)] = [(expanded, 0)]
            while let (dir, depth) = stack.popLast() {
                guard depth <= maxDepth else { continue }
                guard let items = try? fm.contentsOfDirectory(atPath: dir) else { continue }
                for name in items {
                    let full = (dir as NSString).appendingPathComponent(name)
                    var isDir: ObjCBool = false
                    guard fm.fileExists(atPath: full, isDirectory: &isDir), isDir.boolValue else { continue }

                    if let manifests = manifestByTarget[name] {
                        // 命中一个目标缓存目录：判定是否孤儿。
                        if isOrphan(targetDir: full, parent: dir, manifests: manifests) {
                            let size = (try? URL(fileURLWithPath: full).directorySize()) ?? 0
                            if size >= minSizeBytes {
                                hits.append(Hit(path: full, kind: kindName(name), size: size))
                            }
                        }
                        // 不再向目标缓存目录内部下钻（体积大且无需递归）。
                        continue
                    }

                    // 普通目录：下钻。跳过明显的非目标大目录以提速。
                    if name == ".git" { continue }
                    stack.append((full, depth + 1))
                }
            }
        }
        return hits.sorted { $0.size > $1.size }
    }

    /// 父目录里存在任一源清单 → 视为活项目（跳过）；否则孤儿。
    private static func isOrphan(targetDir: String, parent: String, manifests: [String]) -> Bool {
        let fm = FileManager.default
        for m in manifests {
            if fm.fileExists(atPath: (parent as NSString).appendingPathComponent(m)) {
                return false
            }
        }
        return true
    }

    private static func kindName(_ name: String) -> String {
        switch name {
        case "node_modules": return "Node Modules"
        case ".build":       return "SwiftPM Build"
        case "Pods":         return "CocoaPods"
        case "target":       return "Cargo Target"
        case ".venv":        return "Python venv"
        case ".tox":         return "Python tox"
        case ".next":        return "Next.js Build"
        case ".nuxt":        return "Nuxt Build"
        case ".svelte-kit":  return "SvelteKit Build"
        case ".dart_tool":   return "Dart Tool"
        case ".gradle":      return "Gradle (local)"
        default:             return name
        }
    }

    // MARK: - GUI 残留分组

    /// 转成「残留」页用的分组（进入「开发工具缓存」分区）。
    static func scanGroups() -> [LeftoverGroup] {
        let hits = scan()
        guard !hits.isEmpty else { return [] }
        let artifacts = hits.map { h in
            Artifact(category: .toolCache, path: h.path, size: h.size,
                     risk: .uncertain, selected: false)
        }
        return [LeftoverGroup(
            owner: L10n.t("孤儿依赖 / 构建缓存", "Orphan dep & build caches"),
            source: .devCache, artifacts: artifacts)]
    }

    // MARK: - CLI

    /// `--orphan-caches`：列出 scratch 根下的孤儿依赖 / 构建缓存（仅扫描、不删除）。
    static func scanCLI() -> Int32 {
        let hits = scan()
        let fmt = ByteCountFormatter()
        fmt.allowedUnits = [.useGB, .useMB, .useKB]
        fmt.countStyle = .file

        guard !hits.isEmpty else {
            print("未在 \(scanRoots.joined(separator: "、")) 发现孤儿依赖 / 构建缓存。")
            return 0
        }

        var total: Int64 = 0
        print("发现的孤儿依赖 / 构建缓存（仅扫描、不删除）：")
        print("")
        for h in hits {
            total += h.size
            print("  \(h.kind)  \(h.path)  (\(fmt.string(fromByteCount: h.size)))")
        }
        print("")
        print("合计可回收：\(fmt.string(fromByteCount: total))")
        print("删除请在图形界面「残留」页确认。")
        return 0
    }
}
