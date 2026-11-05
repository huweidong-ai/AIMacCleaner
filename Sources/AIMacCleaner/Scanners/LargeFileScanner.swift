import Foundation

/// 大文件清理：扫描用户目录里「体积大且久未访问」的文件，
/// 以及启动磁盘缓存目录里的大缓存文件夹，帮用户腾出空间。
///
/// 与卸载/残留扫描器不同，这里不产出 `Artifact`（不走删除计划那套），
/// 而是返回独立的 `LargeFileItem`：删除走「移到废纸篓」，用户随时能拖回来，
/// 比直接 `rm` 安全一个量级。

/// 文件分类（决定图标与聚合展示）。
enum FileCategory: String, CaseIterable, Identifiable {
    case video, image, archive, diskImage, cache, document, other
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .video:     return L10n.t("视频", "Videos")
        case .image:     return L10n.t("图片", "Images")
        case .archive:   return L10n.t("压缩包", "Archives")
        case .diskImage: return L10n.t("磁盘镜像", "Disk images")
        case .cache:     return L10n.t("应用缓存", "App caches")
        case .document:  return L10n.t("文档", "Documents")
        case .other:     return L10n.t("其他", "Other")
        }
    }

    var icon: String {
        switch self {
        case .video:     return "film"
        case .image:     return "photo"
        case .archive:   return "doc.zipper"
        case .diskImage: return "opticaldiscdrive"
        case .cache:     return "tray.full"
        case .document:  return "doc.text"
        case .other:     return "doc"
        }
    }
}

/// 一个大文件 / 大缓存文件夹的扫描结果。
struct LargeFileItem: Identifiable {
    let id = UUID()
    let path: String
    let size: Int64
    let lastAccess: Date
    let category: FileCategory
    /// true = 这是一个文件夹（缓存目录），删除时整体移入废纸篓。
    let isDirectory: Bool
    var selected: Bool

    var name: String { (path as NSString).lastPathComponent }
    var parent: String { (path as NSString).deletingLastPathComponent }
}

enum LargeFileScanner {

    /// 默认扫描的用户目录。缓存目录单独处理（只列顶层，避免递归进 app 沙盒深处）。
    static let defaultScanDirs: [String] = [
        NSHomeDirectory() + "/Downloads",
        NSHomeDirectory() + "/Desktop",
        NSHomeDirectory() + "/Documents",
        NSHomeDirectory() + "/Movies",
        NSHomeDirectory() + "/Pictures"
    ]
    static let cacheDir: String = NSHomeDirectory() + "/Library/Caches"

    /// 递归扫描时跳过的目录名（依赖缓存、构建产物、版本库等噪声）。
    private static let skipDirNames: Set<String> = [
        "node_modules", ".git", ".npm", ".cache", "Caches",
        ".rustup", "vendor", ".vagrant", ".Trash", "DerivedData"
    ]

    /// 执行扫描。
    /// - Parameters:
    ///   - thresholdBytes: 仅纳入体积 ≥ 此值的项（默认 100MB）。
    ///   - minAgeDays: 仅纳入「最后访问」距今 ≥ 此天数的项（默认 30 天）。
    ///   - maxResults: 结果上限，防止极端情况下 UI 被刷爆。
    static func scan(thresholdBytes: Int64,
                     minAgeDays: Int,
                     maxResults: Int = 1500) -> [LargeFileItem] {
        var results: [LargeFileItem] = []
        let cutoff = Date().addingTimeInterval(-Double(minAgeDays) * 86_400)
        let fm = FileManager.default

        for dir in defaultScanDirs {
            guard fm.fileExists(atPath: dir) else { continue }
            enumerateUserDir(dir, thresholdBytes: thresholdBytes, cutoff: cutoff,
                             maxResults: maxResults, results: &results)
            if results.count >= maxResults { break }
        }

        // 缓存目录：只列顶层，文件直接计入，文件夹算「浅层」体积（ immediate 子项之和）。
        if fm.fileExists(atPath: cacheDir) {
            enumerateCaches(cacheDir, thresholdBytes: thresholdBytes, cutoff: cutoff,
                            maxResults: maxResults, results: &results)
        }

        return results.sorted { $0.size > $1.size }
    }

    // MARK: - 递归枚举用户目录

