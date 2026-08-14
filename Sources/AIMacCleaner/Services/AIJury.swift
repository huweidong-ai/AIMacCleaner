import Foundation

/// 真 AI 判定服务：用 `LLMClient` 做**单轮结构化判断**，不绕 Agent 多轮 loop。
///
/// 三个用途：
/// 1. 应用页「让 AI 分析」—— 挑出不该删的项（登录态 / 凭据 / 共享数据）；
/// 2. 残留页「让 AI 帮我判断」—— 挑出能放心删的项；
/// 3. 进程页「AI 判断后果」—— 判断结束某进程会怎样。
///
/// 全部返回 `nil` 表示「没能用上模型」（未配置 / 调用失败），调用方据此
/// 提示用户去配置或重试，**绝不降级成本地规则伪造结论**——这是「纯 AI」的底线。
enum AIJury {

    // MARK: - 应用分析：挑不该删的

    static func reviewApps(_ items: [Artifact], config: AIModelConfig) async -> [UUID: String]? {
        guard config.isConfigured else { return nil }
        let list = Array(items.prefix(60))
        guard !list.isEmpty else { return [:] }
        let lines = list.enumerated().map { i, a in
            "\(i). [\(a.risk.label)] \(a.category.rawValue) \(a.path) (\(SizeFormat.human(a.size)))"
        }.joined(separator: "\n")
        let system = L10n.t(
            "你是 macOS 深度卸载工具的分析助手。下面是一组准备随某应用一起删除的文件痕迹。请判断哪些【不应被删除】，通常是：登录态/凭据、被其它应用共享的数据、用户显式配置、订阅/授权信息、正在使用的数据库、插件或扩展。只输出 JSON，格式：{\"keep\": {\"<序号>\": \"<一句话理由>\"}}。只列出你建议保留的项；没有则输出 {\"keep\": {}}。不要输出 JSON 以外的任何文字。",
            "You are the review assistant of a macOS deep-uninstall tool. Below is a set of file traces about to be deleted along with an app. Decide which ones should NOT be deleted — typically: login state/credentials, data shared with other apps, explicit user config, subscription/license info, live databases, plugins or extensions. Output ONLY JSON: {\"keep\": {\"<index>\": \"<one-line reason>\"}}. List only items to keep; if none, output {\"keep\": {}}. Do not output any text outside the JSON.")
        let user = L10n.t("待删除文件：\n", "Traces pending deletion:\n") + lines
        guard let reply = try? await LLMClient.complete(config: config,
                                                         messages: [(role: "user", content: user)],
                                                         system: system),
              let obj = extractObject(reply),
              let keep = obj["keep"] as? [String: String]
        else { return nil }
        return mapIndexDict(keep, list: list)
    }

    // MARK: - 残留判断：挑能放心删的

    static func reviewLeftovers(_ items: [Artifact], config: AIModelConfig) async -> [UUID: String]? {
        guard config.isConfigured else { return nil }
        let list = Array(items.prefix(60))
        guard !list.isEmpty else { return [:] }
        let lines = list.enumerated().map { i, a in
            "\(i). [\(a.risk.label)] \(a.category.rawValue) \(a.path) (\(SizeFormat.human(a.size)))"
        }.joined(separator: "\n")
        let system = L10n.t(
            "你是 macOS 清理工具的残留判定助手。下面是一组疑似已卸载应用留下的无主数据。请判断哪些【可以放心删除】，通常是：缓存、日志、明确属于该应用且不含登录态的容器、临时文件。只输出 JSON，格式：{\"safe\": {\"<序号>\": \"<一句话理由>\"}}。只列出你判断可以安全删除的项；拿不准（可能是共享数据、配置、或其它应用在用）的不要列入。不要输出 JSON 以外的任何文字。",
            "You are the leftover-judging assistant of a macOS cleanup tool. Below are orphaned data likely left by uninstalled apps. Decide which can be safely deleted — typically caches, logs, app-specific containers without login state, temp files. Output ONLY JSON: {\"safe\": {\"<index>\": \"<one-line reason>\"}}. List only items you judge safe to delete; when unsure (could be shared data, config, or used by another app) leave them out. Do not output any text outside the JSON.")
        let user = L10n.t("待判定残留：\n", "Leftovers to judge:\n") + lines
        guard let reply = try? await LLMClient.complete(config: config,
                                                         messages: [(role: "user", content: user)],
                                                         system: system),
              let obj = extractObject(reply),
              let safe = obj["safe"] as? [String: String]
        else { return nil }
        return mapIndexDict(safe, list: list)
    }

