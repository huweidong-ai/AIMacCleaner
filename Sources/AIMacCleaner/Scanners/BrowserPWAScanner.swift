import Foundation

/// 扫描 Chrome / Edge 等 Chromium 系浏览器 PWA 在浏览器 profile 里的真实数据。
///
/// 存在的理由：浏览器「安装应用」生成的 PWA（`com.google.Chrome.app.<appid>`），
/// `~/Applications` 里那个 .app 只是 `app_mode_loader` 壳子。真正的数据全在
/// 浏览器 profile 里，而**目录名和 PWA 的名字毫无关系**：
/// - `<profile>/Web Applications/_crXXX/<appid>/` —— 图标与 manifest（appid 是 32 位 hex）
/// - `<profile>/Storage/ext/<appid>/` —— 隔离存储（isolated web app）
/// - `<profile>/IndexedDB/https_<源站>_*` —— 按源站命名的站点数据
///
/// 现有扫描器按「目录名含 app 名」匹配，在这三种形状上全部漏掉——
/// 用户只扫出 2.2 MB 的壳子，几十 MB 的站点数据留在 Chrome 里成了无主残留。
/// 本扫描器改用 **appid 与源站** 作为主键：从 bundle id 末段取出 appid，
/// 再从 manifest 的 `start_url` 解析源站 host，按 host 匹配 IndexedDB 目录。
struct BrowserPWAScanner: Scanner {
    let name = "BrowserPWAScanner"

    /// Chromium 系浏览器的 profile 根目录。PWA 可能装在其中任何一个上。
    static func browserRoots(_ home: String) -> [(root: String, browser: String)] {
        let asDir = home + "/Library/Application Support"
        return [
            ("\(asDir)/Google/Chrome", "Chrome"),
            ("\(asDir)/Microsoft Edge", "Edge"),
            ("\(asDir)/BraveSoftware/Brave-Browser", "Brave"),
            ("\(asDir)/Chromium", "Chromium")
        ]
    }

    /// bundle id 末段即 PWA appid。Chrome 的 appid 是 32 个字符、取自 **a–p 16 字母表**
    ///（不是 hex！`l`/`o`/`n` 都会出现，拿 `isHexDigit` 校验会全部拒掉）。
    /// 过短或字符集不符时放弃匹配——宁可漏报也不拿一个通用词去 profile 里乱撞。
    static func pwaAppID(from bundleId: String?) -> String? {
        guard let last = bundleId?.lowercased().split(separator: ".").last,
              last.count >= 8,
              last.allSatisfy({ ("a"..."p").contains(String($0)) })
        else { return nil }
        return String(last)
    }

    func scan(query: ScanQuery) async -> [Artifact] {
        guard let app = query.app, app.isPWA,
              let appid = Self.pwaAppID(from: app.bundleId) else { return [] }

        var results: [Artifact] = []
        let fm = FileManager.default
        for (root, browser) in Self.browserRoots(NSHomeDirectory()) {
            guard let profiles = try? fm.contentsOfDirectory(atPath: root) else { continue }
            for profile in profiles where !profile.hasPrefix(".") {
                let profilePath = "\(root)/\(profile)"
                results.append(contentsOf: scanWebApplications(
                    profilePath: profilePath, appid: appid, browser: browser))
                results.append(contentsOf: scanIsolatedStorage(
                    profilePath: profilePath, appid: appid, browser: browser))
                results.append(contentsOf: scanOriginData(
                    profilePath: profilePath, appid: appid, browser: browser))
            }
        }
        return results
    }

    // MARK: - <profile>/Web Applications

    /// 图标 + manifest。真机布局：`<profile>/Web Applications/Manifest Resources/<appid>/`，
    /// 但不同版本/浏览器层级不保证一致，所以在 `Web Applications` 下限深 3 层、
    /// 按目录名精确等于 appid 匹配（appid 是 32 位 hex，不会撞名）。
    private func scanWebApplications(profilePath: String, appid: String, browser: String) -> [Artifact] {
        let waRoot = "\(profilePath)/Web Applications"
        let fm = FileManager.default
        guard fm.fileExists(atPath: waRoot) else { return [] }
        var results: [Artifact] = []
        let enumerator = fm.enumerator(atPath: waRoot)
        var depth: [String: Int] = [waRoot: 0]
        while let sub = enumerator?.nextObject() as? String {
            let path = "\(waRoot)/\(sub)"
            let parent = (path as NSString).deletingLastPathComponent
            let level = (depth[parent] ?? 0) + 1
            depth[path] = level
            guard level <= 3 else { enumerator?.skipDescendants(); continue }
            // 枚举产出的是相对路径（如 "Manifest Resources/<appid>"），比对取末段。
            guard (sub as NSString).lastPathComponent == appid,
                  let vals = try? fm.attributesOfItem(atPath: path),
                  let isDir = vals[.type] as? FileAttributeType, isDir == .typeDirectory
            else { continue }
            enumerator?.skipDescendants()
            // 只有图标与 manifest，删了 Chrome 会重新生成 —— 可安全删除。
            results.append(Artifact(
                category: .libraryData,
                path: path,
                size: Self.sizeRecursively(path),
                risk: .safe,
                meta: "\(browser) 为这个 PWA 存的图标与 manifest"
            ))
        }
        return results
    }