    private static func enumerateUserDir(_ dir: String,
                                         thresholdBytes: Int64,
                                         cutoff: Date,
                                         maxResults: Int,
                                         results: inout [LargeFileItem]) {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(atPath: dir) else { return }
        while let relative = enumerator.nextObject() as? String {
            let components = (relative as NSString).pathComponents
            // 隐藏文件 / 目录（含 . 开头）整支跳过。
            if components.contains(where: { $0.hasPrefix(".") }) {
                enumerator.skipDescendants()
                continue
            }
            // 已知噪声目录整支跳过。
            if let last = components.last, skipDirNames.contains(last) {
                enumerator.skipDescendants()
                continue
            }
            let full = (dir as NSString).appendingPathComponent(relative)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: full, isDirectory: &isDir), !isDir.boolValue else { continue }
            if let item = makeItem(path: full, fm: fm, category: categorize(full), cutoff: cutoff),
               item.size >= thresholdBytes {
                results.append(item)
                if results.count >= maxResults { return }
            }
        }
    }

    // MARK: - 缓存目录（顶层）

    private static func enumerateCaches(_ dir: String,
                                        thresholdBytes: Int64,
                                        cutoff: Date,
                                        maxResults: Int,
                                        results: inout [LargeFileItem]) {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(atPath: dir) else { return }
        for name in contents where !name.hasPrefix(".") {
            let full = (dir as NSString).appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: full, isDirectory: &isDir) else { continue }
            let (size, access): (Int64, Date)
            if isDir.boolValue {
                size = shallowFolderSize(full)
                access = folderNewestAccess(full)
            } else {
                guard let attrs = try? fm.attributesOfItem(atPath: full) else { continue }
                size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
                access = accessDate(of: attrs) ?? Date()
            }
            guard size >= thresholdBytes, access <= cutoff else { continue }
            results.append(LargeFileItem(path: full, size: size, lastAccess: access,
                                        category: .cache, isDirectory: isDir.boolValue, selected: false))
            if results.count >= maxResults { return }
        }
    }

    /// 文件夹浅层体积：只累加 immediate 子项的大小（不递归），足够定位「大缓存文件夹」。
    private static func shallowFolderSize(_ dir: String) -> Int64 {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(atPath: dir) else { return 0 }
        var total: Int64 = 0
        for name in contents where !name.hasPrefix(".") {
            let full = (dir as NSString).appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: full, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                total += shallowFolderSize(full) // 再下一层，避免单层低估嵌套缓存
            } else if let attrs = try? fm.attributesOfItem(atPath: full),
                      let s = (attrs[.size] as? NSNumber)?.int64Value {
                total += s
            }
        }
        return total
    }

    /// 文件夹内最新访问时间（取 immediate 子项里最新的那一个）。
    private static func folderNewestAccess(_ dir: String) -> Date {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(atPath: dir) else { return Date.distantPast }
        var newest = Date.distantPast
        for name in contents where !name.hasPrefix(".") {
            let full = (dir as NSString).appendingPathComponent(name)
            if let attrs = try? fm.attributesOfItem(atPath: full) {
                if let d = accessDate(of: attrs), d > newest { newest = d }
            }
        }
        return newest
    }

    // MARK: - 工具

    private static func makeItem(path: String, fm: FileManager,
                                 category: FileCategory, cutoff: Date) -> LargeFileItem? {
        guard let attrs = try? fm.attributesOfItem(atPath: path) else { return nil }
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let access = accessDate(of: attrs) ?? Date()
        guard access <= cutoff else { return nil }
        return LargeFileItem(path: path, size: size, lastAccess: access,
                            category: category, isDirectory: false, selected: false)
    }

    /// 访问时间代理：优先用修改时间，退回创建时间（contentAccessDate 并非在所有
    /// 文件系统上都可靠，且本 SDK 上下文无法稳定解析，故统一用修改时间）。
    private static func accessDate(of attrs: [FileAttributeKey: Any]) -> Date? {
        if let d = attrs[FileAttributeKey.modificationDate] as? Date { return d }
        return attrs[FileAttributeKey.creationDate] as? Date
    }

    /// 按扩展名归类。
    static func categorize(_ path: String) -> FileCategory {
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "mp4", "mov", "m4v", "avi", "mkv", "wmv", "flv", "webm", "mpg", "mpeg", "ts":
            return .video
        case "jpg", "jpeg", "png", "heic", "heif", "gif", "tiff", "tif", "raw",
             "cr2", "cr3", "nef", "arw", "dng", "bmp", "webp":
            return .image
        case "zip", "tar", "gz", "bz2", "7z", "rar", "tgz", "xz", "zst":
            return .archive
        case "dmg", "iso", "img", "vmdk", "sparseimage", "toast", "cdr":
            return .diskImage
        case "pdf", "doc", "docx", "ppt", "pptx", "xls", "xlsx", "key",
             "pages", "numbers", "epub", "rtf", "csv":
            return .document
        default:
            return .other
        }
    }

    /// 把选中的项移到废纸篓。返回实际成功移入的项数。
    @discardableResult
    static func trash(_ items: [LargeFileItem]) -> Int {
        let fm = FileManager.default
        var deleted = 0
        for item in items {
            let url = URL(fileURLWithPath: item.path)
            do {
                // 移到废纸篓：误删能拖回来，比直接 rm 安全。
                try fm.trashItem(at: url, resultingItemURL: nil)
                deleted += 1
            } catch {
                // 单个失败不影响其余；UI 会重扫反映真实状态。
            }
        }
        return deleted
    }
}