    // MARK: - 进程后果判断

    static func judgeProcesses(_ items: [LiveProcess], config: AIModelConfig) async -> [pid_t: ProcessVerdict]? {
        guard config.isConfigured else { return nil }
        let list = Array(items.prefix(40))
        guard !list.isEmpty else { return [:] }
        let lines = list.enumerated().map { i, p in
            "\(i). \(p.name) pid=\(p.pid) kind=\(p.kind.rawValue) cpu=\(String(format: "%.0f", p.cpuPercent))% mem=\(SizeFormat.human(p.memoryBytes)) path=\(p.executablePath) args=\(p.arguments.prefix(6).joined(separator: " "))"
        }.joined(separator: "\n")
        let system = L10n.t(
            "你是 macOS 进程管理助手。下面是一组用户想结束的进程。请逐项判断【结束它的后果】：会不会丢未保存的工作、会不会让某个 GUI 应用崩溃或失联、是不是某个开发服务器的子进程、影响范围多大。只输出 JSON 数组：[{\"idx\": <序号>, \"level\": \"high|medium|low\", \"text\": \"<后果说明>\"}]。level=high 表示高风险（会崩溃重要应用/丢工作），medium 表示有影响但可控，low 表示基本无害。不要输出 JSON 以外的文字。",
            "You are a macOS process-management assistant. Below are processes the user wants to end. For each, judge the CONSEQUENCE of killing it: will it lose unsaved work, crash or disconnect a GUI app, is it a child of a dev server, how broad is the impact. Output ONLY a JSON array: [{\"idx\": <index>, \"level\": \"high|medium|low\", \"text\": \"<consequence>\"}]. level=high means high risk (crashes an important app / loses work), medium means impactful but recoverable, low means essentially harmless. Do not output any text outside the JSON.")
        let user = L10n.t("待结束进程：\n", "Processes to end:\n") + lines
        guard let reply = try? await LLMClient.complete(config: config,
                                                         messages: [(role: "user", content: user)],
                                                         system: system),
              let arr = extractArray(reply)
        else { return nil }
        var out: [pid_t: ProcessVerdict] = [:]
        for entry in arr {
            guard let idx = entry["idx"] as? Int, idx < list.count,
                  let levelRaw = entry["level"] as? String,
                  let text = entry["text"] as? String, !text.isEmpty
            else { continue }
            let level: ProcessVerdict.Level = levelRaw == "high" ? .high
                : levelRaw == "medium" ? .medium : .low
            out[list[idx].pid] = ProcessVerdict(level: level, text: text)
        }
        return out.isEmpty ? nil : out
    }

    // MARK: - 解析辅助

    private static func mapIndexDict(_ dict: [String: String], list: [Artifact]) -> [UUID: String] {
        var out: [UUID: String] = [:]
        for (k, v) in dict {
            if let idx = Int(k), idx < list.count, !v.isEmpty {
                out[list[idx].id] = v
            }
        }
        return out
    }

    /// 从模型回复里尽量抠出第一个 JSON 对象（兼容 ```json 代码块 / 前后多余文字）。
    private static func extractObject(_ raw: String) -> [String: Any]? {
        let s = stripFences(raw)
        guard let start = s.firstIndex(of: "{"), let end = s.lastIndex(of: "}") else { return nil }
        let sub = String(s[start...end])
        return (try? JSONSerialization.jsonObject(with: Data(sub.utf8))) as? [String: Any]
    }

    private static func extractArray(_ raw: String) -> [[String: Any]]? {
        let s = stripFences(raw)
        guard let start = s.firstIndex(of: "["), let end = s.lastIndex(of: "]") else { return nil }
        let sub = String(s[start...end])
        return (try? JSONSerialization.jsonObject(with: Data(sub.utf8))) as? [[String: Any]]
    }

    private static func stripFences(_ raw: String) -> String {
        var s = raw
        if let fence = s.range(of: "```") { s = String(s[fence.upperBound...]) }
        if let fence2 = s.range(of: "```") { s = String(s[..<fence2.lowerBound]) }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// 单个进程被结束后的后果判定。
struct ProcessVerdict: Hashable {
    enum Level: String, Hashable {
        case high, medium, low
    }
    let level: Level
    let text: String
}
