import Foundation
import OpenAI
import SwiftAnthropic

/// LLM 调用相关的错误，带本地化说明，直接 show 给用户。
enum LLMError: LocalizedError {
    case missingKey
    case badURL
    case http(status: Int, body: String)
    case noContent
    case underlying(Error)
    /// 网关把请求转给了另一个上游模型，而那次上游调用失败了。
    ///
    /// 真机遇到：`agnes-2.5-flash` 的网关会按负载均衡转发到别家上游
    /// （响应里 `model` 字段会变成 `ZhipuAI/GLM-5.2` 之类），那次调用失败后
    /// 网关返回 **HTTP 200 + 空信封**：`{"choices":null,"usage":{0,0,0}}`。
    /// SDK 会把它报成 `DecodingError.valueNotFound`，用户若只看到「检查 API Key」
    /// 就会去查一个根本没问题的 Key。单独给它一个case，就是为了把话说准。
    case upstreamFailed(String)
    /// 账户余额 / 额度不足（HTTP 429 `insufficient balance`）。
    ///
    /// 单独识别它的理由：**重试毫无意义**（钱不够不会因为再试一次而够），
    /// 而网关还会把同一个错误吞成 `HTTP 200 + choices:null` 的空信封，
    /// 表现出来是「数据缺失 / Key 错误」这种完全误导的说法。
    /// 真机上因此把额度问题误判成 Key 失效、反复重试白等。
    case insufficientBalance

    /// 这个错误重试有没有意义。
    ///
    /// 余额不足 / Key 无效 / 地址非法：没有。用户唯一该做的是充值或改配置，
    /// 让程序替他重试只是把一句准话拖成十几秒的等待 —— 真机上正是「反复重试
    /// 余额不足」把用户逼成了一句「这 app 是不是坏了」。
    var isPermanent: Bool {
        switch self {
        case .insufficientBalance, .missingKey, .badURL:
            return true
        case .http(let status, _):
            return status == 401 || status == 402 || status == 403
        case .upstreamFailed:
            // 上游抽风是瞬时的，值得再试（网关下一跳可能就换到好的上游了）。
            return false
        case .noContent, .underlying:
            return false
        }
    }

    var errorDescription: String? {
        switch self {
        case .missingKey:
            return L10n.t("缺少 API Key", "API key is missing")
        case .badURL:
            return L10n.t("模型地址不合法", "The model endpoint URL is invalid")
        case .http(let status, _):
            return L10n.t("模型返回错误（HTTP \(status)）", "The model returned an error (HTTP \(status))")
        case .noContent:
            return L10n.t("模型没有返回内容", "The model returned no content")
        case .upstreamFailed(let m):
            return L10n.t("模型网关把请求转给了另一个上游（\(m)）而那次调用失败了",
                          "The model gateway routed the request to another upstream (\(m)) and that call failed")
        case .insufficientBalance:
            return L10n.t("API Key 余额 / 额度不足，请充值后重试",
                          "The API key has insufficient balance — top it up and try again")
        case .underlying(let e):
            return e.localizedDescription
        }
    }
}

/// 极简 LLM 客户端：只做一件事——把 `AIModelConfig` + 对话历史发给真实模型，返回纯文本。
///
/// 协议兼容交给成熟的开源 SDK，不再手写 JSON / 请求头 / 响应解析：
/// - **OpenAI 兼容**（`customOpenAI`）：[MacPaw/OpenAI](https://github.com/MacPaw/OpenAI)
///   —— `POST {base}/chat/completions`，`Authorization: Bearer <key>`。
/// - **Anthropic 兼容**（`customAnthropic`）：[SwiftAnthropic](https://github.com/jamesrochabrun/SwiftAnthropic)
///   —— `POST {base}/v1/messages`，`x-api-key` + `anthropic-version` 头，`system` 走顶级字段。
///
/// 对外签名（`complete(config:messages:system:)`）保持不变，所以 Agent 运行时与 CLI 入口
/// 一行都不用改——只是底层协议处理从手写 JSON 换成了上述 SDK。
struct LLMClient {

    /// 调一次模型。
    /// - Parameters:
    ///   - messages: 对话历史，role 只取 `"user"` / `"assistant"`，不含 system（system 单独传）。
    ///   - system: 系统提示词。
    static func complete(config: AIModelConfig,
                          messages: [(role: String, content: String)],
                          system: String) async throws -> String {
        guard !config.apiKey.isEmpty else { throw LLMError.missingKey }

        if config.provider.isAnthropicProtocol {
            return try await completeAnthropic(config: config, messages: messages, system: system)
        } else {
            return try await completeOpenAI(config: config, messages: messages, system: system)
        }
    }

    // MARK: - 兜底：不用 SDK 的裸请求

