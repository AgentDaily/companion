import SwiftUI
import CompanionCore

public struct ConversationView: View {
    @ObservedObject var store: QuendaStore
    let sessionID: String
    @State private var draft = ""
    @State private var sending = false
    public init(store: QuendaStore, sessionID: String) { self.store = store; self.sessionID = sessionID }
    public var body: some View {
        VStack(spacing: 0) {
            if let error = store.error {
                HStack(alignment: .top) {
                    Image(systemName: "exclamationmark.circle")
                    Text(error).font(.callout).textSelection(.enabled)
                    Spacer()
                    Button("重连") { Task { await store.reconnect() } }.disabled(store.connecting)
                }.padding().background(Color.orange.opacity(0.12))
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        if store.hasEarlier { Button("加载更早消息") { Task { await store.loadEarlier() } }.frame(maxWidth: .infinity) }
                        ForEach(store.messages.filter { $0.role != "tool" }) { message in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(message.role == "user" ? "你" : "Quenda").font(.caption).foregroundStyle(.secondary)
                                Text(message.content).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            }.padding(14).background(message.role == "user" ? Color.accentColor.opacity(0.09) : Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
                        }
                        if store.generating || !store.streamedText.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack { Text("Quenda").font(.caption).foregroundStyle(.secondary); if store.generating { ProgressView().controlSize(.small) } }
                                if !store.streamedText.isEmpty { Text(store.streamedText).textSelection(.enabled) }
                                ForEach(Array(store.activityTitles.enumerated()), id: \.offset) { _, title in Label(title, systemImage: "gearshape").font(.caption).foregroundStyle(.secondary) }
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(14)
                        }
                        ForEach(store.permissions) { permission in
                            VStack(alignment: .leading, spacing: 10) {
                                Label("需要你的许可", systemImage: "hand.raised").font(.headline)
                                Text(permission.summary.isEmpty ? "Agent 请求执行工具操作。" : permission.summary)
                                Text(String(decoding: (try? JSONEncoder().encode(permission.request)) ?? Data(), as: UTF8.self)).font(.caption.monospaced()).textSelection(.enabled)
                                HStack {
                                    Button("拒绝") { Task { await store.respond(permission: permission, allow: false) } }
                                    Button("允许本次") { Task { await store.respond(permission: permission, allow: true) } }.buttonStyle(.borderedProminent)
                                }.disabled(!store.streamConnected)
                            }.padding().background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
                        }
                        ForEach(store.interactions, id: \.self) { interaction in InteractionCard(store: store, interaction: interaction) }
                        Color.clear.frame(height: 1).id("latest")
                    }.padding().frame(maxWidth: 850)
                }
                .onChange(of: store.messages.count) { _, _ in withAnimation { proxy.scrollTo("latest", anchor: .bottom) } }
                .onChange(of: store.streamedText) { _, _ in proxy.scrollTo("latest", anchor: .bottom) }
            }
            Divider()
            HStack(alignment: .bottom, spacing: 12) {
                TextField("发送消息…", text: $draft, axis: .vertical).lineLimit(1...6).textFieldStyle(.roundedBorder)
                if store.generating {
                    Button { Task { await store.stop() } } label: { Image(systemName: "stop.fill") }.accessibilityLabel("停止回答").disabled(!store.streamConnected)
                } else {
                    Button { send() } label: { Image(systemName: "arrow.up") }.buttonStyle(.borderedProminent)
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !store.streamConnected || sending)
                        .accessibilityLabel("发送消息")
                }
            }.padding()
            if !store.streamConnected { Text(store.connecting ? "正在恢复连接…" : "会话连接已断开，正在重试…").font(.caption).foregroundStyle(.secondary).padding(.bottom, 8) }
        }
        .navigationTitle(store.sessions.first { $0.id == sessionID }?.displayTitle ?? "会话")
        .task(id: sessionID) { await store.open(sessionID) }
        .onDisappear { Task { await store.leave(sessionID) } }
    }
    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines); guard !text.isEmpty else { return }
        sending = true
        Task {
            do { try await store.send(text); if draft.trimmingCharacters(in: .whitespacesAndNewlines) == text { draft = "" } }
            catch { }
            sending = false
        }
    }
}

