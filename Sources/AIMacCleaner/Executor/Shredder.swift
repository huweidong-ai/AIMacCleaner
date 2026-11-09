import Foundation
import Security

/// 文件粉碎：把文件 / 目录用随机数据覆写多遍后再删除，使常规恢复软件无法还原。
///
/// ⚠️ 不可逆 —— 粉碎后的数据在大多数情况下无法找回。
/// - HDD：覆写多遍后基本不可恢复。
/// - SSD：受 wear-leveling（磨损均衡）影响，覆写不能 100% 保证物理块被覆盖，
///   敏感数据更可靠的做法是 FileVault 全盘加密或物理销毁。这里仍做覆写 + 删除，
///   对绝大多数场景（误恢复、普通清理）足够。
struct Shredder {

    /// 默认覆写遍数：3 遍（0xFF / 0x00 / 随机），简化版 DoD 5220.22-M。
    static let defaultPasses = 3
    /// 单次写入块大小，避免一次性把超大文件读进内存。
    private static let chunkSize = 1_048_576 // 1 MB

    enum ShredError: LocalizedError {
        case notFound(String)
        case io(URL, Error)
        /// 普通删除因权限不足失败：交由上层以管理员权限提权删除。
        case needsElevation(String)
        var errorDescription: String? {
            switch self {
            case .notFound(let p):
                return L10n.t("找不到文件：\(p)", "File not found: \(p)")
            case .io(let u, let e):
                return L10n.t("写入失败：\(u.lastPathComponent)（\(e.localizedDescription)）",
                              "Write failed: \(u.lastPathComponent) (\(e.localizedDescription))")
            case .needsElevation(let p):
                return L10n.t("权限不足，需管理员授权才能删除：\(p)",
                              "Permission denied; admin authorization required: \(p)")
            }
        }
    }

    /// 列表里展示的一项待粉碎目标。
    struct ShredItem: Identifiable {
        let id = UUID()
        let url: URL
        let name: String
        let path: String
        let isDirectory: Bool
        var size: Int64
        var fileCount: Int
        var selected: Bool
        var status: Status = .idle
        var progress: Double = 0   // 0...1
        var message: String?

        enum Status: String { case idle, shredding, failed }
    }