    /// SDK 解码失败时的兜底：自己发一次裸请求，**宽松**地取正文。
    ///
    /// 为什么必须有这条：真机遇到过「工具都跑完了，最后一轮汇总崩掉」——
    /// `choices` 结构稍有出入（字段缺失、被 `max_tokens` 截断、网关多塞了字段），
    /// MacPaw/OpenAI 那种严格解码的 SDK 会直接抛
    /// `The data couldn't be read because it is missing`，整轮辛苦的调查结果全废，
    /// 用户只看到一句「模型调用失败」。
    ///
    /// 这里刻意**不**做任何严格校验：只要能抠出 `choices[0].message.content`
    /// 就返回。拿不到才把原始错误抛回去。
    static func lenientComplete(config: AIModelConfig,
                                messages: [(role: String, content: String)],
                                system: String) async throws -> String {
        guard let url = URL(string: config.effectiveBaseURL + "/chat/completions") else {
            throw LLMError.badURL
        }
        let body: [String: Any] = [
            "model": config.effectiveModel,
            // 比 SDK 那条给得更宽：agent 最后一轮常要复述整份清单，
            // 2048 会把它截断成非法 JSON —— 那正是上面那个 bug 的触发条件。
            "max_tokens": 4096,
            "temperature": 0.3,
            "messages": ([["role": "system", "content": system]] + messages.map {
                ["role": $0.role, "content": $0.content]
            })
        ]
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 120
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer " + config.apiKey, forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        guard (200..<300).contains(status) else {
            let raw = String(data: data, encoding: .utf8) ?? ""
            // 429 有两种含义，差别极大：真限流（该等）vs 余额不足（等也没用）。
            // 不分开就会把「充值」这件事伪装成「多试几次」。
            if status == 429 {
                let low = raw.lowercased()
                if low.contains("insufficient balance") || low.contains("insufficient_quota")
                    || low.contains("余额不足") || low.contains("额度不足") {
                    throw LLMError.insufficientBalance
                }
            }
            throw LLMError.http(status: status, body: raw)
        }
        let text = String(data: data, encoding: .utf8) ?? ""
        // 网关「转给别的上游且那次失败」的特征：HTTP 200，但 id 为空、choices 为 null。
        // 必须先认出来，否则会被当成「模型没返回内容」，把用户引去查 API Key。
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           (obj["choices"] as? [[String: Any]]) == nil,
           let id = obj["id"] as? String, id.isEmpty {
            let upstream = (obj["model"] as? String) ?? "?"
            throw LLMError.upstreamFailed(upstream)
        }
        let (content, _) = LLMStream.parseOneShot(text, anthropic: false)
        if content.isEmpty, ProcessInfo.processInfo.environment["AIMAG_DEBUG"] != nil {
            // 见过「HTTP 200 但 choices 是 null」——网关把错误当正常响应返回，
            // SDK 会报成 keyNotFound / valueNotFound，localizedDescription 完全看不出
            // 是「服务端拒绝了」还是「响应格式变了」。原始体是唯一能分辨的东西。
            FileHandle.standardError.write(Data("AIMAG: raw response (\(data.count) bytes) — \(text.prefix(600))\n".utf8))
        }
        guard !content.isEmpty else { throw LLMError.noContent }
        return content
    }

    /// 包一层：**SDK 失败自动退到裸请求，再整体重试一次**。全失败才抛错。
    ///
    /// 为什么必须有重试：真机观察到 `agnes-2.5-flash` 网关会**偶发**返回
    /// 「HTTP 200 + `choices: null`」的错误载荷 —— SDK 把它报成
    /// `DecodingError.valueNotFound`，localizedDescription 是毫无线索的
    /// 「The data couldn't be read because it is missing」，而同一时刻同样的请求
    /// 又完全正常。不重试的话，用户看到的就是「偶发地，工具都跑完了却告诉我模型挂了」。
    ///
    /// 重试 3 次、退避递增（1.2s → 2.6s）：端点在连续调用下会短暂限流，
