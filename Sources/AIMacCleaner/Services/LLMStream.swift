import Foundation

/// # 流式 LLM 调用
///
/// `LLMClient.complete` 是一次阻塞调用：等模型把整段话吐完才返回。带来两个后果：
/// 1. **看不到「深度思考」** —— 推理内容在非流式响应里要么被并进正文、要么直接丢掉；
/// 2. **没有进度感** —— 工具调用一轮接一轮，中间只有「转圈」，用户不知道它在干什么。
///
/// 实测（`agnes-2.5-flash`，OpenAI 兼容端点）：`stream: true` 时逐帧返回
/// `choices[0].delta.reasoning_content` 与 `.content`，两者都是**增量**，
/// 所以上面两件事都能靠流式解决，不需要端点配合开任何特殊开关。
///
/// ## 两种协议的帧形状不同，都要认
///
/// - OpenAI 兼容：`data: {"choices":[{"delta":{"reasoning_content"|"content":…}}]}`，
///   以 `data: [DONE]` 收尾。
/// - Anthropic 兼容：`event: content_block_delta` + `data: {"delta":{"type":
///   "thinking_delta"|"text_delta", …}}`。
///
/// ## 降级
///
/// 端点可能**忽略** `stream`、直接返回一个完整 JSON（非 `text/event-stream`）。
/// 这时按一次性响应解析，事件回调补发一次全量 —— 界面退化成「不流式」，
/// 但**功能不缺**，绝不会因为端点不支持就报错。
enum LLMStream {

    /// 一个流式增量。
    enum Event {
        /// 深度思考增量（`reasoning_content` / `thinking_delta`）。
        case reasoning(String)
        /// 正文增量。
        case text(String)
    }

    struct Result {
        var text: String = ""
        var reasoning: String = ""
        /// 端点是否真的流式返回。false = 退化成一次性（补发了一次全量）。
        var streamed: Bool = false
    }

    enum Failure: LocalizedError {
        case badURL
        case http(Int, String)
        case server(String)

        var errorDescription: String? {
            switch self {
            case .badURL:  return L10n.t("模型地址不合法", "The model endpoint URL is invalid")
            case .http(let code, _):
                return L10n.t("模型返回错误（HTTP \(code)）", "The model returned an error (HTTP \(code))")
            case .server(let m): return m
            }
        }
    }

    /// 发起一次流式调用，逐帧回调。
    ///
    /// - Parameter onEvent: 在调用方给的执行上下文上被同步调用。Agent 运行时
    ///   用它把增量转发到主 actor 刷新界面，因此必须保证非空且极轻。
    static func run(config: AIModelConfig,
                    messages: [(role: String, content: String)],
                    system: String,
                    onEvent: @Sendable (Event) async -> Void) async throws -> Result {
        guard !config.apiKey.isEmpty else { throw LLMError.missingKey }

        let request: URLRequest
        let anthropic = config.provider.isAnthropicProtocol
        if anthropic {
            request = try anthropicRequest(config: config, messages: messages, system: system)
        } else {
            request = try openAIRequest(config: config, messages: messages, system: system)
        }

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        guard (200..<300).contains(status) else {
            var raw = ""
            for try await line in bytes.lines {
                raw += line
                if raw.count > 400 { break }
            }
            throw Failure.http(status, raw)
        }

        var result = Result()
        let contentType = (response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""

        // 端点可能忽略 stream（真·一次性 JSON），也可能只是把 SSE 标成了 text/plain
        // （很多网关的 Content-Type 不带 event-stream）。两条都要给出内容、不能丢。
        // 策略：先按 SSE 逐帧试拆一遍；只要拆出任何帧就当流式处理（哪怕端点没标对），
        // 否则才是真·一次性，退回 parseOneShot。
        if !contentType.contains("event-stream") {
            var body = ""
            var sse = Result()
            for try await line in bytes.lines {
                body += line + "\n"
                let (c, r) = Self.parseStreamFrame(line, anthropic: anthropic)
                if !r.isEmpty { sse.reasoning += r; await onEvent(.reasoning(r)) }
                if !c.isEmpty { sse.text += c; await onEvent(.text(c)) }
            }
            if !sse.text.isEmpty || !sse.reasoning.isEmpty { return sse }   // 其实是 SSE，只是标错了

            let (text, reasoning) = Self.parseOneShot(body, anthropic: anthropic)
            guard !text.isEmpty || !reasoning.isEmpty else { return result }
            if !reasoning.isEmpty { await onEvent(.reasoning(reasoning)) }
            if !text.isEmpty { await onEvent(.text(text)) }
            result.text = text
            result.reasoning = reasoning
            return result
        }

        result.streamed = true
        for try await line in bytes.lines {
            let (c, r) = Self.parseStreamFrame(line, anthropic: anthropic)
            if !r.isEmpty { result.reasoning += r; await onEvent(.reasoning(r)) }
            if !c.isEmpty { result.text += c; await onEvent(.text(c)) }
        }
        // 一帧都没拿到 = 协议形状不认识（如网关改了格式）。明确报错，
        // 不要静默返回空字符串让界面显示「AI 什么都没说」。
        if result.text.isEmpty && result.reasoning.isEmpty {
            throw Failure.server(L10n.t(
                "模型返回了流式响应，但没有任何可识别的内容帧（可能该端点用了别的流式格式）。",
                "The model streamed a response but no recognizable content frames came through (this endpoint may use a different streaming format)."))
        }
        return result
    }

    /// 解析单条 `data: {…}` 帧，返回它携带的增量（正文 / 思考）。
    ///
    /// **两个协议都支持**（这是「都要支持流式输出」的落点）：
    /// - OpenAI 兼容：`choices[0].delta.{content, reasoning_content|reasoning}`；
    /// - Anthropic 兼容：`delta.{type: thinking_delta|text_delta}`。
    ///
    /// 非 `data:` 行（event:/id:/空行）、`data: [DONE]`、以及任何解析不出的帧都返回
    /// `("", "")` —— 调用方据此忽略它，而不是当成空内容。抽成纯函数是为了能在单测里
    /// 喂两协议的样本帧，锁死「两边都真的在流式」。
    static func parseStreamFrame(_ line: String, anthropic: Bool) -> (text: String, reasoning: String) {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("data:") else { return ("", "") }
        let payload = t.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" { return ("", "") }
        guard let data = payload.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return ("", "") }

        if anthropic {
            guard let delta = obj["delta"] as? [String: Any],
                  let type = delta["type"] as? String else { return ("", "") }
            if type == "thinking_delta" { return ("", delta["thinking"] as? String ?? "") }
            if type == "text_delta" { return (delta["text"] as? String ?? "", "") }
            return ("", "")
        }
        guard let choices = obj["choices"] as? [[String: Any]],
              let delta = choices.first?["delta"] as? [String: Any] else { return ("", "") }
        let r = (delta["reasoning_content"] as? String) ?? (delta["reasoning"] as? String) ?? ""
        let c = delta["content"] as? String ?? ""
        return (c, r)
    }