private struct InteractionCard: View {
    @ObservedObject var store: QuendaStore
    let interaction: JSONValue
    @State private var values: [String: String] = [:]
    @State private var selections: [String: Set<String>] = [:]
    @State private var submitting = false
    private var questions: [JSONValue] { interaction["questions"].array.isEmpty ? [interaction] : interaction["questions"].array }
    private func questionID(_ q: JSONValue) -> String { q["id"].text.isEmpty ? interaction["id"].text : q["id"].text }
    private var canSubmit: Bool {
        questions.allSatisfy { q in
            let id = questionID(q)
            let selected = selections[id] ?? []
            let hasText = !(values[id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if selected.contains("__other__") && !hasText { return false }
            return q["required"] == .bool(false) || !selected.isEmpty || hasText
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(interaction["title"].text.isEmpty ? "需要你的回复" : interaction["title"].text, systemImage: "questionmark.bubble").font(.headline)
            ForEach(Array(questions.enumerated()), id: \.offset) { _, q in
                let id = questionID(q)
                if questions.count > 1, !q["title"].text.isEmpty { Text(q["title"].text).font(.subheadline.bold()) }
                if !q["message"].text.isEmpty { Text(q["message"].text) }
                ForEach(q["options"].array, id: \.self) { option in
                    let optionID = option["id"].text
                    Button {
                        var chosen = selections[id] ?? []
                        if chosen.contains(optionID) { chosen.remove(optionID) }
                        else if q["multiple"].flag { chosen.insert(optionID) }
                        else { chosen = [optionID] }
                        selections[id] = chosen
                    } label: {
                        Label(option["label"].text, systemImage: (selections[id] ?? []).contains(optionID) ? "checkmark.circle.fill" : "circle")
                    }.buttonStyle(.bordered)
                }
                TextField("输入回复", text: Binding(get: { values[id] ?? "" }, set: { values[id] = $0 }), axis: .vertical).textFieldStyle(.roundedBorder)
            }
            Button("提交回复") {
                submitting = true
                Task {
                    let answers = questions.map { q -> JSONValue in
                        let id = questionID(q)
                        return .object(["question_id": .string(id), "selected_option_ids": .array((selections[id] ?? []).sorted().map(JSONValue.string)), "value": .string(values[id] ?? "")])
                    }
                    await store.answer(interaction: interaction, answers: answers); submitting = false
                }
            }.buttonStyle(.borderedProminent).disabled(!canSubmit || submitting || !store.streamConnected)
        }.padding().background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
    }
}

public struct NewSessionView: View {
    @ObservedObject var store: QuendaStore
    let onCreated: (String) -> Void
    let defaultAgent: String
    @Environment(\.dismiss) private var dismiss
    @State private var agent = ""
    @State private var workspace = ""
    @State private var creating = false
    @State private var error: String?
    public init(store: QuendaStore, defaultAgent: String = "quenda-code", onCreated: @escaping (String) -> Void) { self.store = store; self.defaultAgent = defaultAgent; self.onCreated = onCreated }
    public var body: some View {
        NavigationStack {
            Form {
                Picker("Agent", selection: $agent) { ForEach(store.agents) { Text($0.name).tag($0.id) } }
                Picker("项目", selection: $workspace) { Text("无项目").tag(""); ForEach(store.workspaces) { Text($0.name).tag($0.id) } }
                if let error { Text(error).foregroundStyle(.red) }
                Button("创建会话") {
                    creating = true
                    Task {
                        do { let id = try await store.create(agent: agent, workspace: workspace); dismiss(); onCreated(id) }
                        catch { self.error = error.localizedDescription }
                        creating = false
                    }
                }.disabled(agent.isEmpty || creating || !store.connected)
            }.navigationTitle("新会话").toolbar { Button("取消") { dismiss() } }
            .onAppear { agent = store.agents.first { $0.id == defaultAgent }?.id ?? store.agents.first?.id ?? "" }
        }.frame(minWidth: 300, minHeight: 260)
    }
}
