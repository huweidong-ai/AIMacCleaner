import Foundation
import AppKit
import UniformTypeIdentifiers

/// 把「问 AI」的对话记录整理成人类可读的文本，并支持导出为文件。
///
/// 为什么要单独做：反馈 AI 回答、离线存档、贴给开发者排查，都要的是
/// **人能读**的对话稿，而不是 `ChatStore` 落盘的 JSON（带结构噪声、不可读）。
/// 这里只负责「渲染」，不碰任何业务状态。
enum ChatTranscript {

    /// 把消息序列渲染成一份带时间戳、含思考过程与执行步骤的 Markdown 文本。
    /// 锚点消息（`/reset` 分割线）不进稿子 —— 它对读者没有信息量。
    static func string(from messages: [AIMessage]) -> String {
        let df = DateFormatter()
        df.dateStyle = .short
        df.timeStyle = .short
        df.locale = Locale(identifier: L10n.isChinese ? "zh_CN" : "en_US")

        var out: [String] = []
        out.append(L10n.t("# AI Mac Cleaner 对话记录", "# AI Mac Cleaner chat transcript"))
        out.append("")
        out.append(L10n.t("导出时间：", "Exported: ")
                   + DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .short))
        let real = messages.filter { $0.role != .system }
        out.append(L10n.t("对话条数：", "Messages: ") + "\(real.count)")
        out.append("")

        for m in messages where m.role != .system {
            let who = m.role == .me ? L10n.t("我", "Me") : L10n.t("AI", "AI")
            out.append("## \(who) · \(df.string(from: m.createdAt))")
            if let r = m.reasoning, !r.isEmpty {
                out.append("")
                out.append(L10n.t("<思考过程>", "<reasoning>"))
                out.append(r)
            }
            out.append("")
            out.append(m.text.isEmpty ? L10n.t("（无文本）", "(no text)") : m.text)
            if !m.steps.isEmpty {
                out.append("")
                out.append(L10n.t("执行步骤：", "Steps:"))
                for s in m.steps {
                    let mark = s.ok ? "✓" : "✗"
                    out.append("- \(mark) \(s.summary)")
                }
            }
            out.append("")
            out.append("---")
            out.append("")
        }

        return out.joined(separator: "\n").trimmingCharacters(in: .newlines)
    }

    /// 弹出保存面板，把对话稿写成 `.md` 文件。
    /// - 返回 `true`：写盘成功。
    /// - 返回 `false`：面板确认了但写盘失败（极少见，调用方可提示）。
    /// - 返回 `nil`：用户取消（`runModal` 非 OK），调用方不应打扰。
    static func export(_ messages: [AIMessage]) -> Bool? {
        let text = string(from: messages)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "AIMacCleaner-对话记录-\(stamp()).md"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText, .plainText]
        panel.canCreateDirectories = true
        panel.title = L10n.t("导出对话记录", "Export chat transcript")
        panel.message = L10n.t("把当前对话保存为 Markdown 文件。",
                               "Save the current conversation as a Markdown file.")

        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }

    /// 文件名里的时间戳（本地时区，精确到分钟，避免重名）。
    private static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmm"
        return f.string(from: Date())
    }
}