/// 递增退避比固定间隔更有效，又不至于让界面卡住十几秒。
///
/// **永久性失败不重试**：余额不足、Key 无效、地址非法——重试只是让用户多等几秒。
/// 分不清这两类的代价很实在：曾把「充值」伪装成「多试几次」。
/// 重试仍失败就如实报错——**绝不假装成功**。
    static func completeResilient(config: AIModelConfig,
                                  messages: [(role: String, content: String)],
                                  system: String) async throws -> String {
        let backoffs: [UInt64] = [1_200_000_000, 2_600_000_000]
        var lastError: Error = LLMError.noContent
        for attempt in 1...backoffs.count {
            do {
                return try await complete(config: config, messages: messages, system: system)
            } catch {
                lastError = error
                // 每一轮失败都先走一次宽松解析（能救截断 / 字段缺失 / choices 为 null）。
                do {
                    let recovered = try await lenientComplete(config: config,
                                                              messages: messages, system: system)
                    if !recovered.isEmpty { return recovered }
                    throw LLMError.noContent
                } catch let fallbackError {
                    if ProcessInfo.processInfo.environment["AIMAG_DEBUG"] != nil {
                        FileHandle.standardError.write(Data(
                            "AIMAG: attempt \(attempt) failed — SDK: \(String(reflecting: error)) | fallback: \(String(reflecting: fallbackError))\n".utf8))
                    }
                    // 兜底解析报了「永久性」问题就别再试了，直接如实抛给用户。
                    if let le = fallbackError as? LLMError, le.isPermanent {
                        throw le
                    }
                }
                if let le = lastError as? LLMError, le.isPermanent { throw le }
                try? await Task.sleep(nanoseconds: backoffs[attempt - 1])
            }
        }
        throw lastError
    }

    // MARK: - OpenAI 兼容（MacPaw/OpenAI）

    private static func completeOpenAI(config: AIModelConfig,
                                        messages: [(role: String, content: String)],
                                        system: String) async throws -> String {
        let (scheme, host, basePath) = splitBaseURL(config.effectiveBaseURL)
        let openAI = OpenAI(configuration: OpenAI.Configuration(
            token: config.apiKey,
            host: host,
            scheme: scheme,
            basePath: basePath
        ))

        let apiMessages: [ChatQuery.ChatCompletionMessageParam] = [
            .system(.init(content: .textContent(system)))
        ] + messages.map { m in
            if m.role == "assistant" {
                return .assistant(.init(content: .textContent(m.content)))
            }
            return .user(.init(content: .string(m.content)))
        }

        let query = ChatQuery(
            messages: apiMessages,
            model: config.effectiveModel,
            maxCompletionTokens: 2048,
            temperature: 0.3
        )

        do {
            let result: ChatResult = try await openAI.chats(query: query)
            guard let text = result.choices.first?.message.content, !text.isEmpty else {
                throw LLMError.noContent
            }
            return text
        } catch {
            throw LLMError.underlying(error)
        }
    }

    // MARK: - Anthropic 兼容（SwiftAnthropic）

    private static func completeAnthropic(config: AIModelConfig,
                                           messages: [(role: String, content: String)],
                                           system: String) async throws -> String {
        // SwiftAnthropic 会把传入的 base URL 的 path 保留，然后自己补 `/v1/messages`。
        // 例如 `https://ark.cn-beijing.volces.com/api/coding` → `/api/coding/v1/messages`。
        let basePath = anthropicBaseURL(config.effectiveBaseURL)
        let service = AnthropicServiceFactory.service(
            apiKey: config.apiKey,
            apiVersion: "2023-06-01",
            basePath: basePath,
            betaHeaders: nil
        )

        let apiMessages: [MessageParameter.Message] = messages.map { m in
            let role: MessageParameter.Message.Role = (m.role == "assistant") ? .assistant : .user
            return MessageParameter.Message(role: role, content: .text(m.content))
        }

        let parameters = MessageParameter(
            model: .other(config.effectiveModel),
            messages: apiMessages,
            maxTokens: 2048,
            system: .text(system)
        )

        do {
            let response = try await service.createMessage(parameters)
            let text = response.content.compactMap { block -> String? in
                if case .text(let str, _) = block { return str }
                return nil
            }.joined(separator: "\n")
            guard !text.isEmpty else { throw LLMError.noContent }
            return text
        } catch {
            throw LLMError.underlying(error)
        }
    }

    // MARK: - URL 辅助

    /// 把 `https://host/path` 拆成 (scheme, host, path)，给 MacPaw 的 `host` / `basePath` 用。
    private static func splitBaseURL(_ base: String) -> (scheme: String, host: String, basePath: String) {
        guard let u = URL(string: base), let scheme = u.scheme, let host = u.host else {
            return ("https", "api.openai.com", "/v1")
        }
        return (scheme, host, u.path)
    }

    /// SwiftAnthropic 会把传入的 base URL 的 path 保留，然后自己补 `/v1/messages`。
    /// 例如：
    ///   - `https://api.anthropic.com` → `/v1/messages`
    ///   - `https://ark.cn-beijing.volces.com/api/coding` → `/api/coding/v1/messages`
    /// 因此不能 strip 掉 path，否则兼容端点（火山方舟 Coding Plan 等）会 404。
    private static func anthropicBaseURL(_ base: String) -> String {
        guard let u = URL(string: base), let scheme = u.scheme, let host = u.host else {
            return "https://api.anthropic.com"
        }
        var c = URLComponents()
        c.scheme = scheme
        c.host = host
        c.port = u.port
        c.path = u.path
        return c.string ?? "https://api.anthropic.com"
    }
}
