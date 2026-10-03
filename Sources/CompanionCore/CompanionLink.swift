import Foundation
import Network

public enum CompanionTransport: String, Sendable { case nearby, remote }
public enum CompanionConnectionState: Equatable, Sendable {
    case disconnected, discovering, connectingRemote, connected(CompanionTransport)
    public var title: String {
        switch self {
        case .disconnected: return "Mac 未连接"
        case .discovering: return "正在寻找附近的 Mac…"
        case .connectingRemote: return "正在通过 Tailscale 连接…"
        case .connected(.nearby): return "附近连接已建立"
        case .connected(.remote): return "Tailscale 已连接"
        }
    }
}

/// A device connection shared by all applications. Only opening a connection
/// may fall back to another transport; application requests are never replayed.
@MainActor public final class CompanionLink {
    private let pairing: Pairing
    private let resolve: @MainActor (String) async throws -> NWEndpoint
    private var channel: FramedConnection?
    private var discoveryTask: Task<NWEndpoint, Error>?
    private var connectTask: Task<Void, Error>?
    private var reader: Task<Void, Never>?
    private var closed = false
    private struct Pending {
        let applicationID: String?
        let wait: CheckedContinuation<RelayPacket, Error>
    }
    private var pending: [String: Pending] = [:]
    private var subscribers: [UUID: (String, AsyncThrowingStream<RelayPacket, Error>.Continuation)] = [:]
    public private(set) var state = CompanionConnectionState.disconnected
    public var onApplicationsChanged: ((String?) -> Void)?
    public var onState: ((CompanionConnectionState) -> Void)?
    public init(pairing: Pairing, resolve: @escaping @MainActor (String) async throws -> NWEndpoint = { try await NearbyDiscovery.resolve(service: $0) }) {
        self.pairing = pairing; self.resolve = resolve
    }
    public func connect() async throws {
        guard !closed else { throw CompanionError.disconnected }
        if reader != nil { return }
        if let connectTask { return try await connectTask.value }
        let operation = Task { try await self.open() }
        connectTask = operation
        defer { connectTask = nil }
        try await withTaskCancellationHandler(operation: { try await operation.value }, onCancel: {
            operation.cancel()
            Task { @MainActor [weak self] in self?.close(CancellationError()) }
        })
    }
    private func open() async throws {
        try Task.checkCancellation(); guard !closed else { throw CompanionError.disconnected }
        do {
            if let service = pairing.nearbyService {
                do {
                    update(.discovering)
                    let search = Task { try await resolve(service) }; discoveryTask = search
                    let endpoint = try await search.value; discoveryTask = nil
                    try Task.checkCancellation(); guard !closed else { throw CompanionError.disconnected }
                    let nearby = try FramedConnection(endpoint: endpoint, key: pairing.key); channel = nearby
                    try await nearby.start()
                    update(.connected(.nearby))
                } catch {
                    discoveryTask?.cancel(); discoveryTask = nil
                    channel?.close(); channel = nil
                    try Task.checkCancellation(); guard !closed else { throw CompanionError.disconnected }
                    guard pairing.remoteHost != nil else { throw error }
                    try await openRemote()
                }
            } else { try await openRemote() }
            try Task.checkCancellation(); guard !closed, let channel else { throw CompanionError.disconnected }
            reader = Task { [weak self] in
                guard let self else { return }
                do {
                    for try await packet in channel.packets {
                        if packet.kind == "catalog_changed" {
                            self.onApplicationsChanged?(packet.applicationID)
                        } else if packet.kind == "event" {
                            let app = packet.applicationID ?? "quenda" // v1 event compatibility
                            for (_, subscription) in self.subscribers where subscription.0 == app {
                                if case .dropped = subscription.1.yield(packet) { throw CompanionError.server("消息积压，请重新连接。") }
                            }
                        } else if let response = self.pending.removeValue(forKey: packet.id) {
                            guard packet.applicationID == response.applicationID || (packet.applicationID == nil && response.applicationID == "quenda") else {
                                response.wait.resume(throwing: CompanionError.invalidFrame); throw CompanionError.invalidFrame
                            }
                            if let error = packet.error { response.wait.resume(throwing: CompanionError.server(error)) }
                            else { response.wait.resume(returning: packet) }
                        }
                    }
                    self.close()
                } catch { self.close(error) }
            }
        } catch { close(error); throw error }
    }
    private func openRemote() async throws {
        guard pairing.remoteHost != nil else { throw CompanionError.invalidAddress }
        update(.connectingRemote)
        let remote = try FramedConnection(pairing: pairing); channel = remote
        try await remote.start(); update(.connected(.remote))
    }
    public func applications() async throws -> [CompanionApplication] {
        let reply = try await request(RelayPacket(kind: "catalog"))
        guard let body = reply.body else { throw CompanionError.invalidFrame }
        return try JSONDecoder().decode([CompanionApplication].self, from: body)
    }
    public func events(applicationID: String) -> AsyncThrowingStream<RelayPacket, Error> {
        let pair = AsyncThrowingStream<RelayPacket, Error>.makeStream(bufferingPolicy: .bufferingOldest(256))
        guard !closed else { pair.continuation.finish(throwing: CompanionError.disconnected); return pair.stream }
        let id = UUID(); subscribers[id] = (applicationID, pair.continuation)
        pair.continuation.onTermination = { [weak self] _ in Task { @MainActor in self?.subscribers.removeValue(forKey: id) } }
        return pair.stream
    }
    public func request(_ packet: RelayPacket) async throws -> RelayPacket {
        try Task.checkCancellation()
        guard !closed, reader != nil else { throw CompanionError.disconnected }
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { wait in
                pending[packet.id] = Pending(applicationID: packet.applicationID, wait: wait)
                Task {
                    do { guard let channel, !closed else { throw CompanionError.disconnected }; try await channel.send(packet) }
                    catch { pending.removeValue(forKey: packet.id)?.wait.resume(throwing: error) }
                }
                Task {
                    do { try await Task.sleep(for: .seconds(15)) } catch { return }
                    pending.removeValue(forKey: packet.id)?.wait.resume(throwing: CompanionError.timeout)
                }
            }
        }, onCancel: { Task { @MainActor [weak self] in self?.pending.removeValue(forKey: packet.id)?.wait.resume(throwing: CancellationError()) } })
    }
    public func close(_ error: Error = CompanionError.disconnected) {
        guard !closed else { return }; closed = true
        connectTask?.cancel(); discoveryTask?.cancel(); discoveryTask = nil
        reader?.cancel(); reader = nil; channel?.close(error); channel = nil
        let waits = pending.values; pending.removeAll(); waits.forEach { $0.wait.resume(throwing: error) }
        let streams = subscribers.values; subscribers.removeAll(); streams.forEach { $0.1.finish(throwing: error) }
        update(.disconnected)
    }
    private func update(_ state: CompanionConnectionState) { self.state = state; onState?(state) }
}