    // MARK: - <profile>/Storage/ext/<appid>

    /// isolated web app 的隔离存储。存在与否不确定，逐层探测代价可忽略。
    private func scanIsolatedStorage(profilePath: String, appid: String, browser: String) -> [Artifact] {
        let storageRoot = "\(profilePath)/Storage"
        let fm = FileManager.default
        guard fm.fileExists(atPath: storageRoot) else { return [] }
        var results: [Artifact] = []
        for extDir in ["ext", "isolated"] {
            let dir = "\(storageRoot)/\(extDir)"
            guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for entry in entries where entry.contains(appid) {
                let path = "\(dir)/\(entry)"
                results.append(Artifact(
                    category: .libraryData,
                    path: path,
                    size: Self.sizeRecursively(path),
                    risk: .userData,
                    meta: "\(browser) 为这个 PWA 开的隔离存储（可能含登录态）"
                ))
            }
        }
        return results
    }

    // MARK: - 按源站匹配站点数据

    /// PWA 的站点数据（IndexedDB 等）按源站命名（`https_<host>_<port>_0.indexeddb.leveldb`）。
    /// 源站从 manifest 的 `start_url` / `url` 里解析出来。
    private func scanOriginData(profilePath: String, appid: String, browser: String) -> [Artifact] {
        guard let host = Self.originHost(profilePath: profilePath, appid: appid),
              host.count >= 4 else { return [] }
        let fm = FileManager.default
        var results: [Artifact] = []

        let originDirs = [("\(profilePath)/IndexedDB", "IndexedDB（站点数据库，可能含离线数据）")]
        for (dir, label) in originDirs {
            guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for entry in entries where entry.lowercased().contains(host) {
                let path = "\(dir)/\(entry)"
                results.append(Artifact(
                    category: .libraryData,
                    path: path,
                    size: Self.sizeRecursively(path),
                    risk: .userData,
                    meta: "\(browser) 里这个 PWA 源站（\(host)）的\(label)"
                ))
            }
        }
        return results
    }

    /// 在 `<profile>/Web Applications` 下找 `<…>/<appid>/manifest.json`，解析出源站 host。
    /// 层级不假设（真机在 `Manifest Resources/` 下一层），递归限深 3 层。
    static func originHost(profilePath: String, appid: String) -> String? {
        let fm = FileManager.default
        let waRoot = "\(profilePath)/Web Applications"
        guard let enumerator = fm.enumerator(atPath: waRoot) else { return nil }
        var depth: [String: Int] = [waRoot: 0]
        while let sub = enumerator.nextObject() as? String {
            let path = "\(waRoot)/\(sub)"
            let parent = (path as NSString).deletingLastPathComponent
            let level = (depth[parent] ?? 0) + 1
            depth[path] = level
            guard level <= 4 else { enumerator.skipDescendants(); continue }
            guard (sub as NSString).lastPathComponent == appid else { continue }
            enumerator.skipDescendants()
            for manifestName in ["manifest.json", "manifest"] {
                guard let data = fm.contents(atPath: "\(path)/\(manifestName)"),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                for key in ["start_url", "url", "app_url", "scope"] {
                    if let s = obj[key] as? String,
                       let url = URL(string: s),
                       let host = url.host, !host.isEmpty {
                        return host.lowercased()
                    }
                }
            }
        }
        return nil
    }

    // MARK: - 工具

    /// 目录总大小（递归）。跳过无权限项；出错按 0 处理。
    static func sizeRecursively(_ path: String) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(atPath: path) else { return 0 }
        var total: Int64 = 0
        for case let sub as String in enumerator {
            let attrs = try? fm.attributesOfItem(atPath: "\(path)/\(sub)")
            total += (attrs?[.size] as? Int64) ?? 0
        }
        return total
    }
}
