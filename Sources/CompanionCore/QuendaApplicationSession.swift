import Foundation

/// Quenda's host adapter. No discovery, pairing or transport selection lives here.
@MainActor public final class QuendaApplicationSession: CompanionApplicationSession {
    private let gateway: GatewayClient
    private let emit: @MainActor (RelayPacket) async throws -> Void
    private var eventReader: Task<Void, Never>?
    private var socket: GatewayChannel?
    private var sessionID: String?
    private var attachments = AttachmentBuffer()
    public init(gateway: URL, emit: @escaping @MainActor (RelayPacket) async throws -> Void) {
        self.gateway = GatewayClient(baseURL: gateway); self.emit = emit
    }
    public func close() { unwatch() }
    public func handle(_ packet: RelayPacket) async throws -> RelayPacket {
        var reply = RelayPacket(kind: "response", id: packet.id, status: 200)
        switch packet.kind {
        case "request":
            guard let path = packet.path, let method = packet.method, RoutePolicy.allows(method: method, path: path) else { throw CompanionError.server("此接口未开放给 Quenda 应用。") }
            let result = try await gateway.request(method: method, path: path, body: packet.body)
            reply.status = result.status; reply.body = result.body
        case "watch":
            guard let id = packet.sessionID, RoutePolicy.validSessionID(id) else { throw CompanionError.invalidAddress }
            unwatch(); sessionID = id
            let newSocket = try gateway.channel(sessionID: id); socket = newSocket
            let events = try await newSocket.start()
            eventReader = Task { [weak self] in
                guard let self else { return }
                do {
                    for try await event in events {
                        try Task.checkCancellation()
                        try await emit(RelayPacket(kind: "event", body: JSONEncoder().encode(event), sessionID: id))
                    }
                } catch {
                    if !Task.isCancelled {
                        let event = GatewayEvent(type: "transport_error", content: .string(error.localizedDescription), metadata: nil)
                        try? await emit(RelayPacket(kind: "event", body: JSONEncoder().encode(event), sessionID: id))
                    }
                }
            }
        case "attachment_reset", "attachment_begin", "attachment_chunk":
            guard sessionID != nil, packet.sessionID == sessionID else { throw CompanionError.disconnected }
            if packet.kind == "attachment_reset" { attachments.reset() }
            else if packet.kind == "attachment_begin", let body = packet.body { try attachments.begin(JSONDecoder().decode(JSONValue.self, from: body)) }
            else if packet.kind == "attachment_chunk", let id = packet.path, let body = packet.body { try attachments.append(id: id, data: body) }
            else { throw CompanionError.invalidFrame }
        case "command":
            guard let socket, sessionID != nil, packet.sessionID == sessionID, let body = packet.body else { throw CompanionError.disconnected }
            var value = try JSONDecoder().decode(JSONValue.self, from: body)
            guard ["user_message", "interrupt", "permission_response", "interaction_response", "pong"].contains(value["type"].text) else { throw CompanionError.server("未知会话操作。") }
            if value["type"].text == "user_message", case .object(var command) = value {
                if case .array(let ids) = command["attachment_ids"] {
                    guard ids.allSatisfy({ !$0.text.isEmpty }) else { throw CompanionError.invalidFrame }
                    command["attachments"] = .array(try attachments.payload(ids: ids.map(\.text)))
                    command.removeValue(forKey: "attachment_ids"); value = .object(command)
                }
                defer { attachments.reset() }
                try await socket.send(value)
            } else { try await socket.send(value) }
        case "unwatch": unwatch()
        default: throw CompanionError.server("未知 Quenda 操作。")
        }
        return reply
    }
    private func unwatch() { attachments.reset(); sessionID = nil; eventReader?.cancel(); eventReader = nil; socket?.close(); socket = nil }
}

#if os(macOS)
extension RelayServer {
    public convenience init(gateway: URL, host: String, port: UInt16, key: String, nearbyService: String? = nil) throws {
        let registry = ApplicationRegistry()
        registry.register(.quenda) { QuendaApplicationSession(gateway: gateway, emit: $0) }
        try self.init(registry: registry, host: host, port: port, key: key, nearbyService: nearbyService)
    }
}
#endif
