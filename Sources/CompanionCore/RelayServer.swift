#if os(macOS)
import Foundation
import Network

@MainActor public final class RelayServer {
    private let registry: ApplicationRegistry
    private let listener: NWListener
    private var cancelled = false
    private var stopWaits: [CheckedContinuation<Void, Never>] = []
    private var startup: CheckedContinuation<Void, Error>?
    private var peers: [UUID: RelayPeer] = [:]
    public var onStatus: ((String) -> Void)?
    public var onPeerCount: ((Int) -> Void)?
    public init(registry: ApplicationRegistry, host: String, port: UInt16, key: String, nearbyService: String? = nil) throws {
        self.registry = registry

        let parameters = try FrameCodec.parameters(key: key, nearby: nearbyService != nil)
        parameters.allowLocalEndpointReuse = true
        if nearbyService == nil {
            guard let ip = IPv4Address(host) else { throw CompanionError.invalidAddress }
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(ip), port: NWEndpoint.Port(rawValue: port)!)
        }
        listener = try NWListener(using: parameters)
        if let nearbyService { listener.service = NWListener.Service(name: nearbyService, type: NearbyDiscovery.serviceType) }
    }
    public func applicationChanged(_ id: String) { peers.values.forEach { $0.applicationChanged(id) } }
    public func disconnectPeers() {
        let current = Array(peers.values); peers.removeAll(); current.forEach { $0.close() }; onPeerCount?(0)
    }
    public var port: UInt16 { listener.port?.rawValue ?? 0 }
    public func start() async throws {
        try await withCheckedThrowingContinuation { (wait: CheckedContinuation<Void, Error>) in
            startup = wait
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        self.startup?.resume(); self.startup = nil
                        self.onStatus?("正在接受手机连接")
                    case .failed(let error):
                        self.startup?.resume(throwing:error); self.startup = nil
                        self.onStatus?(error.localizedDescription)
                    case .cancelled:
                        self.startup?.resume(throwing:CompanionError.disconnected); self.startup = nil
                        self.cancelled = true
                        let waits = self.stopWaits; self.stopWaits = []
                        waits.forEach { $0.resume() }
                    default: break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in
                    guard let self else { connection.cancel(); return }
                    guard self.peers.count < 8 else { connection.cancel(); return }
                    let id = UUID()
                    let peer = RelayPeer(channel:FramedConnection(connection),registry:self.registry)
                    self.peers[id] = peer
                    peer.onReady = { [weak self] in self?.updateCount() }
                    peer.onClose = { [weak self] in self?.peers.removeValue(forKey:id); self?.updateCount() }
                    peer.start()
                }
            }
            listener.start(queue:.main)
        }
    }
    public func stopAndWait() async {
        if cancelled { return }
        await withCheckedContinuation { wait in stopWaits.append(wait); stop() }
    }
    private func updateCount() { onPeerCount?(peers.values.filter(\.isReady).count) }
    public func stop() { listener.cancel(); disconnectPeers() }
}

@MainActor private final class RelayPeer {
    let channel: FramedConnection
    let registry: ApplicationRegistry
    var onReady: (() -> Void)?
    var onClose: (() -> Void)?
    var isReady = false
    private var reader: Task<Void, Never>?
    private var applications: [String: any CompanionApplicationSession] = [:]
    private var workers: [UUID: (String, Task<Void, Never>)] = [:]
    private var tails: [String: Task<Void, Never>] = [:]
    init(channel: FramedConnection, registry: ApplicationRegistry) { self.channel = channel; self.registry = registry }
    func start() {
        reader = Task { [weak self] in
            guard let self else { return }
            do {
                try await channel.start(); isReady = true; onReady?()
                for try await packet in channel.packets {
                    guard workers.count < 64 else { throw CompanionError.server("请求积压，请重新连接。") }
                    if packet.kind == "application_close", let app = packet.applicationID {
                        cancelApplication(app)
                        try await channel.send(RelayPacket(kind: "response", id: packet.id, status: 200, applicationID: app))
                    } else { enqueue(packet) }
                }
            } catch { }
            close()
        }
    }
    func close() {
        reader?.cancel(); reader = nil
        workers.values.forEach { $0.1.cancel() }; workers.removeAll(); tails.removeAll()
        let sessions = applications.values; applications.removeAll(); sessions.forEach { $0.close() }
        channel.close(); isReady = false
        let callback = onClose; onClose = nil; callback?()
    }
    func applicationChanged(_ id: String) {
        cancelApplication(id)
        Task { try? await channel.send(RelayPacket(kind: "catalog_changed", applicationID: id)) }
    }
    private func cancelApplication(_ id: String) {
        applications.removeValue(forKey: id)?.close()
        let ids = workers.filter { $0.value.0 == id }.map(\.key)
        for worker in ids { workers.removeValue(forKey: worker)?.1.cancel() }
        tails.removeValue(forKey: id)
    }
    private func enqueue(_ packet: RelayPacket) {
        let app = packet.kind == "catalog" && packet.applicationID == nil ? "catalog" : packet.applicationID ?? "quenda"
        let previous = tails[app], id = UUID()
        let task = Task { [weak self] in
            await previous?.value
            guard !Task.isCancelled, let self, self.isReady else { return }
            await self.handle(packet)
            self.workers.removeValue(forKey: id)
        }
        workers[id] = (app, task); tails[app] = task
    }
    private func handle(_ packet: RelayPacket) async {
        do {
            let reply: RelayPacket
            if packet.kind == "catalog", packet.applicationID == nil {
                reply = RelayPacket(kind: "response", id: packet.id, body: try JSONEncoder().encode(registry.applications), status: 200)
            } else {
                let id = packet.applicationID ?? "quenda" // v1 clients
                if applications[id] == nil {
                    applications[id] = try registry.session(for: id) { [weak self] event in
                        guard let self, self.isReady else { throw CompanionError.disconnected }
                        var scoped = event; scoped.applicationID = id
                        try await self.channel.send(scoped)
                    }
                }
                guard let application = applications[id] else { throw CompanionError.disconnected }
                var response = try await application.handle(packet)
                response.id = packet.id; response.kind = "response"; response.applicationID = packet.applicationID
                reply = response
            }
            try Task.checkCancellation()
            try await channel.send(reply)
        } catch {
            try? await channel.send(RelayPacket(kind: "response", id: packet.id, status: 502, error: error.localizedDescription, applicationID: packet.applicationID))
        }
    }
}
#endif
