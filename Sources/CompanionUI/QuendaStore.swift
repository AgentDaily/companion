import Foundation
import SwiftUI
import CompanionCore

/// Identity for the phone's connection task. The device link can survive in the
/// background while 24R records, even though Quenda releases its own connection.
public struct QuendaConnectionContext: Hashable {
    public let revision: Int
    public let applicationRevision: Int
    public let active: Bool
    public init(revision: Int, applicationRevision: Int, active: Bool, foreground: Bool) {
        self.revision = revision; self.applicationRevision = applicationRevision
        self.active = active && foreground
    }
}

@MainActor public final class QuendaStore: ObservableObject {
    @Published public var connected = false
    @Published public var connecting = false
    @Published public var error: String?
    @Published public var sessions: [SessionInfo] = []
    @Published public var agents: [Agent] = []
    @Published public var workspaces: [Workspace] = []
    @Published public var messages: [ChatMessage] = []
    @Published public var streamedText = ""
    @Published public var generating = false
    @Published public var streamConnected = false
    @Published public var permissions: [PendingPermission] = []
    @Published public var interactions: [JSONValue] = []
    @Published public var activityTitles: [String] = []
    @Published public var hasEarlier = false
    @Published public var uploadProgress: Double?
    private var before = 0
    private var backend: Backend?
    private var connectFactory: (() throws -> Backend)?
    private var reader: Task<Void, Never>?
    private var retry: Task<Void, Never>?
    private var recoveryID: UUID?
    private var conversationID: String?
    private var generation = 0
    private var connectionGeneration = 0
    private var sequences = Set<Double>()
    public init() {}
    public func connect(factory: @escaping () throws -> Backend) async {
        retry?.cancel(); retry = nil; recoveryID = nil
        connectFactory = factory
        let attempt = connectionGeneration + 1
        await establish(factory: factory)
        guard attempt == connectionGeneration, !Task.isCancelled else { return }
        if !connected || (conversationID != nil && !streamConnected) { scheduleRecovery() }
    }
    private func establish(factory: @escaping () throws -> Backend) async {
        connectionGeneration += 1; generation += 1; let attempt = connectionGeneration
        reader?.cancel(); reader = nil; backend?.close()
        connected = false; streamConnected = false; connecting = true; error = nil
        connectFactory = factory
        do {
            let client = try factory(); backend = client
            try await client.connect()
            guard attempt == connectionGeneration else { client.close(); return }
            connected = true
            try await refresh()
            if let id = conversationID { await openSession(id) }
        } catch {
            guard attempt == connectionGeneration else { return }
            backend?.close(); connected = false; self.error = error.localizedDescription
        }
        if attempt == connectionGeneration { connecting = false }
    }
    public func reconnect() async { if let factory = connectFactory { await connect(factory: factory) } }
    public func disconnect() {
        connectionGeneration += 1; generation += 1
        retry?.cancel(); retry = nil; recoveryID = nil; reader?.cancel(); reader = nil; backend?.close(); backend = nil
        connected = false; connecting = false; streamConnected = false; connectFactory = nil
    }
    public func refresh() async throws {
        guard let backend else { throw CompanionError.disconnected }
        let attempt = connectionGeneration
        let newAgents = try JSONDecoder().decode([Agent].self, from: await backend.request(path: "/api/agents"))
        let newWorkspaces = try JSONDecoder().decode([Workspace].self, from: await backend.request(path: "/api/workspaces"))
        let newSessions = try JSONDecoder().decode([SessionInfo].self, from: await backend.request(path: "/api/sessions?limit=100"))
        guard attempt == connectionGeneration else { return }
        agents = newAgents; workspaces = newWorkspaces; sessions = newSessions
    }
    public func create(agent: String, workspace: String?, provider: String? = nil, model: String? = nil) async throws -> String {
        guard let backend else { throw CompanionError.disconnected }
        var payload: [String: JSONValue] = ["agent_id": .string(agent)]
        if let workspace, !workspace.isEmpty { payload["workspace_id"] = .string(workspace) }
        if let provider, let model { payload["provider"] = .string(provider); payload["model"] = .string(model) }
        let data = try await backend.request(method: "POST", path: "/api/sessions", body: .object(payload))
        let created = try JSONDecoder().decode(SessionInfo.self, from: data)
        sessions.insert(created, at: 0); try? await refresh(); return created.id
    }
    public func createProject(name: String, path: String, description: String) async throws -> Workspace {
        guard let backend else { throw CompanionError.disconnected }
        var payload: [String: JSONValue] = ["name": .string(name), "description": .string(description)]
        if !path.isEmpty { payload["path"] = .string(path) }
        let created = try JSONDecoder().decode(Workspace.self, from: await backend.request(method: "POST", path: "/api/workspaces", body: .object(payload)))
        workspaces.append(created); try? await refresh(); return created
    }
    public func models(agent: String) async throws -> [ModelChoice] {
        guard let backend, RoutePolicy.validSessionID(agent) else { throw CompanionError.disconnected }
        return try JSONDecoder().decode([ModelChoice].self, from: await backend.request(path: "/api/models?agent_id=\(agent)"))
    }
    public func providerSettings(agent: String) async throws -> JSONValue {
        guard let backend, RoutePolicy.validSessionID(agent) else { throw CompanionError.disconnected }
        return try JSONDecoder().decode(JSONValue.self, from: await backend.request(path: "/api/models/settings/\(agent)"))
    }
    public func saveProviderSettings(agent: String, revision: String, patch: JSONValue) async throws -> JSONValue {
        guard let backend, RoutePolicy.validSessionID(agent) else { throw CompanionError.disconnected }
        return try JSONDecoder().decode(JSONValue.self, from: await backend.request(method: "PUT", path: "/api/models/settings/\(agent)", body: .object(["revision": .string(revision), "patch": patch])))
    }
    public func imageData(session: String, attachment: MessageAttachment) async throws -> Data {
        guard let backend, RoutePolicy.validSessionID(session), RoutePolicy.validSessionID(attachment.id), attachment.isImage,
              attachment.size <= FrameCodec.maximumSize / 2 else { throw CompanionError.server("图片过大，无法在会话内预览。") }
        return try await backend.request(path: "/api/sessions/\(session)/attachments/\(attachment.id)")
    }
    public func open(_ id: String) async {
        retry?.cancel(); retry = nil; recoveryID = nil
        await openSession(id)
    }
    private func openSession(_ id: String) async {
        generation += 1; let attempt = generation
        reader?.cancel(); reader = nil
        conversationID = id; streamConnected = false; messages = []; hasEarlier = false; permissions = []; interactions = []; activityTitles = []; streamedText = ""; generating = false; sequences = []
        guard let backend, connected else { return }
        await backend.unwatch()
        guard attempt == generation else { return }
        do {
            try await reload(id, generation: attempt)
            let pending = try await backend.request(path: "/api/sessions/\(id)/interactions?pending_only=true")
            guard attempt == generation else { return }
            interactions = try JSONDecoder().decode([JSONValue].self, from: pending)
            let events = try await backend.watch(id)
            guard attempt == generation else { return }
            streamConnected = true; error = nil
            reader = Task { [weak self] in
                guard let self else { return }
                do {
                    for try await event in events {
                        guard attempt == generation, !Task.isCancelled else { return }
                        try await receive(event, id: id, attempt: attempt)
                    }
                    if attempt == generation, !Task.isCancelled { scheduleRecovery() }
                } catch {
                    if attempt == generation, !Task.isCancelled { self.error = error.localizedDescription; scheduleRecovery() }
                }
            }
        } catch { if attempt == generation { self.error = error.localizedDescription; scheduleRecovery() } }
    }
    public func leave(_ id: String) async {
        guard conversationID == id else { return }
        generation += 1; conversationID = nil; retry?.cancel(); retry = nil; recoveryID = nil; reader?.cancel(); reader = nil
        streamConnected = false; await backend?.unwatch()
    }
    public func loadEarlier() async {
        guard let id = conversationID, let backend, hasEarlier else { return }
        let attempt = generation
        do {
            let data = try await backend.request(path: "/api/sessions/\(id)/message-pages?limit=50&before=\(before)")
            guard attempt == generation else { return }
            let page = try JSONDecoder().decode(MessagePage.self, from: data)
            let existing = Set(messages.map(\.id)); messages.insert(contentsOf: page.items.filter { !existing.contains($0.id) }, at: 0)
            before = page.before; hasEarlier = page.has_more
        } catch { self.error = error.localizedDescription }
    }
    public func send(_ text: String, attachments: [OutgoingAttachment] = []) async throws {
        guard let backend, let id = conversationID, streamConnected, !generating else { throw CompanionError.disconnected }
        try AttachmentLimits.validate(attachments)
        let attempt = generation
        error = nil; generating = true; streamedText = ""; activityTitles = []
        uploadProgress = attachments.isEmpty ? nil : 0
        defer { uploadProgress = nil }
        do {
            try await backend.sendUser(text, attachments: attachments, sessionID: id) { [weak self] in self?.uploadProgress = $0 }
            if conversationID == id, generation == attempt { try await reload(id, generation: attempt) }
        } catch {
            self.error = "发送状态未确认：\(error.localizedDescription) 请恢复连接后检查会话记录。"
            scheduleRecovery(); throw error
        }
    }
    public func stop() async { await command(.object(["type": .string("interrupt")])) }
    public func respond(permission: PendingPermission, allow: Bool) async {
        await command(.object(["type": .string("permission_response"), "request_id": .string(permission.id), "decision": .string(allow ? "allow" : "deny")]))
    }
    public func answer(interaction: JSONValue, answers: [JSONValue]) async {
        await command(.object(["type": .string("interaction_response"), "interaction_id": interaction["id"], "answers": .array(answers)]))
    }
    private func command(_ value: JSONValue) async {
        do { guard let backend, let id = conversationID, streamConnected else { throw CompanionError.disconnected }; try await backend.send(value, sessionID: id) }
        catch { self.error = error.localizedDescription }
    }
    private func reload(_ id: String, generation attempt: Int) async throws {
        guard let backend else { throw CompanionError.disconnected }
        let data = try await backend.request(path: "/api/sessions/\(id)/message-pages?limit=50")
        guard attempt == generation, id == conversationID else { return }
        let page = try JSONDecoder().decode(MessagePage.self, from: data)
        messages = page.items; before = page.before; hasEarlier = page.has_more
    }
    private func receive(_ event: GatewayEvent, id: String, attempt: Int) async throws {
        if event.type == "stream_start" { sequences = [] }
        if case .number(let sequence) = event.metadata?["sequence"], !sequences.insert(sequence).inserted { return }
        switch event.type {
        case "stream_start": generating = true; streamedText = ""; activityTitles = []
        case "stream_chunk": streamedText += event.content.text
        case "stream_activity":
            let title = event.content["title"].text
            if !title.isEmpty { activityTitles.append(title); activityTitles = Array(activityTitles.suffix(10)) }
        case "permission_requested":
            let permission = PendingPermission(id: event.content["id"].text, request: event.content["request"])
            permissions.removeAll { $0.id == permission.id }; permissions.append(permission)
        case "permission_resolved": permissions.removeAll { $0.id == event.content["id"].text }
        case "stream_end", "stream_interrupted", "interaction_requested":
            generating = false; streamedText = ""; permissions = []
            try await reload(id, generation: attempt)
            guard let backend else { throw CompanionError.disconnected }
            let data = try await backend.request(path: "/api/sessions/\(id)/interactions?pending_only=true")
            guard attempt == generation else { return }
            interactions = try JSONDecoder().decode([JSONValue].self, from: data)
            if let message = event.metadata?["error"]?.text, !message.isEmpty { error = message }
        case "error": generating = false; error = event.content.text
        case "transport_error": throw CompanionError.server(event.content.text)
        default: break
        }
    }
    private func scheduleRecovery() {
        streamConnected = false
        guard retry == nil, connectFactory != nil else { return }
        let token = UUID(); recoveryID = token
        retry = Task { [weak self] in
            var delay = 1
            defer { if self?.recoveryID == token { self?.retry = nil; self?.recoveryID = nil } }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                guard let self, let factory = self.connectFactory, self.recoveryID == token else { return }
                await self.establish(factory: factory)
                if self.connected && (self.conversationID == nil || self.streamConnected) { return }
                delay = min(delay * 2, 15)
            }
        }
    }
}

public typealias ClientStore = QuendaStore
