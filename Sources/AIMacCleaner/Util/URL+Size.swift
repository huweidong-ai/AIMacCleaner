import Foundation

extension URL {
    /// 递归统计目录占用字节数。出错返回 nil。
    func directorySize() throws -> Int64 {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else { return 0 }

        // 用 du 命令比纯 Swift 遍历快很多，macOS 自带
        let process = Process()
        process.launchPath = "/usr/bin/du"
        process.arguments = ["-sk", path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        let firstLine = output.split(separator: "\n").first ?? ""
        let kbStr = firstLine.split(separator: "\t").first ?? ""
        if let kb = Int64(kbStr) {
            return kb * 1024
        }
        return 0
    }
}

enum SizeFormat {
    static func human(_ bytes: Int64) -> String {
        if bytes == 0 { return "0 KB" }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useAll]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
