import Foundation

/// 单个模型配置档（一个 profile）。
///
/// 协议分两类（视觉上两列）：
/// - **customOpenAI**：任意 OpenAI 兼容端点（OpenAI 官方、本地代理、第三方中转都行），
///   chat/completions 协议，默认 `https://api.openai.com/v1`，可改。
/// - **customAnthropic**：任意 Anthropic 兼容端点，messages 协议，
///   需要 `x-api-key` + `anthropic-version` 头，`system` 走顶级字段，
///   默认 `https://api.anthropic.com/v1`，可改。
///
/// 每个 profile **独立**保存自己的 apiKey / baseURL / model，互不串台——
/// 「切到 Anthropic 把 OpenAI 的 key 带过去」这种事不会发生，因为它们是
/// 各自独立的存档，而不是一个共享表单。
struct AIModelConfig: Codable, Equatable, Identifiable {
    let id: UUID
    /// 用户自定义的显示名（可空，空则用「协议 · 模型」兜底）。
    var name: String
    var provider: Provider
    var apiKey: String
    var baseURL: String
    var model: String

    init(id: UUID = UUID(),
         name: String = "",
         provider: Provider = .customOpenAI,
         apiKey: String = "",
         baseURL: String = "",
         model: String = "") {
        self.id = id
        self.name = name
        self.provider = provider
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.model = model
    }

    enum Provider: String, Codable, CaseIterable, Identifiable {
        case customOpenAI
        case customAnthropic
        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .customOpenAI:    return L10n.t("自定义（OpenAI 兼容）", "Custom (OpenAI-compatible)")
            case .customAnthropic: return L10n.t("自定义（Anthropic 兼容）", "Custom (Anthropic-compatible)")
            }
        }

        /// 下拉 / 列表里用的短名。
        var shortLabel: String {
            switch self {
            case .customOpenAI:    return "OpenAI"
            case .customAnthropic: return "Anthropic"
            }
        }

        /// 不选 baseURL 时用的默认值。
        var defaultBaseURL: String {
            switch self {
            case .customOpenAI:    return "https://api.openai.com/v1"
            case .customAnthropic: return "https://api.anthropic.com/v1"
            }
        }

        /// 不选 model 时用的默认值。
        var defaultModel: String {
            switch self {
            case .customOpenAI:    return "gpt-4o-mini"
            case .customAnthropic: return "claude-3-5-sonnet-20241022"
            }
        }

        /// 是否走 Anthropic messages 协议（自定义 Anthropic 兼容）。
        var isAnthropicProtocol: Bool {
            self == .customAnthropic
        }

        /// Anthropic 的 system prompt 是请求体里的顶级字段，不是 messages 里的一项。
        var usesTopLevelSystem: Bool { isAnthropicProtocol }

        /// 自定义解码，兼容旧版 `openai` / `anthropic` / `custom`（统一映射到对应兼容类型）。
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            switch raw {
            case Provider.customOpenAI.rawValue:    self = .customOpenAI
            case Provider.customAnthropic.rawValue: self = .customAnthropic
            case "openai":    self = .customOpenAI    // 旧数据迁移
            case "anthropic": self = .customAnthropic // 旧数据迁移
            case "custom":    self = .customOpenAI    // 旧数据迁移
            default:          self = .customOpenAI
            }
        }
    }

    /// 服务商预设：常用大模型厂商的 Base URL + 默认模型名。
    ///
    /// 存在的理由：用户配 DeepSeek / GLM / Kimi 这类厂商时，被迫先去查文档抄
    /// Base URL，还要知道模型名叫什么。预设让用户**只填 Key**，地址与模型自动带出。
    /// 预设不持久化 —— 档里存的仍是 provider + baseURL + model，预设只是填表捷径，
    /// 所以以后厂商改地址/模型名，老配置不受影响。
    enum Preset: String, CaseIterable, Identifiable {
        case openai, anthropic
        case deepseek, zhipu, moonshot, qwen, siliconflow, openrouter, ollama
        case customOpenAI, customAnthropic
        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .openai:          return "OpenAI"
            case .anthropic:       return "Anthropic"
            case .deepseek:        return "DeepSeek 深度求索"
            case .zhipu:           return "智谱 GLM"
            case .moonshot:        return "Moonshot Kimi"
            case .qwen:            return "通义千问 Qwen"
            case .siliconflow:     return "硅基流动 SiliconFlow"
            case .openrouter:      return "OpenRouter"
            case .ollama:          return L10n.t("Ollama（本地）", "Ollama (local)")
            case .customOpenAI:    return L10n.t("自定义（OpenAI 兼容）", "Custom (OpenAI-compatible)")
            case .customAnthropic: return L10n.t("自定义（Anthropic 兼容）", "Custom (Anthropic-compatible)")
            }
        }

        var baseURL: String {
            switch self {
            case .openai:          return "https://api.openai.com/v1"
            case .anthropic:       return "https://api.anthropic.com/v1"
            case .deepseek:        return "https://api.deepseek.com/v1"
            case .zhipu:           return "https://open.bigmodel.cn/api/paas/v4"
            case .moonshot:        return "https://api.moonshot.cn/v1"
            case .qwen:            return "https://dashscope.aliyuncs.com/compatible-mode/v1"
            case .siliconflow:     return "https://api.siliconflow.cn/v1"
            case .openrouter:      return "https://openrouter.ai/api/v1"
            case .ollama:          return "http://localhost:11434/v1"
            case .customOpenAI:    return "https://api.openai.com/v1"
            case .customAnthropic: return "https://api.anthropic.com/v1"
            }
        }

        /// 预设的推荐模型名（仅填表用，用户可改）。对照 2026-10 各家官方文档：
        /// - DeepSeek：deepseek-chat 别名已于 2026-07-24 弃用，改用 v4 系列；
        /// - 智谱旗舰为 GLM-5.3 家族；Kimi 示例用 kimi-k3（旗舰）/ kimi-k2.6（通用档）；
        /// - OpenAI 当前档位为 GPT-6 Astra（旗舰）/ GPT-5.6 Terra（均衡）/ Luna（低价），
        ///   预设取 Terra；Anthropic 当前为 Opus/Sonnet/Haiku 5.5 代，预设取 Sonnet。
        /// 厂商迭代很快，过期了改这里的字符串即可——预设不持久化，老配置不受影响。
        var model: String {
            switch self {
            case .openai:          return "gpt-5.6-terra"
            case .anthropic:       return "claude-sonnet-5-5"
            case .deepseek:        return "deepseek-v4-flash"
            case .zhipu:           return "glm-5.3-flash"
            case .moonshot:        return "kimi-k2.6"
            case .qwen:            return "qwen-plus"
            case .siliconflow:     return "deepseek-ai/DeepSeek-V3"
            case .openrouter:      return "openai/gpt-5.6-terra"
            case .ollama:          return "llama3.1"
            case .customOpenAI:    return "gpt-5.6-terra"
            case .customAnthropic: return "claude-sonnet-5-5"
            }
        }

        var provider: Provider {
            self == .anthropic || self == .customAnthropic ? .customAnthropic : .customOpenAI
        }

        /// 自定义档：只切协议、重置官方默认值，不预设具体厂商。
        var isCustom: Bool { self == .customOpenAI || self == .customAnthropic }

        /// 反查：现有档对应哪个预设（按协议 + Base URL 精确匹配）。
        /// 自定义档放最后，保证先命中具体厂商。
        static func matching(_ cfg: AIModelConfig?) -> Preset? {
            guard let cfg else { return nil }
            return allCases.first {
                $0.provider == cfg.provider && $0.baseURL == cfg.effectiveBaseURL
            }
        }
    }

    // MARK: - 派生

    /// 用户是否真正填齐了调用所需字段。
    var isConfigured: Bool {
        !apiKey.isEmpty && !effectiveModel.isEmpty
    }

    var effectiveBaseURL: String {
        baseURL.trimmingCharacters(in: .whitespaces).isEmpty
            ? provider.defaultBaseURL
            : baseURL.trimmingCharacters(in: .whitespaces)
    }

    var effectiveModel: String {
        model.trimmingCharacters(in: .whitespaces).isEmpty
            ? provider.defaultModel
            : model.trimmingCharacters(in: .whitespaces)
    }

    /// 列表 / 下拉里展示的名字：自定义 name 优先，否则回退到模型名（不再用「OpenAI」兜底）。
    var displayName: String {
        let n = name.trimmingCharacters(in: .whitespaces)
        if !n.isEmpty { return n }
        return effectiveModel
    }
}

