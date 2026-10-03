import Foundation

/// Quenda's host adapter. No discovery, pairing or transport selection lives here.
@MainActor public final class QuendaApplicationSession: CompanionApplicationSession {
    private let gateway: GatewayClient
    private let emit: @MainActor (RelayPacket) async throws -> Void
    private var eventReader: Task<Void, Never>?
    private var socket: GatewayChannel?
    private var sessionID: String?
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
        case "command":
            guard let socket, sessionID != nil, packet.sessionID == sessionID, let body = packet.body else { throw CompanionError.disconnected }
            let value = try JSONDecoder().decode(JSONValue.self, from: body)
            guard ["user_message", "interrupt", "permission_response", "interaction_response", "pong"].contains(value["type"].text) else { throw CompanionError.server("未知会话操作。") }
            try await socket.send(value)
        case "unwatch": unwatch()
        default: throw CompanionError.server("未知 Quenda 操作。")
        }
        return reply
    }
    private func unwatch() { sessionID = nil; eventReader?.cancel(); eventReader = nil; socket?.close(); socket = nil }
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
