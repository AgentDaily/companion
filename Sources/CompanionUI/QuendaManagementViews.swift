import SwiftUI
import CompanionCore

public struct NewProjectView: View {
    @ObservedObject var store: QuendaStore
    private let onCreated: (Workspace) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var path = ""
    @State private var detail = ""
    @State private var saving = false
    @State private var error: String?
    public init(store: QuendaStore, onCreated: @escaping (Workspace) -> Void = { _ in }) { self.store = store; self.onCreated = onCreated }
    public var body: some View {
        NavigationStack {
            Form {
                Section("项目资料") {
                    TextField("项目名称", text: $name)
                    TextField("用途或描述（可选）", text: $detail, axis: .vertical).lineLimit(2...4)
                }
                Section("Mac 上的文件夹") {
                    TextField("绝对路径（可选）", text: $path).quendaTechnicalInput()
                    Text("留空时由 Gateway 在默认目录下创建同名文件夹。填写路径时，使用 Mac 上的路径；文件不会存放在 iPhone。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let error { Text(error).foregroundStyle(.orange) }
                Button(saving ? "正在创建…" : "创建项目") { create() }
                    .disabled(saving || !store.connected || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.formStyle(.grouped).navigationTitle("新建项目")
            .toolbar { Button("取消") { dismiss() }.disabled(saving) }
        }
        #if os(macOS)
        .frame(width: 500, height: 420)
        #endif
        .interactiveDismissDisabled(saving)
    }
    private func create() {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let folder = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.contains("/"), !title.contains("\\"), title != ".", title != ".." else { error = "项目名称不能包含路径分隔符。"; return }
        guard folder.isEmpty || folder.hasPrefix("/") else { error = "请填写 Mac 上的绝对路径，例如 /Users/你的名字/Projects/demo。"; return }
        saving = true; error = nil
        Task {
            do { let project = try await store.createProject(name: title, path: folder, description: detail); dismiss(); onCreated(project) }
            catch { self.error = error.localizedDescription }
            saving = false
        }
    }
}

public struct ProviderSettingsView: View {
    @ObservedObject var store: QuendaStore
    @State private var agent: String
    @State private var document = JSONValue.null
    @State private var selection = ""
    @State private var providerID = ""
    @State private var providerName = ""
    @State private var baseURL = ""
    @State private var api = "openai-completions"
    @State private var key = ""
    @State private var model = ""
    @State private var vision = false
    @State private var setDefault = true
    @State private var loading = false
    @State private var saving = false
    @State private var error: String?
    @State private var saved = false
    public init(store: QuendaStore, defaultAgent: String) { self.store = store; _agent = State(initialValue: defaultAgent) }
    private var providers: [JSONValue] { document["providers"].array }
    private var selected: JSONValue { providers.first { $0["id"].text == selection } ?? .null }
    public var body: some View {
        Form {
            Section("Agent 的模型配置") {
                Picker("Agent", selection: $agent) { ForEach(store.agents) { Text($0.name).tag($0.id) } }.disabled(saving)
                Text("配置写入 Mac 上该 Agent 的配置文件。不会在手机保存 API Key，也不会改变其他 Agent。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if loading { ProgressView("读取配置…") }
            Section("Provider") {
                Picker("编辑或添加", selection: $selection) {
                    Text("添加新 Provider").tag("")
                    ForEach(providers, id: \.self) { provider in Text(provider["name"].text + (provider["configured"].flag ? " · 已配置" : "")).tag(provider["id"].text) }
                }.onChange(of: selection) { _, _ in populate() }.disabled(saving || loading)
                TextField("Provider ID", text: $providerID, prompt: Text("例如 my-provider")).disabled(!selection.isEmpty).quendaTechnicalInput()
                TextField("显示名称", text: $providerName)
                TextField("Base URL", text: $baseURL).quendaTechnicalInput()
                Picker("协议", selection: $api) {
                    Text("OpenAI 兼容").tag("openai-completions")
                    Text("Anthropic Messages").tag("anthropic-messages")
                    Text("Kimi").tag("my-kimi-completions")
                }
                SecureField("API Key", text: $key, prompt: Text(selection.isEmpty ? "本地服务可留空" : "留空保留现有凭证"))
                    .quendaTechnicalInput()
                if selected["configured"].flag { Label("Mac 已有凭证，密钥不会回传", systemImage: "lock.fill").font(.caption).foregroundStyle(.secondary) }
            }.disabled(loading || saving || document["revision"].text.isEmpty)
            Section("模型") {
                TextField("模型 ID", text: $model).quendaTechnicalInput()
                if !selected["models"].array.isEmpty {
                    Menu("选择已有模型") {
                        ForEach(selected["models"].array, id: \.self) { entry in Button(entry["id"].text) { model = entry["id"].text; vision = entry["vision"].flag } }
                    }
                }
                Toggle("新增模型支持图片输入", isOn: $vision)
                Toggle("设为该 Agent 的默认模型", isOn: $setDefault)
                Text("填写新模型 ID 会加入此 Provider，已有模型与高级参数保留。支持图片需要服务端模型实际具备视觉能力。默认模型用于后续新会话。")
                    .font(.caption).foregroundStyle(.secondary)
            }.disabled(loading || saving || document["revision"].text.isEmpty)
            if let error {
                Section { Text(error).foregroundStyle(.orange); Button("重新读取配置") { Task { await load() } }.disabled(saving || loading) }
            }
            if saved { Label("配置已保存到 Mac", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
            Button(saving ? "正在保存…" : "保存 Provider 配置") { save() }
                .disabled(saving || loading || !store.connected || document["revision"].text.isEmpty || providerID.isEmpty)
        }
        .formStyle(.grouped)
        .navigationTitle("Provider 与模型")
        .task(id: agent) { await load() }
        .onDisappear { key = "" }
        .interactiveDismissDisabled(saving)
    }
    private func populate() {
        let entry = selected
        providerID = entry["id"].text; providerName = entry["name"].text; baseURL = entry["base_url"].text
        api = entry["api"].text.isEmpty ? "openai-completions" : entry["api"].text
        let configured = document["models"]["default"]
        let choice = entry["models"].array.first { $0["id"].text == configured["model"].text } ?? entry["models"].array.first ?? .null
        model = choice["id"].text; vision = choice["vision"].flag; key = ""
    }
    private func load() async {
        loading = true; error = nil; key = ""; document = .null
        let requested = agent
        do {
            let value = try await store.providerSettings(agent: requested)
            guard requested == agent, !Task.isCancelled else { return }
            document = value
            let preferred = value["models"]["default"]["provider"].text
            selection = providers.first { $0["id"].text == preferred }?["id"].text ?? providers.first?["id"].text ?? ""
            populate()
        } catch { if requested == agent && !Task.isCancelled { self.error = error.localizedDescription } }
        if requested == agent { loading = false }
    }
    private func save() {
        let id = providerID.trimmingCharacters(in: .whitespacesAndNewlines)
        let modelID = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard RoutePolicy.validSessionID(id) else { error = "Provider ID 只能包含英文、数字、短横线与下划线。"; return }
        guard let url = URLComponents(string: baseURL), ["https", "http"].contains(url.scheme), url.host != nil, url.user == nil, url.password == nil else { error = "请填写有效的 HTTP(S) Base URL。"; return }
        guard !modelID.isEmpty || !setDefault else { error = "设置默认模型时需要填写模型 ID。"; return }
        var declaration: [String: JSONValue] = ["name": .string(providerName.isEmpty ? id : providerName), "base_url": .string(baseURL), "api": .string(api)]
        if !key.isEmpty { declaration["api_key"] = .string(key) }
        var existing = selected["models"].array
        if !modelID.isEmpty && !existing.contains(where: { $0["id"].text == modelID }) {
            existing.append(.object(["id": .string(modelID), "name": .string(modelID), "vision": .bool(vision), "tool_calling": .bool(true), "streaming": .bool(true)]))
            declaration["models"] = .array(existing)
        }
        var patch: [String: JSONValue] = ["providers": .object([id: .object(declaration)])]
        if setDefault { patch["models"] = .object(["default": .object(["provider": .string(id), "model": .string(modelID)])]) }
        saving = true; error = nil; saved = false
        Task {
            do {
                document = try await store.saveProviderSettings(agent: agent, revision: document["revision"].text, patch: .object(patch))
                key = ""; selection = id; saved = true
            } catch { self.error = error.localizedDescription }
            saving = false
        }
    }
}