/// 多个模型配置档的集合（「问 AI」的模型仓库）。
///
/// - `profiles`：用户配置的所有档（可只填了一个，也可多个）。
/// - `defaultID`：在设置页里标为「默认」的档；新开对话、下拉未显式选择时回退到它。
/// - `activeID`：对话框下拉当前选中的档；优先级高于 `defaultID`。
///
/// 持久化在 UserDefaults（key `expunge.aimodels`）。首次启动若发现旧版单配置
/// `expunge.aimodel`，自动迁移成单个 profile，避免老用户配置丢失。
struct ModelConfigStore: Codable, Equatable {
    var profiles: [AIModelConfig]
    var defaultID: UUID?
    var activeID: UUID?

    // MARK: - 派生

    /// 是否存在至少一条「填齐了 key + model」的可用档。
    var isConfigured: Bool {
        profiles.contains { $0.isConfigured }
    }

    /// 当前用于回答的档：activeID → defaultID → 第一条可用 → 第一条。
    var active: AIModelConfig? {
        if let id = activeID, let p = profiles.first(where: { $0.id == id }) { return p }
        if let id = defaultID, let p = profiles.first(where: { $0.id == id }) { return p }
        return profiles.first(where: { $0.isConfigured }) ?? profiles.first
    }

    /// 下拉可选项：只列「已填齐」的档，避免把半截配置丢给模型。
    var selectable: [AIModelConfig] {
        profiles.filter { $0.isConfigured }
    }

    /// 列表 / 下拉统一展示名。
    static func displayName(_ p: AIModelConfig) -> String { p.displayName }

    // MARK: - 持久化

    static let userDefaultsKey = "expunge.aimodels"

    static var current: ModelConfigStore {
        get {
            if let data = UserDefaults.standard.data(forKey: userDefaultsKey),
               let s = try? JSONDecoder().decode(ModelConfigStore.self, from: data) {
                return s
            }
            // 旧版单配置迁移：把 expunge.aimodel 里的那份转成一个 profile。
            if let data = UserDefaults.standard.data(forKey: "expunge.aimodel"),
               let old = try? JSONDecoder().decode(LegacyAIModelConfig.self, from: data) {
                var m = AIModelConfig(provider: old.provider,
                                      apiKey: old.apiKey,
                                      baseURL: old.baseURL,
                                      model: old.model)
                m.name = ""
                return ModelConfigStore(profiles: [m], defaultID: m.id, activeID: m.id)
            }
            return ModelConfigStore(profiles: [], defaultID: nil, activeID: nil)
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: userDefaultsKey)
            }
        }
    }

    /// 旧版单配置的字段布局，仅用于迁移。
    private struct LegacyAIModelConfig: Codable {
        var provider: AIModelConfig.Provider
        var apiKey: String
        var baseURL: String
        var model: String
    }
}
