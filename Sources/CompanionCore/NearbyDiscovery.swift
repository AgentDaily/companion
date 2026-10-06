import Foundation
import Network
import CryptoKit

/// Transport discovery only; service names are identifiers, never authentication.
@MainActor public enum NearbyDiscovery {
    #if DEBUG
    static var diagnosticExcludedInterfaces: [NWInterface] = []
    #endif
    public static let serviceType = "_companion._tcp"
    /// Pairing identifiers are UUIDs; DNS service-label case is not identity.
    static func matchesName(_ name: String, service: String) -> Bool {
        guard let candidate = UUID(uuidString: name), let expected = UUID(uuidString: service) else { return false }
        return candidate == expected
    }
    static func candidateDescription(_ name: String, service: String) -> String {
        let relation: String
        if name == service { relation = "exact" }
        else if matchesName(name, service: service) { relation = "case-only" }
        else if name.lowercased().hasPrefix(service.lowercased() + " (") { relation = "possible-rename" }
        else { relation = "different" }
        func fingerprint(_ value: String) -> String {
            SHA256.hash(data: Data(value.lowercased().utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
        }
        return "relation=\(relation) expected=\(fingerprint(service)) candidate=\(fingerprint(name))"
    }
    /// Keep the scope supplied by discovery when there is only one possible interface.
    static func connectionEndpoint(_ endpoint: NWEndpoint, interfaces: [NWInterface]) -> NWEndpoint {
        guard case .service(let name, let type, let domain, nil) = endpoint,
              interfaces.count == 1, let interface = interfaces.first else { return endpoint }
        // NWBrowser can return an unscoped endpoint even when it found the service
        // on a single interface. Resolve on that actual discovery interface.
        // With multiple interfaces leave selection to Network.framework.
        return .service(name: name, type: type, domain: domain, interface: interface)
    }
    /// One-shot lookup only. Connections should own a NearbyDiscoverySession.
    public static func resolve(service: String) async throws -> NWEndpoint {
        let discovery = NearbyDiscoverySession(service: service)
        defer { discovery.cancel() }
        return try await discovery.resolve()
    }
}

/// Owns discovery demand while a nearby connection uses the resulting service.
/// The connection owner must cancel on failure, fallback or disconnection.
@MainActor public final class NearbyDiscoverySession {
    private let service: String
    private let browser: NWBrowser
    private var wait: CheckedContinuation<NWEndpoint, Error>?
    private var result: Result<NWEndpoint, Error>?
    private var timeout: Task<Void, Never>?
    private var cancelled = false
    public init(service: String) {
        self.service = service
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        browser = NWBrowser(for: .bonjour(type: NearbyDiscovery.serviceType, domain: "local."), using: parameters)
    }
    deinit { browser.cancel() }
    private(set) var isBrowsing = false
    public func resolve() async throws -> NWEndpoint {
        guard !cancelled else { throw CancellationError() }
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await run()
        }, onCancel: { Task { @MainActor [weak self] in self?.cancel() } })
    }
    public func cancel() {
        guard !cancelled else { return }; cancelled = true
        if isBrowsing { ConnectionDiagnostics.shared.record("nearby.browse.stopped") }
        browser.cancel(); isBrowsing = false
        finish(.failure(CancellationError()))
    }
    private func run() async throws -> NWEndpoint {
        ConnectionDiagnostics.shared.record("nearby.browse.start", "peer-to-peer enabled")
        return try await withCheckedThrowingContinuation { continuation in
            if let result { continuation.resume(with: result); return }
            wait = continuation
            browser.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    switch state {
                    case .ready: ConnectionDiagnostics.shared.record("nearby.browse.ready")
                    case .waiting(let error): ConnectionDiagnostics.shared.record("nearby.browse.waiting", String(describing: error))
                    case .failed(let error):
                        ConnectionDiagnostics.shared.record("nearby.browse.failed", String(describing: error))
                        self?.finish(.failure(error))
                    default: break
                    }
                }
            }
            browser.browseResultsChangedHandler = { [weak self] results, _ in
                Task { @MainActor in
                    guard let self, self.result == nil else { return }
                    ConnectionDiagnostics.shared.record("nearby.browse.results", "count=\(results.count)")
                    for candidate in results {
                        guard case .service(let name, _, _, _) = candidate.endpoint else { continue }
                        ConnectionDiagnostics.shared.record("nearby.browse.candidate", NearbyDiscovery.candidateDescription(name, service: self.service) + " interfaces=" + candidate.interfaces.map(\.name).sorted().joined(separator: ","))
                        if NearbyDiscovery.matchesName(name, service: self.service) {
                            ConnectionDiagnostics.shared.record("nearby.browse.matched", candidate.interfaces.map(\.name).sorted().joined(separator: ","))
                            #if DEBUG
                            if ProcessInfo.processInfo.environment["COMPANION_DIAGNOSTIC_AWDL_ONLY"] == "1" {
                                ConnectionDiagnostics.shared.record("debug.awdl.interfaces", candidate.interfaces.map { "\($0.name):\($0.type)" }.joined(separator: ","))
                                NearbyDiscovery.diagnosticExcludedInterfaces = candidate.interfaces.filter { $0.name != "awdl0" }
                                guard let awdl = candidate.interfaces.first(where: { $0.name == "awdl0" }) else { continue }
                                guard case .service(let name, let type, let domain, _) = candidate.endpoint else { continue }
                                self.finish(.success(.service(name: name, type: type, domain: domain, interface: ProcessInfo.processInfo.environment["COMPANION_DIAGNOSTIC_UNSCOPED"] == "1" ? nil : awdl))); return
                            }
                            #endif
                            self.finish(.success(NearbyDiscovery.connectionEndpoint(candidate.endpoint, interfaces: candidate.interfaces))); return
                        }
                    }
                }
            }
            isBrowsing = true
            browser.start(queue: .main)
            timeout = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
                ConnectionDiagnostics.shared.record("nearby.browse.timeout")
                self?.finish(.failure(CompanionError.server("未发现已配对的 Mac。请确认附近连接已开启、两台设备 Wi-Fi 已开启，并允许本地网络访问。")))
            }
        }
    }
    func finish(_ result: Result<NWEndpoint, Error>) {
        guard self.result == nil else { return }
        self.result = result
        if case .failure = result { browser.cancel(); isBrowsing = false }
        else {
            // Affected iOS versions withdraw AWDL datapaths when their final browse
            // is cancelled, even with a live connection. The connection owns cleanup.
            ConnectionDiagnostics.shared.record("nearby.browse.retained")
        }
        timeout?.cancel(); timeout = nil
        wait?.resume(with: result); wait = nil
    }
}
