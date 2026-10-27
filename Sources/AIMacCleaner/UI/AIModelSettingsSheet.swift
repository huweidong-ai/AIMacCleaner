import SwiftUI

/// 「问 AI」的模型配置弹窗（多配置档管理器）。
///
/// 左侧是配置档列表（可新增 / 删除 / 设为默认），右侧是选中档的编辑区。
/// 每个档**独立**保存自己的 API Key / Base URL / 模型名，互不串台——
/// 再也不会出现「只配了 OpenAI，一切到 Anthropic 就把 key 带过去」的情况。
///
/// 配置写进 `AppState.modelStore`（持久化到 UserDefaults）。「问 AI」是**纯 AI Agent**，
/// 只要任一档填齐 API Key 与模型名就能驱动；否则发消息时会提示先来这里配置。
struct AIModelSettingsSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var store: ModelConfigStore
    @State private var selectedID: UUID?
    @State private var testing = false
    @State private var status: String = ""
    /// 用户是否已改动配置。关闭时若有未保存改动，先弹二次确认，避免误丢 API Key 等。
    @State private var touched = false
    @State private var showDiscard = false

    init() {
        let s = ModelConfigStore.current
        _store = State(initialValue: s)
        _selectedID = State(initialValue: s.active?.id ?? s.profiles.first?.id)
    }

    /// 当前正在编辑的档。
    private var editing: AIModelConfig? {
        guard let id = selectedID else { return nil }
        return store.profiles.first(where: { $0.id == id })
    }

    /// 把一个字段绑定到「当前档」上：切档时自动跟随，改值时写回 store。
    private func binding<T>(_ keyPath: WritableKeyPath<AIModelConfig, T>) -> Binding<T> {
        Binding(
            get: { self.editing.map { $0[keyPath: keyPath] } ?? AIModelConfig()[keyPath: keyPath] },
            set: { newValue in
                guard let idx = store.profiles.firstIndex(where: { $0.id == selectedID }) else { return }
                store.profiles[idx][keyPath: keyPath] = newValue
            }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: L10n.t("模型配置", "Model settings"),
                       subtitle: L10n.t("可配置多个模型档，设置其中一个为默认；对话框里还能随时下拉切换。「问 AI」是纯 AI Agent，不配置则发消息时会提示先来这里填好模型。",
                                        "Configure multiple model profiles and mark one as default; you can also switch on the fly in the chat. Ask AI is a pure AI agent — unconfigured, it'll ask you to set up a model before sending.")) {
                Button(L10n.t("取消", "Cancel")) { attemptDismiss() }
                    .controlSize(.small)
                    .keyboardShortcut(.cancelAction)
            }

            Divider()

            HStack(spacing: 0) {
                // ── 左：配置档列表 ──
                VStack(spacing: 0) {
                    HStack {
                        Text(L10n.t("模型配置档", "Model profiles"))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button { addProfile() } label: {
                            Image(systemName: "plus")
                        }
                        .controlSize(.small)
                        .help(L10n.t("新增一个模型档", "Add a model profile"))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)

                    Divider()

                    List(selection: $selectedID) {
                        ForEach(store.profiles) { p in
                            HStack(spacing: 6) {
                                if store.defaultID == p.id {
                                    Image(systemName: "star.fill")
                                        .foregroundStyle(Theme.accent)
                                        .font(.system(size: 9))
                                }
                                Text(ModelConfigStore.displayName(p))
                                    .font(.system(size: 12))
                                    .lineLimit(1)
                                // 历史清单里直接显示已选协议（静态标签），不再给二选一。
                                Text(p.provider.shortLabel)
                                    .font(.system(size: 9))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Theme.accent.opacity(0.1))
                                    .foregroundStyle(Theme.accent)
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                                Spacer(minLength: 4)
                                if store.profiles.count > 1 {
                                    Button {
                                        withAnimation { deleteProfile(p.id) }
                                    } label: {
                                        Image(systemName: "trash")
                                            .foregroundStyle(.secondary)
                                            .font(.system(size: 11))
                                    }
                                    .buttonStyle(.plain)
                                    .controlSize(.small)
                                    .help(L10n.t("删除这个模型档", "Delete this profile"))
                                }
                            }
                            .padding(.horizontal, 8)
                            .tag(p.id)
                        }
                    }
                    .listStyle(.inset)
                }
                .frame(width: 210)

                Divider()

                // ── 右：编辑器 ──
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if let p = editing {
                            section(title: L10n.t("显示名（可选）", "Display name (optional)")) {
                                TextField(L10n.t("例如：我的 GPT / 公司 Claude", "e.g. My GPT / Work Claude"),
                                          text: binding(\.name))
                                    .textFieldStyle(.roundedBorder)
                            }

                            section(title: L10n.t("服务商（选常用的自动填好地址与模型）",
                                                  "Provider (common presets fill URL & model)")) {
                                Picker("", selection: presetBinding) {
                                    ForEach(AIModelConfig.Preset.allCases) { preset in
                                        Text(preset.displayName).tag(preset)
                                    }
                                }
                                .pickerStyle(.menu)
                                .labelsHidden()
                                .frame(maxWidth: 280, alignment: .leading)
                                if let preset = AIModelConfig.Preset.matching(editing), preset == .ollama {
                                    Text(L10n.t("Ollama 需先在终端 ollama pull 拉取模型再填模型名。",
                                                "Run `ollama pull` in Terminal first, then fill the model name."))
                                        .font(.system(size: 10.5))
                                        .foregroundStyle(.tertiary)
                                }
                            }

                            section(title: L10n.t("API Key", "API Key")) {
                                SecureField(L10n.t("粘贴你的密钥", "Paste your key"),
                                            text: binding(\.apiKey))
                                    .textFieldStyle(.roundedBorder)
                            }

                            section(title: L10n.t("Base URL", "Base URL")) {
                                TextField(p.provider.defaultBaseURL, text: binding(\.baseURL))
                                    .textFieldStyle(.roundedBorder)
                            }

                            section(title: L10n.t("模型", "Model")) {
                                TextField(p.provider.defaultModel, text: binding(\.model))
                                    .textFieldStyle(.roundedBorder)
                            }

                            HStack(spacing: 10) {
                                Button {
                                    Task { await testConnection() }
                                } label: {
                                    Label(L10n.t("测试连接", "Test connection"),
                                          systemImage: "cable.connector")
                                }
                                .controlSize(.small)
                                .disabled(testing || binding(\.apiKey).wrappedValue.isEmpty)

                                if !status.isEmpty {
                                    Text(status)
                                        .font(.system(size: 11))
                                        .foregroundStyle(status.hasPrefix("✗") ? .red : .green)
                                }
                                Spacer(minLength: 8)

                                if store.defaultID != p.id {
                                    Button(L10n.t("设为默认", "Set as default")) {
                                        setDefault(p.id)
                                    }
                                    .controlSize(.small)
                                }
                            }
                        } else {
                            Text(L10n.t("还没有配置档，点左上角 + 新增一个。",
                                        "No profile yet — tap + to add one."))
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.top, 40)
                        }
                    }
                    .padding(20)
                }
                .background(Theme.bgCanvas)
            }

            Divider()
            HStack {
                Text(L10n.t("密钥仅保存在本机 UserDefaults，不会上传。",
                            "The key is stored only in this Mac’s UserDefaults and never uploaded."))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Spacer()
                Button(L10n.t("保存", "Save")) { save(); dismiss() }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(Theme.bgSurface)
        }
        .frame(width: 640, height: 580)
        .onChange(of: store) { _, _ in touched = true }
        .interactiveDismissDisabled(true)
        .alert(L10n.t("放弃未保存的模型配置？", "Discard model settings?"), isPresented: $showDiscard) {
            Button(L10n.t("继续编辑", "Keep editing"), role: .cancel) {}
            Button(L10n.t("放弃", "Discard"), role: .destructive) { dismiss() }
        } message: {
            Text(L10n.t("你修改的模型配置尚未保存，关闭后将丢失。", "Your changes will be lost if you close without saving."))
        }
    }

    // MARK: - 布局小件

    private func section<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    // MARK: - 档操作

    private func addProfile() {
        let p = AIModelConfig(name: "",
                              provider: .customOpenAI,
                              baseURL: AIModelConfig.Provider.customOpenAI.defaultBaseURL,
                              model: AIModelConfig.Provider.customOpenAI.defaultModel)
        store.profiles.append(p)
        selectedID = p.id
    }

    private func deleteProfile(_ id: UUID) {
        store.profiles.removeAll { $0.id == id }
        if store.defaultID == id { store.defaultID = store.profiles.first?.id }
        if store.activeID == id { store.activeID = store.defaultID ?? store.profiles.first?.id }
        if selectedID == id { selectedID = store.profiles.first?.id }
    }

    /// 设为默认：同时把「当前活动档」也指向它，让默认立即生效（对话框下拉会跟着跳）。
    private func setDefault(_ id: UUID) {
        store.defaultID = id
        store.activeID = id
    }

    /// 「服务商」下拉的绑定。
    ///
    /// 读：按当前档的协议 + Base URL 反查预设，命不中（自定义地址）落到「自定义」项。
    /// 写：把预设的 Base URL / 默认模型写进**当前档**，API Key 不动 ——
    /// 换厂商时 key 本来就要换，但已经填了 OpenAI 的 key 再切 DeepSeek，
    /// 也不能把 key 清掉，用户可能只是想对比。
    private var presetBinding: Binding<AIModelConfig.Preset> {
        Binding(
            get: {
                // 反查命不中（用户手改过 Base URL）时，按协议落到对应「自定义」项。
                if let p = self.editing {
                    return AIModelConfig.Preset.matching(p)
                        ?? (p.provider == .customAnthropic ? .customAnthropic : .customOpenAI)
                }
                return .customOpenAI
            },
            set: { preset in
                guard let idx = store.profiles.firstIndex(where: { $0.id == selectedID }) else { return }
                store.profiles[idx].provider = preset.provider
                store.profiles[idx].baseURL = preset.baseURL
                store.profiles[idx].model = preset.model
            }
        )
    }

    // MARK: - 行为

    private func save() {
        state.modelStore = store
    }

    /// 关闭前若配置已改动，先弹二次确认，避免误丢 API Key 等尚未保存的修改。
    private func attemptDismiss() {
        if touched {
            showDiscard = true
        } else {
            dismiss()
        }
    }

    private func testConnection() async {
        guard let cfg = editing else { return }
        testing = true
        status = L10n.t("正在测试…", "Testing…")
        do {
            _ = try await LLMClient.complete(config: cfg,
                                             messages: [("user", "ping")],
                                             system: L10n.t("只回复 OK。", "Reply with OK only."))
            state.resetAISuppression()
            status = L10n.t("✓ 连接成功", "✓ Connected")
        } catch {
            let msg = (error as? LLMError)?.errorDescription ?? error.localizedDescription
            status = L10n.t("✗ \(msg)", "✗ \(msg)")
        }
        testing = false
    }
}
