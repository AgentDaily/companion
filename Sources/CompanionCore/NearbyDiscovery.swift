import Foundation
import Network

/// Transport discovery only; service names are identifiers, never authentication.
@MainActor public enum NearbyDiscovery {
    public static let serviceType = "_companion._tcp"
    public static func resolve(service: String) async throws -> NWEndpoint {
        let discovery = Discovery(service: service)
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await discovery.run()
        }, onCancel: { Task { @MainActor in discovery.finish(.failure(CancellationError())) } })
    }
}

@MainActor private final class Discovery {
    private let service: String
    private let browser: NWBrowser
    private var wait: CheckedContinuation<NWEndpoint, Error>?
    private var result: Result<NWEndpoint, Error>?
    private var timeout: Task<Void, Never>?
    init(service: String) {
        self.service = service
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        browser = NWBrowser(for: .bonjour(type: NearbyDiscovery.serviceType, domain: "local."), using: parameters)
    }
    func run() async throws -> NWEndpoint {
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
                    guard let self else { return }
                    ConnectionDiagnostics.shared.record("nearby.browse.results", "count=\(results.count)")
                    for candidate in results {
                        if case .service(let name, _, _, _) = candidate.endpoint, name == self.service {
                            ConnectionDiagnostics.shared.record("nearby.browse.matched", candidate.interfaces.map(\.name).sorted().joined(separator: ","))
                            self.finish(.success(candidate.endpoint)); return
                        }
                    }
                }
            }
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
        browser.cancel(); timeout?.cancel(); timeout = nil
        wait?.resume(with: result); wait = nil
    }
}