    // MARK: - 请求构造

    private static func openAIRequest(config: AIModelConfig,
                                      messages: [(role: String, content: String)],
                                      system: String) throws -> URLRequest {
        guard let url = URL(string: config.effectiveBaseURL + "/chat/completions") else {
            throw Failure.badURL
        }
        let payload: [String: Any] = [
            "model": config.effectiveModel,
            "stream": true,
            "max_tokens": 2048,
            "temperature": 0.3,
            "messages": ([["role": "system", "content": system]] + messages.map {
                ["role": $0.role, "content": $0.content]
            })
        ]
        return try post(url: url, body: payload, headers: [
            "Content-Type": "application/json",
            "Authorization": "Bearer " + config.apiKey
        ])
    }

    private static func anthropicRequest(config: AIModelConfig,
                                         messages: [(role: String, content: String)],
                                         system: String) throws -> URLRequest {
        // 与 LLMClient.anthropicBaseURL 同源：保留 base path，交给 /v1/messages 收尾。
        guard let url = URL(string: config.effectiveBaseURL + "/v1/messages") else {
            throw Failure.badURL
        }
        let payload: [String: Any] = [
            "model": config.effectiveModel,
            "stream": true,
            "max_tokens": 2048,
            "system": system,
            "messages": messages.map { ["role": $0.role, "content": $0.content] }
        ]
        return try post(url: url, body: payload, headers: [
            "Content-Type": "application/json",
            "x-api-key": config.apiKey,
            "anthropic-version": "2023-06-01"
        ])
    }

    private static func post(url: URL, body: [String: Any], headers: [String: String]) throws -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 120
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return req
    }

    // MARK: - 一次性响应兜底

    /// 端点忽略 `stream` 时的一次性 JSON → (正文, 思考)。
    ///
    /// OpenAI / Anthropic 两套协议都认 —— 这是「流式降级成一次性补发」路径能正常工作的前提，
    /// 否则某个协议的用户点完分析只会看到空气泡。OpenAI 分支额外兼容几种常见变种
    /// （老式 `choice.text`、平铺的 `content`），因为 OpenAI 兼容网关的返回形状并不统一。
    static func parseOneShot(_ body: String, anthropic: Bool) -> (String, String) {
        guard let data = body.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return ("", "") }
        if anthropic {
            var text = ""
            var reasoning = ""
            for block in (obj["content"] as? [[String: Any]]) ?? [] {
                switch block["type"] as? String {
                case "text": text += (block["text"] as? String ?? "")
                case "thinking": reasoning += (block["thinking"] as? String ?? "")
                default: break
                }
            }
            return (text, reasoning)
        }
        let choice = (obj["choices"] as? [[String: Any]])?.first
        let message = choice?["message"] as? [String: Any] ?? [:]
        let text = (message["content"] as? String)
            ?? (choice?["text"] as? String)          // 老式 OpenAI 一次性接口
            ?? (obj["content"] as? String)           // 部分兼容网关平铺 content
            ?? ""
        let reasoning = (message["reasoning_content"] as? String)
            ?? (message["reasoning"] as? String)
            ?? (obj["reasoning_content"] as? String)
            ?? (obj["reasoning"] as? String) ?? ""
        return (text, reasoning)
    }
}