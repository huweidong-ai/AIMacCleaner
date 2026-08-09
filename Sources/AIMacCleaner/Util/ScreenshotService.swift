import Foundation
import AppKit

/// 截图模式，映射到系统 `screencapture` 的参数。
enum ScreenshotMode: String {
    case selection  // 拖拽选区（交互）
    case window     // 点选窗口
    case full       // 整屏
}

/// 截图服务：薄封装系统自带的 `/usr/sbin/screencapture`。
///
/// 设计取舍：
/// - **零依赖、零资源占用**：app 本体不打包任何截图引擎，只调系统已有的二进制。
///   真正编码发生在系统进程里，app 仅负责「触发一下」并等它结束。
/// - **磁盘占用仅来自用户保存的 PNG**（一张全屏约 0.5–3 MB），存放在
///   `~/Pictures/AI Mac Cleaner Screenshots`，随手可删，不算 app 开销。
/// - 交互模式（选区 / 窗口）下用户按 Esc 取消，`screencapture` 退出码非 0
///   且不落盘 —— 此时 completion 收到 `nil`，调用方应当静默不提示。
enum ScreenshotService {

    /// 截图统一存放目录。首次访问时创建（失败则回退到桌面），不抛错。
    static var saveDir: URL {
        let base = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Desktop")
        let dir = base.appendingPathComponent("AI Mac Cleaner Screenshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 调系统 `screencapture` 截图。`completion` 永远在主线程回调，
    /// 取消（Esc）时收到 `nil`。
    static func capture(_ mode: ScreenshotMode, completion: ((URL?) -> Void)? = nil) {
        let stamp = Self.stamp()
        let out = saveDir.appendingPathComponent("AIMacCleaner-\(stamp).png")

        var args: [String]
        switch mode {
        case .selection: args = ["-i", "-s", "-x"]   // 交互选区，无快门声
        case .window:    args = ["-w", "-x"]          // 点选窗口，无快门声
        case .full:      args = ["-x"]                // 整屏（无 -i，立即抓）
        }
        args.append(out.path)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        proc.arguments = args
        proc.terminationHandler = { _ in
            let saved = FileManager.default.fileExists(atPath: out.path) ? out : nil
            DispatchQueue.main.async { completion?(saved) }
        }
        do {
            try proc.run()
        } catch {
            DispatchQueue.main.async { completion?(nil) }
        }
    }

    /// 时间戳文件名：AIMacCleaner-20260809-143005.png
    private static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }
}
