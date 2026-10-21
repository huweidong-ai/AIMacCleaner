import Foundation

/// 「问 AI」首屏建议词的可配置化。
///
/// 为什么不放代码里：建议词是运营面——想换措辞、想推荐新能力，每次都要改 Swift
/// 再打包一遍太重。落在 app 数据目录的 `suggestions.json`，改完重启（或重进问 AI 页）
/// 即生效，不需要重新编译。
///
/// 文件不存在时自动写入一份**默认模板**：用户打开就能看懂格式、照着改。
/// JSON 解析失败（手滑改坏）时静默回退到内置默认值——首屏不能因为一个配置文件白屏。
struct PromptSuggestion: Identifiable, Decodable {
    let icon: String
    /// 中文文案。英文走 `textEn`，没给就复用中文。
    let text: String
    let textEn: String?
    /// 特殊动作。`"macTools"` = 直接给出工具面板介绍并带跳转按钮（不走模型）；
    /// `nil` = 作为建议词填进输入框，由用户自己改完再发。
    let action: String?

    var id: String { text }

    var displayText: String {
        L10n.isChinese ? text : (textEn ?? text)
    }
}

enum PromptSuggestionStore {

    /// 内置默认值 —— 与可配置化之前的八条建议词一字不差。
    static let defaults: [PromptSuggestion] = [
        PromptSuggestion(icon: "sparkles", text: "看看装了哪些 AI 工具，能清理吗",
                         textEn: "Check installed AI tools for cleanup", action: nil),
        PromptSuggestion(icon: "wand.and.rays", text: "扫一遍所有残留",
                         textEn: "Scan all leftovers", action: nil),
        PromptSuggestion(icon: "waveform.path.ecg", text: "列出后台进程",
                         textEn: "List background processes", action: nil),
        PromptSuggestion(icon: "bolt.fill", text: "ChatGPT 占的空间有多大？",
                         textEn: "How much space does ChatGPT take?", action: nil),
        PromptSuggestion(icon: "magnifyingglass", text: "看看有什么可以清理的",
                         textEn: "See what can be cleaned up", action: nil),
        PromptSuggestion(icon: "leaf", text: "给某个应用瘦身（只清缓存）",
                         textEn: "Slim an app (caches only)", action: nil),
        PromptSuggestion(icon: "arrow.counterclockwise", text: "把某个应用彻底重置（等同新装）",
                         textEn: "Fully reset an app (like a fresh install)", action: nil),
        PromptSuggestion(icon: "macwindow", text: "macOS 工具使用指南",
                         textEn: "macOS tools guide", action: "macTools")
    ]

    static var fileURL: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("AIMacCleaner", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("suggestions.json")
    }

    /// 读取当前生效的建议词。每次调用都重读文件：首屏只在出现时取一次，
    /// 一次读盘开销可以忽略，换来「改完 JSON 重进页面就生效」的体验。
    static func load() -> [PromptSuggestion] {
        let url = fileURL
        if !FileManager.default.fileExists(atPath: url.path) {
            writeTemplate(defaults, to: url)
            return defaults
        }
        guard let data = try? Data(contentsOf: url),
              let parsed = try? JSONDecoder().decode([PromptSuggestion].self, from: data),
              !parsed.isEmpty else {
            return defaults
        }
        return parsed
    }

    /// 把默认模板写盘（仅在文件不存在时），让用户有一个可以照着改的起点。
    private static func writeTemplate(_ suggestions: [PromptSuggestion], to url: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(suggestions) else { return }
        try? data.write(to: url)
    }
}
