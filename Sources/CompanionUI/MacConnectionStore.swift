#if os(macOS)
import Foundation
import SwiftUI
import CompanionCore

/// Hosts applications over nearby Wi-Fi and optional private Tailscale forwarding.
@MainActor public final class MacConnectionStore: ObservableObject {
    @Published public var host = LocalGateway.tailscaleAddresses().first ?? ""
    @Published public var remoteEnabled = UserDefaults.standard.object(forKey: "connection.remoteEnabled") as? Bool ?? true
    @Published public private(set) var running = false
    @Published public private(set) var starting = false
    @Published public private(set) var peers = 0
    @Published public private(set) var pairing: Pairing?
    @Published public private(set) var status = "手机连接尚未开启"
    @Published public private(set) var remoteStatus = ""
    @Published public var error: String?
    private let registry: ApplicationRegistry
    private var nearby: RelayServer?
    private var remote: RelayServer?
    private var serve: TailscaleServe?
    private var nearbyPeers = 0
    private var remotePeers = 0
    private var generation = 0
    public init(registry: ApplicationRegistry) { self.registry = registry }
    public func start() async {
        guard !starting, !running else { return }
        starting = true; generation += 1; let token = generation
        error = nil; remoteStatus = ""
        do {
            let key = try CredentialStore.read("relay-key") ?? Pairing.newKey()
            try CredentialStore.write(key, account: "relay-key")
            let service = try CredentialStore.read("nearby-service") ?? UUID().uuidString
            try CredentialStore.write(service, account: "nearby-service")
            let server = try RelayServer(registry: registry, host: "", port: 0, key: key, nearbyService: service)
            nearby = server
            server.onPeerCount = { [weak self] count in
                guard let self, self.generation == token else { return }
                self.nearbyPeers = count; self.updatePeers()
            }
            try await server.start()
            guard generation == token else { server.stop(); return }
            // Nearby remains usable even if remote setup fails.
            running = true; status = "附近连接已开启"
            pairing = try Pairing(host: "nearby", key: key, nearbyService: service)
            if remoteEnabled, !host.isEmpty {
                do {
                    let listener = try RelayServer(registry: registry, host: "127.0.0.1", port: 8766, key: key)
                    remote = listener
                    listener.onPeerCount = { [weak self] count in
                        guard let self, self.generation == token else { return }
                        self.remotePeers = count; self.updatePeers()
                    }
                    try await listener.start()
                    guard generation == token else { listener.stop(); return }
                    let forwarding = TailscaleServe(); serve = forwarding
                    try await forwarding.start(localPort: listener.port)
                    guard generation == token else { forwarding.stop(); return }
                    pairing = try Pairing(host: host, key: key, nearbyService: service)
                    remoteStatus = "Tailscale 回退已开启"
                } catch {
                    guard generation == token else { return }
                    serve?.stop(); serve = nil; remote?.stop(); remote = nil
                    remoteStatus = "附近连接可用；Tailscale 未开启：\(error.localizedDescription)"
                }
            } else { remoteStatus = remoteEnabled ? "未发现 Tailscale 地址，使用附近连接" : "仅使用附近连接" }
            UserDefaults.standard.set(remoteEnabled, forKey: "connection.remoteEnabled")
        } catch {
            guard generation == token else { return }
            stop(); self.error = error.localizedDescription
        }
        if generation == token { starting = false }
    }
    public func stop() {
        generation += 1
        serve?.stop(); serve = nil; nearby?.stop(); nearby = nil; remote?.stop(); remote = nil
        starting = false; running = false; pairing = nil; nearbyPeers = 0; remotePeers = 0; peers = 0
        status = "手机连接尚未开启"; remoteStatus = ""
    }
    public func applicationChanged(_ id: String) { nearby?.applicationChanged(id); remote?.applicationChanged(id) }
    public func rotateKey() async {
        let previousNearby = nearby, previousRemote = remote, previousServe = serve
        stop()
        await previousNearby?.stopAndWait(); await previousRemote?.stopAndWait(); await previousServe?.stopAndWait()
        do { try CredentialStore.write(Pairing.newKey(), account: "relay-key"); await start() }
        catch { self.error = error.localizedDescription }
    }
    private func updatePeers() { peers = nearbyPeers + remotePeers }
}
#endif
