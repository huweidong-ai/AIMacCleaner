import Foundation

/// 一次模型调用的 token 用量。跨协议归一化：OpenAI 的
/// `prompt_tokens / completion_tokens / prompt_tokens_details.cached_tokens`
/// 与 Anthropic 的 `input_tokens / output_tokens / cache_read_input_tokens /
/// cache_creation_input_tokens` 都映射到同一组字段。
///
/// 解析永远容错：端点没返回 usage 时得到全 0，不影响回答本身。
struct TokenUsage: Codable, Equatable {
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var cacheReadTokens: Int = 0
    var cacheWriteTokens: Int = 0

    var isEmpty: Bool {
        inputTokens == 0 && outputTokens == 0 && cacheReadTokens == 0 && cacheWriteTokens == 0
    }

    mutating func add(_ other: TokenUsage) {
        inputTokens += other.inputTokens
        outputTokens += other.outputTokens
        cacheReadTokens += other.cacheReadTokens
        cacheWriteTokens += other.cacheWriteTokens
    }

    /// 从 JSON 对象里取 usage。兼容顶层 `usage` 与 Anthropic `message.start.message.usage`。
    static func parse(_ obj: [String: Any]?, anthropic: Bool) -> TokenUsage {
        guard let obj else { return TokenUsage() }
        var usage = obj["usage"] as? [String: Any]
        if usage == nil {
            usage = (obj["message"] as? [String: Any])?["usage"] as? [String: Any]
        }
        guard let usage else { return TokenUsage() }
        var result = TokenUsage()
        if anthropic {
            result.inputTokens = usage["input_tokens"] as? Int ?? 0
            result.outputTokens = usage["output_tokens"] as? Int ?? 0
            result.cacheReadTokens = usage["cache_read_input_tokens"] as? Int ?? 0
            result.cacheWriteTokens = usage["cache_creation_input_tokens"] as? Int ?? 0
        } else {
            result.inputTokens = usage["prompt_tokens"] as? Int ?? 0
            result.outputTokens = usage["completion_tokens"] as? Int ?? 0
            result.cacheReadTokens =
                (usage["prompt_tokens_details"] as? [String: Any])?["cached_tokens"] as? Int ?? 0
        }
        return result
    }

    /// 从一行 SSE 里取 usage（OpenAI 末帧 / Anthropic message_start、message_delta）。
    static func parseFrame(_ line: String, anthropic: Bool) -> TokenUsage {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("data:") else { return TokenUsage() }
        let payload = t.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard payload != "[DONE]",
              let data = payload.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return TokenUsage() }
        return parse(obj, anthropic: anthropic)
    }

    var displayText: String {
        let cache = cacheReadTokens > 0
            ? " · " + L10n.t("缓存命中 \(cacheReadTokens)", "cache hit \(cacheReadTokens)")
            : ""
        return L10n.t("输入 \(inputTokens) / 输出 \(outputTokens) token\(cache)",
                      "in \(inputTokens) / out \(outputTokens) tokens\(cache)")
    }
}
