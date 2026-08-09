import Foundation

/// 卸载历史，JSONL 格式追加写入 ~/Library/Application Support/AIMacCleaner/history.jsonl
/// 每行一个 RemovalRecord，对应一次卸载动作。
enum HistoryStore {
    static var historyPath: String {
        let path = "\(NSHomeDirectory())/Library/Application Support/AIMacCleaner"
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return "\(path)/history.jsonl"
    }

    struct RemovalRecord: Codable, Identifiable, Hashable {
        let id: String
        let targetName: String
        let startedAt: Date
        let finishedAt: Date
        let deletedCount: Int
        let failedCount: Int
        /// 需要用户手动处理的项数（如 ~/.zshrc 里的 shell 配置污染）。
        /// 可选是为了兼容旧历史记录：没这个字段时视为 0。
        let manualCount: Int?
        /// 真正释放的磁盘字节数。v1.3 起绝大多数删除走废纸篓，这个值通常是 0。
        let freedBytes: Int64
        /// 移到废纸篓的字节数 —— **还占着磁盘**，清空废纸篓后才真正释放。
        /// 可选是为了兼容 v1.2 及更早写入的历史记录：`listAll()` 用
        /// `try?` 跳过解不出的行，若设为非可选，旧记录会全部静默消失。
        let trashedBytes: Int64?
        let deletedArtifacts: [DeletedArtifact]
    }

    struct DeletedArtifact: Codable, Hashable {
        let category: String
        let path: String
        let risk: String
        let success: Bool
        /// true 表示该项未自动删除，需用户按提示手动处理（如编辑 shell rc）。
        /// 可选是为了兼容旧历史记录；新写入手动项时应显式传 true。
        let requiresManual: Bool?
        let message: String
    }

    static func append(_ record: RemovalRecord) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(record),
              let line = String(data: data, encoding: .utf8) else { return }
        let lineWithNewline = line + "\n"
        guard let data2 = lineWithNewline.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: historyPath) {
            if let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: historyPath)) {
                handle.seekToEndOfFile()
                handle.write(data2)
                try? handle.close()
            }
        } else {
            try? data2.write(to: URL(fileURLWithPath: historyPath))
        }
    }

    static func listAll() -> [RemovalRecord] {
        guard let content = try? String(contentsOfFile: historyPath, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var records: [RemovalRecord] = []
        for line in content.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let record = try? decoder.decode(RemovalRecord.self, from: data) else { continue }
            records.append(record)
        }
        return records.sorted { $0.startedAt > $1.startedAt }
    }

    /// 删除指定记录
    static func remove(_ record: RemovalRecord) {
        let all = listAll().filter { $0.id != record.id }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var lines: [String] = []
        for r in all {
            guard let data = try? encoder.encode(r),
                  let line = String(data: data, encoding: .utf8) else { continue }
            lines.append(line)
        }
        let content = lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")
        try? content.write(toFile: historyPath, atomically: true, encoding: .utf8)
    }

    /// 清空全部历史
    static func clear() {
        try? FileManager.default.removeItem(atPath: historyPath)
    }
}
