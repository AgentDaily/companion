import Foundation

/// Quenda's phone adapter on top of the shared device link.
@MainActor public final class QuendaRelayClient {
    private let link: CompanionLink
    private let ownsLink: Bool
    private var eventReader: Task<Void, Never>?
    private var watchedID: String?
    private var eventContinuation: AsyncThrowingStream<GatewayEvent, Error>.Continuation?
    private var closed = false
    public init(pairing: Pairing) throws { link = CompanionLink(pairing: pairing); ownsLink = true }
    public init(link: CompanionLink) { self.link = link; ownsLink = false }
    public func connect() async throws {
        guard !closed else { throw CompanionError.disconnected }
        try await link.connect()
    }
    public func request(method: String, path: String, body: Data?) async throws -> APIReply {
        let reply = try await request(RelayPacket(kind: "request", method: method, path: path, body: body))
        return APIReply(status: reply.status ?? 502, body: reply.body ?? Data())
    }
    public func watch(_ sessionID: String) async throws -> AsyncThrowingStream<GatewayEvent, Error> {
        eventReader?.cancel(); eventContinuation?.finish()
        let pair = AsyncThrowingStream<GatewayEvent, Error>.makeStream(bufferingPolicy: .bufferingOldest(256))
        eventContinuation = pair.continuation; watchedID = sessionID
        let packets = link.events(applicationID: "quenda")
        eventReader = Task {
            do {
                for try await packet in packets {
                    guard !Task.isCancelled else { break }
                    if packet.sessionID == sessionID, let data = packet.body {
                        let event = try JSONDecoder().decode(GatewayEvent.self, from: data)
                        if case .dropped = pair.continuation.yield(event) { throw CompanionError.server("消息积压，请重新连接。") }
                    }
                }
                pair.continuation.finish()
            } catch { pair.continuation.finish(throwing: error) }
        }
        do { _ = try await request(RelayPacket(kind: "watch", sessionID: sessionID)) }
        catch { eventReader?.cancel(); pair.continuation.finish(throwing: error); throw error }
        return pair.stream
    }
    public func send(_ command: JSONValue) async throws {
        _ = try await request(RelayPacket(kind: "command", body: JSONEncoder().encode(command), sessionID: watchedID))
    }
    public func sendUser(_ text: String, attachments: [OutgoingAttachment], progress: (Double) -> Void) async throws {
        try AttachmentLimits.validate(attachments)
        guard let id = watchedID else { throw CompanionError.disconnected }
        if !attachments.isEmpty {
            _ = try await request(RelayPacket(kind: "attachment_reset", sessionID: id))
            let total = attachments.reduce(0) { $0 + $1.data.count }; var transferred = 0
            for attachment in attachments {
                let declaration: JSONValue = .object(["id": .string(attachment.id), "name": .string(attachment.name), "media_type": .string(attachment.mediaType), "size": .number(Double(attachment.data.count))])
                _ = try await request(RelayPacket(kind: "attachment_begin", body: JSONEncoder().encode(declaration), sessionID: id))
                for offset in stride(from: 0, to: attachment.data.count, by: AttachmentLimits.chunkBytes) {
                    try Task.checkCancellation()
                    guard watchedID == id else { throw CompanionError.disconnected }
                    let end = min(offset + AttachmentLimits.chunkBytes, attachment.data.count)
                    _ = try await request(RelayPacket(kind: "attachment_chunk", path: attachment.id, body: attachment.data.subdata(in: offset..<end), sessionID: id))
                    transferred += end - offset; progress(Double(transferred) / Double(total))
                }
            }
        }
        guard watchedID == id else { throw CompanionError.disconnected }
        try await send(.object(["type": .string("user_message"), "content": .string(text), "attachment_ids": .array(attachments.map { .string($0.id) })]))
    }
    public func unwatch() async {
        eventReader?.cancel(); eventReader = nil
        eventContinuation?.finish(); eventContinuation = nil; watchedID = nil
        _ = try? await request(RelayPacket(kind: "unwatch"))
    }
    public func close(_ error: Error = CompanionError.disconnected) {
        guard !closed else { return }; closed = true
        eventReader?.cancel(); eventReader = nil
        eventContinuation?.finish(throwing: error); eventContinuation = nil
        if ownsLink { link.close(error) }
        watchedID = nil
    }
    private func request(_ packet: RelayPacket) async throws -> RelayPacket {
        guard !closed else { throw CompanionError.disconnected }
        var scoped = packet; scoped.applicationID = "quenda"
        return try await link.request(scoped)
    }
}

@MainActor public final class QuendaBackend {
    private let gateway: GatewayClient?
    private let relay: QuendaRelayClient?
    private var socket: GatewayChannel?
    private var watchedID: String?
    public init(gateway: URL) { self.gateway = GatewayClient(baseURL: gateway); relay = nil }
    public init(pairing: Pairing) throws { gateway = nil; relay = try QuendaRelayClient(pairing: pairing) }
    public init(link: CompanionLink) { gateway = nil; relay = QuendaRelayClient(link: link) }
    public func connect() async throws { try await relay?.connect(); _ = try await request(path: "/api/health") }
    public func request(method: String = "GET", path: String, body: JSONValue? = nil) async throws -> Data {
        let data = try body.map { try JSONEncoder().encode($0) }
        let reply: APIReply
        if let gateway { reply = try await gateway.request(method: method, path: path, body: data) }
        else if let relay { reply = try await relay.request(method: method, path: path, body: data) }
        else { throw CompanionError.disconnected }
        guard (200...299).contains(reply.status) else {
            let detail = (try? JSONDecoder().decode(JSONValue.self, from: reply.body))?["detail"].text ?? ""
            throw CompanionError.server(detail.isEmpty ? "Gateway 请求失败（\(reply.status)）。" : detail)
        }
        return reply.body
    }
    public func watch(_ id: String) async throws -> AsyncThrowingStream<GatewayEvent, Error> {
        watchedID = id
        if let relay { return try await relay.watch(id) }
        socket?.close(); socket = try gateway?.channel(sessionID: id)
        guard let socket else { throw CompanionError.disconnected }
        return try await socket.start()
    }
    public func send(_ command: JSONValue, sessionID: String? = nil) async throws {
        guard watchedID != nil, sessionID == nil || sessionID == watchedID else { throw CompanionError.server("会话已切换，请重新发送。") }
        if let relay { try await relay.send(command) }
        else { guard let socket else { throw CompanionError.disconnected }; try await socket.send(command) }
    }
    public func sendUser(_ text: String, attachments: [OutgoingAttachment], sessionID: String, progress: (Double) -> Void) async throws {
        try AttachmentLimits.validate(attachments)
        guard watchedID == sessionID else { throw CompanionError.disconnected }
        if let relay { try await relay.sendUser(text, attachments: attachments, progress: progress) }
        else {
            try await send(.object(["type": .string("user_message"), "content": .string(text), "attachments": .array(attachments.map(\.payload))]), sessionID: sessionID)
            progress(1)
        }
    }
    public func unwatch() async { watchedID = nil; socket?.close(); socket = nil; await relay?.unwatch() }
    public func close() { watchedID = nil; socket?.close(); socket = nil; relay?.close() }
}

public typealias RelayClient = QuendaRelayClient
public typealias Backend = QuendaBackend
