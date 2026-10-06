import XCTest
import Network
@testable import CompanionCore

final class ConnectionDiagnosticsTests: XCTestCase {
    @MainActor func testPersistedTransportHistoryIsBounded() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("diagnostics.json")
        let diagnostics = ConnectionDiagnostics(file: file)
        for number in 0..<300 { diagnostics.record("nearby.browse.results", "count=\(number)") }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let entries = try decoder.decode([ConnectionDiagnostics.Entry].self, from: Data(contentsOf: file))
        XCTAssertEqual(entries.count, 240)
        XCTAssertEqual(entries.first?.detail, "count=60")
        XCTAssertEqual(entries.last?.detail, "count=299")
    }
    @MainActor func testUnwritableDiagnosticsDoNotInterruptConnectionCode() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: root)
        let diagnostics = ConnectionDiagnostics(file: root.appendingPathComponent("diagnostics.json"))
        diagnostics.record("nearby.browse.timeout")
        XCTAssertEqual(diagnostics.entries.count, 1)
        XCTAssertTrue(diagnostics.summary.contains("nearby.browse.timeout"))
    }
    @MainActor func testTLSStallRecordsPathAndReportAvailabilityWithoutEndpointAddresses() async throws {
        let previous = ConnectionDiagnostics.shared
        let diagnostics = ConnectionDiagnostics()
        ConnectionDiagnostics.shared = diagnostics
        defer { ConnectionDiagnostics.shared = previous }
        let listener = try NWListener(using: .tcp, on: .any)
        var accepted: [NWConnection] = []
        defer { listener.cancel(); accepted.forEach { $0.cancel() } }
        try await withCheckedThrowingContinuation { (wait: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { state in
                if case .ready = state { wait.resume() }
                if case .failed(let error) = state { wait.resume(throwing: error) }
            }
            listener.newConnectionHandler = { connection in
                Task { @MainActor in
                    accepted.append(connection)
                    connection.start(queue: .main) // Accept TCP but never answer the TLS ClientHello.
                }
            }
            listener.start(queue: .main)
        }
        let channel = try FramedConnection(endpoint: .hostPort(host: "127.0.0.1", port: listener.port!), key: Pairing.newKey())
        do { try await channel.start(); XCTFail("Silent TLS peer became ready") }
        catch { guard case CompanionError.timeout = error else { XCTFail("Unexpected error: \(error)"); return } }
        try await Task.sleep(for: .milliseconds(100)) // Network report is delivered asynchronously.
        XCTAssertTrue(diagnostics.entries.contains { $0.stage == "transport.connect.timeout" && $0.detail.contains("status=satisfied") })
        XCTAssertTrue(diagnostics.entries.contains { $0.stage == "transport.connect.packets" && ($0.detail.contains("sentIP=") || $0.detail.contains("unavailable")) }, diagnostics.summary)
        XCTAssertFalse(diagnostics.summary.contains("127.0.0.1"))
    }

    @MainActor func testBonjourConnectionSurvivesSetupLongerThanTenSeconds() async throws {
        let key = try Pairing.newKey(), service = UUID().uuidString
        let listener = try NWListener(using: FrameCodec.parameters(key: key, nearby: true))
        listener.service = NWListener.Service(name: service, type: NearbyDiscovery.serviceType)
        var serverTask: Task<Void, Never>?
        var peer: FramedConnection?
        defer { listener.cancel(); serverTask?.cancel(); peer?.close() }
        try await withCheckedThrowingContinuation { (wait: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { state in
                if case .ready = state { wait.resume() }
                if case .failed(let error) = state { wait.resume(throwing: error) }
            }
            listener.newConnectionHandler = { connection in
                Task { @MainActor in
                    let channel = FramedConnection(connection)
                    peer = channel
                    serverTask = Task {
                        do {
                            // A bounded delayed peer exercises the connection setup budget.
                            // This does not simulate AWDL service-resolution internals.
                            try await Task.sleep(for: .seconds(11))
                            try await channel.start()
                            for try await packet in channel.packets { try await channel.send(packet) }
                        } catch { channel.close(error) }
                    }
                }
            }
            listener.start(queue: .main)
        }
        let channel = try FramedConnection(endpoint: .service(name: service, type: NearbyDiscovery.serviceType, domain: "local.", interface: nil), key: key)
        defer { channel.close() }
        try await channel.start()
        let packet = RelayPacket(kind: "probe")
        try await channel.send(packet)
        var iterator = channel.packets.makeAsyncIterator()
        let echo = try await iterator.next()
        XCTAssertEqual(echo?.id, packet.id)
    }

    @MainActor func testConnectionDiscoveryRetainsBrowserUntilOwnerCancels() async throws {
        let service = UUID().uuidString
        let listener = try NWListener(using: .tcp)
        listener.service = NWListener.Service(name: service, type: NearbyDiscovery.serviceType)
        listener.newConnectionHandler = { $0.cancel() }
        defer { listener.cancel() }
        try await withCheckedThrowingContinuation { (wait: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { state in
                if case .ready = state { wait.resume() }
                if case .failed(let error) = state { wait.resume(throwing: error) }
            }
            listener.start(queue: .main)
        }
        let discovery = NearbyDiscoverySession(service: service)
        defer { discovery.cancel() }
        _ = try await discovery.resolve()
        // A resolved endpoint is not the end of the wireless discovery demand.
        XCTAssertTrue(discovery.isBrowsing, "Resolution prematurely withdrew peer-to-peer discovery demand")
        discovery.cancel()
        XCTAssertFalse(discovery.isBrowsing)
        discovery.cancel() // Owner cleanup remains safe after explicit cancellation.
    }

    @MainActor func testDiscoveryDemandFollowsLocalWiFiPathRatherThanWiredTransport() {
        XCTAssertTrue(FramedConnection.needsNearbyDiscovery(interfaceTypes: [.wifi], host: .ipv6(IPv6Address("fe80::1234")!)))
        XCTAssertFalse(FramedConnection.needsNearbyDiscovery(interfaceTypes: [.wiredEthernet], host: .ipv6(IPv6Address("fe80::1234")!)))
        XCTAssertFalse(FramedConnection.needsNearbyDiscovery(interfaceTypes: [.wifi], host: .ipv4(IPv4Address("192.168.1.2")!)))
        XCTAssertFalse(FramedConnection.needsNearbyDiscovery(interfaceTypes: [.wifi], host: .ipv6(IPv6Address("fd00::1234")!)))
        XCTAssertTrue(FramedConnection.needsNearbyDiscovery(interfaceTypes: [], host: nil))
    }

    @MainActor func testCancelledDiscoverySessionCannotReopen() async throws {
        let discovery = NearbyDiscoverySession(service: UUID().uuidString)
        discovery.cancel()
        do { _ = try await discovery.resolve(); XCTFail("Cancelled discovery reopened") }
        catch is CancellationError { }
        XCTAssertFalse(discovery.isBrowsing)
    }

    @MainActor func testLinkOwnsDiscoveryDuringHandshakeAndReleasesOnCancel() async throws {
        let previous = ConnectionDiagnostics.shared
        let diagnostics = ConnectionDiagnostics()
        ConnectionDiagnostics.shared = diagnostics
        defer { ConnectionDiagnostics.shared = previous }
        let service = UUID().uuidString
        let listener = try NWListener(using: .tcp)
        listener.service = NWListener.Service(name: service, type: NearbyDiscovery.serviceType)
        var peer: NWConnection?
        listener.newConnectionHandler = { connection in
            Task { @MainActor in peer = connection; connection.start(queue: .main) }
        }
        defer { listener.cancel(); peer?.cancel() }
        try await withCheckedThrowingContinuation { (wait: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { state in
                if case .ready = state { wait.resume() }
                if case .failed(let error) = state { wait.resume(throwing: error) }
            }
            listener.start(queue: .main)
        }
        let pairing = try Pairing(host: "nearby", key: Pairing.newKey(), nearbyService: service)
        let link = CompanionLink(pairing: pairing)
        let opening = Task { try await link.connect() }
        defer { link.close(); opening.cancel() }
        for _ in 0..<200 {
            if peer != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotNil(peer, "Real Bonjour discovery never reached the handshake")
        XCTAssertTrue(diagnostics.entries.contains { $0.stage == "nearby.browse.retained" })
        XCTAssertFalse(diagnostics.entries.contains { $0.stage == "nearby.browse.stopped" }, "Link withdrew discovery before authentication completed")
        link.close()
        _ = try? await opening.value
        XCTAssertTrue(diagnostics.entries.contains { $0.stage == "nearby.browse.stopped" }, "Cancelled link leaked discovery demand")
    }

}