    /// 估算一个 URL（文件或目录）的总字节数与文件数，用于列表展示与总进度。纯读取，安全。
    static func measure(_ url: URL) -> (size: Int64, fileCount: Int) {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return (0, 0) }
        if !isDir.boolValue {
            let s = (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
            return (s, 1)
        }
        var total: Int64 = 0
        var count = 0
        if let en = fm.enumerator(at: url,
                                  includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey]) {
            for case let f as URL in en {
                let rv = try? f.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
                if rv?.isDirectory != true {
                    let s = Int64(rv?.fileSize ?? 0)
                    total += s
                    count += 1
                }
            }
        }
        return (total, count)
    }

    /// 安全删除单个 URL（文件或目录）：先覆写再 unlink。
    /// - Parameters:
    ///   - url: 目标
    ///   - passes: 覆写遍数（默认 3）
    ///   - grandTotal: 本次操作的预计总字节（用于进度归一化）
    ///   - accumulator: 已处理字节累加器（与 grandTotal 配套）
    ///   - onProgress: 进度回调，传 0...1。在调用线程同步触发，调用方自行切回主线程。
    /// - Returns: 被删除目标的字节大小。
    @discardableResult
    static func shred(_ url: URL,
                     passes: Int = defaultPasses,
                     grandTotal: Int64,
                     accumulator: UnsafeMutablePointer<Int64>,
                     onProgress: ((Double) -> Void)? = nil) throws -> Int64 {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else {
            throw ShredError.notFound(url.path)
        }
        // 先清除不可变标志（uchg）：macOS 的「锁定」标志会同时阻止覆写与删除，
        // 即便是属主 / root 也会被拒绝，所以必须在覆写之前解锁，否则后面全步都走不通。
        // 普通用户对自己文件的 uchg 有清除权限，无需提权。
        _ = clearImmutableFlag(url)
        if isDir.boolValue {
            let children = try fm.contentsOfDirectory(at: url,
                                                     includingPropertiesForKeys: nil)
            for c in children {
                _ = try shred(c, passes: passes, grandTotal: grandTotal,
                              accumulator: accumulator, onProgress: onProgress)
            }
            do {
                try fm.removeItem(at: url)
            } catch {
                // 普通删除失败（通常是权限）→ 交由上层提权删除。
                throw ShredError.needsElevation(url.path)
            }
            onProgress?(Double(accumulator.pointee) / Double(max(grandTotal, 1)))
            return grandTotal
        } else {
            // 覆写尽力而为：权限不足时写不进去，但不阻塞后面的删除尝试。
            try? shredFile(url, passes: passes, accumulator: accumulator,
                           grandTotal: grandTotal, onProgress: onProgress)
            do {
                try fm.removeItem(at: url)
            } catch {
                throw ShredError.needsElevation(url.path)
            }
            onProgress?(Double(accumulator.pointee) / Double(max(grandTotal, 1)))
            return grandTotal
        }
    }

    private static func shredFile(_ url: URL,
                                  passes: Int,
                                  accumulator: UnsafeMutablePointer<Int64>,
                                  grandTotal: Int64,
                                  onProgress: ((Double) -> Void)?) throws {
        let fm = FileManager.default
        let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        guard size > 0 else { return } // 空文件无需覆写，直接删除即可
        guard let fh = try? FileHandle(forWritingTo: url) else {
            throw ShredError.io(url, NSError(domain: "Shredder",
                                             code: 0,
                                             userInfo: [NSLocalizedDescriptionKey:
                                                        L10n.t("无法打开写入", "cannot open for writing")]))
        }
        defer { try? fh.close() }
        var lastPct = -1
        for pass in 0..<passes {
            // 前两遍填常值（0xFF / 0x00），末遍用密码学安全随机数。
            let useRandom = (pass == passes - 1)
            let fill: UInt8 = (pass == 0) ? 0xFF : 0x00
            var remaining = size
            while remaining > 0 {
                let n = min(Int64(chunkSize), remaining)
                var buf = Data(count: Int(n))
                if useRandom {
                    let rc = buf.withUnsafeMutableBytes { ptr in
                        SecRandomCopyBytes(kSecRandomDefault, Int(n), ptr.baseAddress!)
                    }
                    if rc != errSecSuccess {
                        for i in 0..<Int(n) { buf[i] = UInt8(arc4random_uniform(256)) }
                    }
                } else {
                    buf = Data(repeating: fill, count: Int(n))
                }
                let offset = size - remaining
                fh.seek(toFileOffset: UInt64(offset))
                fh.write(buf)
                remaining -= n
                accumulator.pointee += n
                let pct = Int(accumulator.pointee * 100 / max(grandTotal, 1))
                if pct != lastPct {
                    lastPct = pct
                    onProgress?(Double(accumulator.pointee) / Double(max(grandTotal, 1)))
                }
            }
            fh.synchronizeFile() // 落盘，避免覆写停留在页缓存
        }
    }

    /// 清除不可变标志（uchg）。macOS 的「锁定」标志（Finder 里勾了「已锁定」）会让文件
    /// 无法被覆写或删除，连属主 / root 都不行，必须先解锁。
    /// - 普通用户对自己拥有的文件有清除 uchg 的权限，无需提权。
    /// - 目录用 `-R` 递归，连同子项一起解锁，确保后续覆写子文件能进行。
    /// - 返回是否执行成功（失败也不致命：后续删除若仍失败会走提权删除分支）。
    @discardableResult
    static func clearImmutableFlag(_ url: URL) -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/chflags")
        proc.arguments = ["-R", "nouchg", url.path]
        proc.standardOutput = nil
        proc.standardError = nil
        do {
            try proc.run()
            proc.waitUntilExit()
            return proc.terminationStatus == 0
        } catch {
            return false
        }
    }
}
