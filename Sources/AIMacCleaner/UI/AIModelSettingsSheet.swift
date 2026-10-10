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
    /// 哪些档当前把「协议」做成二选一（仅新增的档，或手动点了「切换」的档）。
    /// 已有档默认只显示已选协议（静态标签），不再一进来就给二选一。
    @State private var editableProtocolIDs: Set<UUID> = []
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

                            section(title: L10n.t("协议", "Provider")) {
                                if editableProtocolIDs.contains(p.id) {
                                    // 新增档：给二选一，方便一上来就选协议。
                                    HStack(spacing: 10) {
                                        providerButton(.customOpenAI)
                                        providerButton(.customAnthropic)
                                    }
                                } else {
                                    // 已有档（点历史清单进入）：只显示已选协议，不暴露切换入口。
                                    Text(p.provider.shortLabel)
                                        .font(.system(size: 12, weight: .medium))
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 7)
                                        .background(Theme.accent.opacity(0.1))
                                        .foregroundStyle(Theme.accent)
                                        .clipShape(RoundedRectangle(cornerRadius: 6))
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

    /// 带边框的协议卡片：整张卡片可点，选中高亮 + 勾选。
    /// 切到某协议时，**只重置当前档**的 Base URL / 模型为该协议默认值，
    /// 不会动别的档，也不会把别的档的 key 带过来。
    private func providerButton(_ p: AIModelConfig.Provider) -> some View {
        let selected = editing?.provider == p
        return Button {
            selectProvider(p)
        } label: {
            HStack(spacing: 7) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? Theme.accent : .secondary)
                Text(p.displayName)
                    .font(.system(size: 12, weight: selected ? .semibold : .regular))
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
            .padding(.horizontal, 12)
        }
        .buttonStyle(.plain)
        .background(selected ? Theme.accent.opacity(0.12) : Color(nsColor: .controlBackgroundColor))
        .overlay(RoundedRectangle(cornerRadius: 8)
                    .stroke(selected ? Theme.accent : Color.secondary.opacity(0.25), lineWidth: selected ? 1.5 : 1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - 档操作

    private func addProfile() {
        let p = AIModelConfig(name: "",
                              provider: .customOpenAI,
                              baseURL: AIModelConfig.Provider.customOpenAI.defaultBaseURL,
                              model: AIModelConfig.Provider.customOpenAI.defaultModel)
        store.profiles.append(p)
        selectedID = p.id
        // 新增档默认进入「协议二选一」状态，方便一上来就选协议。
        editableProtocolIDs.insert(p.id)
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

    /// 切换当前档的协议，并只重置**该档**的 Base URL / 模型默认值。
    private func selectProvider(_ p: AIModelConfig.Provider) {
        guard let idx = store.profiles.firstIndex(where: { $0.id == selectedID }) else { return }
        store.profiles[idx].provider = p
        store.profiles[idx].baseURL = p.defaultBaseURL
        store.profiles[idx].model = p.defaultModel
        // 新增档保持在「二选一」状态，方便同一次编辑里反复切换；
        // 已有档不在 editableProtocolIDs 里，因此会保持静态标签。
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
