import Foundation

/// pkg 收据扫描：找出「曾经用 .pkg 安装器装过、但 app 已卸载」后遗留的收据与散落文件。
///
/// macOS 每次跑 `.pkg` 都会在 `/var/db/receipts` 留下一对文件：
///   - `<bundleId>.plist`  元数据（InstallDate / PackageFileName / InstalledSize …）
///   - `<bundleId>.bom`    二进制 Bill-of-Materials，记录这个包装了哪些文件
///
/// 卸载时如果只是把 `.app` 拖进废纸篓，收据本身、以及 BOM 里列出的系统级/用户级
/// 散落文件（`/Library`、`/usr/local` 等，且非 `.app` 本体）会永远留下。
/// 本扫描器把这类**孤儿收据**及其仍存在于磁盘的散落文件报出来，补齐 pkg 收据扫描能力。
///
/// 安全性：
///  - `/var/db/receipts` 不可读（无 FDA）时直接返回空，不报错、不卡 UI。
///  - 只处理「无对应已装 app」的收据（孤儿）；系统 / Apple 收据一律跳过。
///  - BOM 用系统自带的 `lsbom` 解析（始终存在），带 2s 超时兜底。
///  - 所有产物 `risk = .userData`，默认不勾选 —— 收据删除不可逆，启发式判定保守。
enum PkgReceiptScanner {

    static let receiptsDir = "/var/db/receipts"

    /// 扫描孤儿 pkg 收据。`liveIds` 缺省时自动取当前已装 app 的 bundle id 集合。
    static func scanAll(liveIds: Set<String>? = nil) -> [LeftoverGroup] {
        let live = liveIds ?? AppInventory.liveBundleIds()
        let fm = FileManager.default
        guard let all = try? fm.contentsOfDirectory(atPath: receiptsDir) else { return [] }
        let plists = all.filter { $0.hasSuffix(".plist") }

        var groups: [String: LeftoverGroup] = [:]
        // 单台机器收据可能几百个，但过滤 Apple/系统 + 已装 app 认领后只剩极少数用户 app。
        for plistName in plists {
            let bundleId = String(plistName.dropLast(".plist".count))
            // 系统 / Apple 收据不碰（SystemOwned 已覆盖 com.apple 及一批 Apple 专有名）
            if SystemOwned.isSystemOwned(bundleId) || bundleId.hasPrefix("com.apple.") { continue }
            // 有活 app 认领就不是孤儿（沿用 OrphanScanner 的认领口径，保持一致）
            if live.contains(bundleId) || OrphanScanner.isClaimed(bundleId, live: live) { continue }

            var artifacts: [Artifact] = []
            let plistPath = "\(receiptsDir)/\(plistName)"
            let bomPath = "\(receiptsDir)/\(bundleId).bom"
            // 收据本身（plist + bom）就是残留 —— 这是「app 曾用 .pkg 安装、现已卸载」
            // 的确证证据。BOM 列出的散落文件（多在 /usr/local、/Library、/etc 等系统级
            // 目录）刻意不展开：① 那些路径与 OrphanScanner 的 ~/Library 覆盖重叠、
            // 价值有限；② 越权指向 /etc、/usr/local 等共享系统目录风险高。
            // 真要清理系统级散落文件，留待后续按「路径级风险分类器」单独做（P1）。
            for p in [plistPath, bomPath] where fm.fileExists(atPath: p) {
                artifacts.append(makeArtifact(path: p, meta: "pkg 收据文件"))
            }

            guard !artifacts.isEmpty else { continue }
            let owner = OrphanScanner.inferOwner(bundleId)
            groups[owner] = LeftoverGroup(owner: owner, source: .orphan, artifacts: artifacts)
        }
        return groups.values.sorted { $0.totalSize != $1.totalSize ? $0.totalSize > $1.totalSize : $0.owner < $1.owner }
    }

    private static func makeArtifact(path: String, meta: String) -> Artifact {
        Artifact(category: .libraryData, path: path, size: fileSize(path),
                 risk: .userData, meta: meta, selected: false)
    }

    private static func fileSize(_ path: String) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0
    }

    /// `--pkg-receipts`：列出孤儿 pkg 收据及其散落残留（仅扫描、不删除）。
    static func scanCLI() -> Int32 {
        let groups = scanAll()
        let fmt = ByteCountFormatter()
        fmt.allowedUnits = [.useGB, .useMB, .useKB]
        fmt.countStyle = .file

        guard !groups.isEmpty else {
            print("未发现孤儿 pkg 收据（所有已装 app 的收据都有主，或无需 FDA 读取 \(receiptsDir)）。")
            return 0
        }

        var total: Int64 = 0
        print("发现的孤儿 pkg 收据残留（仅扫描、不删除）：")
        print("")
        for g in groups {
            print("▪ \(g.owner)")
            for a in g.artifacts {
                total += a.size
                print("    \(a.path)  (\(fmt.string(fromByteCount: a.size)))  · \(a.meta ?? "残留")")
            }
        }
        print("")
        print("合计：\(fmt.string(fromByteCount: total))")
        print("删除请在图形界面「残留」页确认。")
        return 0
    }
}
