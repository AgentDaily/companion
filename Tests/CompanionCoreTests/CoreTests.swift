import XCTest
import Network
@testable import CompanionCore

final class CoreTests: XCTestCase {
    func testPairingRoundTripAndValidation() throws {
        let p = try Pairing(host: "100.87.136.122", port: 8765, key: String(repeating: "a1", count: 32))
        XCTAssertEqual(try Pairing(link: p.link), p)
        XCTAssertThrowsError(try Pairing(host: "", key: p.key))
        XCTAssertThrowsError(try Pairing(host: "host/path", key: p.key))
        XCTAssertThrowsError(try Pairing(host: "host", port: 0, key: p.key))
        XCTAssertThrowsError(try Pairing(host: "host", key: String(repeating: "z", count: 64)))
        XCTAssertThrowsError(try Pairing(link: "https://pair?host=host&key=\(p.key)"))
        let a = try Pairing.newKey(), b = try Pairing.newKey()
        XCTAssertEqual(a.count, 64); XCTAssertNotEqual(a, b)
    }
    func testNearbyPairingPreservesIdentity() throws {
        let pairing = try Pairing(host: "nearby", key: Pairing.newKey(), nearbyService: UUID().uuidString)
        XCTAssertEqual(try Pairing(link: pairing.link), pairing)
        XCTAssertThrowsError(try Pairing(host: "nearby", key: pairing.key, nearbyService: "invalid"))
        XCTAssertTrue(try FrameCodec.parameters(key: pairing.key, nearby: true).includePeerToPeer)
        XCTAssertFalse(try FrameCodec.parameters(key: pairing.key).includePeerToPeer)
    }
    @MainActor func testNearbyDiscoveryCancellation() async throws {
        let task = Task { try await NearbyDiscovery.resolve(service: UUID().uuidString) }
        task.cancel()
        do { _ = try await task.value; XCTFail("cancelled discovery completed") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
    @MainActor func testClosingRelayCancelsPendingDiscovery() async throws {
        let relay = try RelayClient(pairing: Pairing(host: "nearby", key: Pairing.newKey(), nearbyService: UUID().uuidString))
        let task = Task { try await relay.connect() }
        await Task.yield()
        relay.close()
        do { try await task.value; XCTFail("closed relay connected") } catch { }
    }
    func testFramesKeepUTF8AndBinaryAndRejectOversize() throws {
        let packet = RelayPacket(kind: "request", path: "/api/sessions", body: Data("中文🙂".utf8))
        let data = try FrameCodec.encode(packet)
        XCTAssertEqual(try FrameCodec.length(Data(data.prefix(4))), data.count - 4)
        let result = try JSONDecoder().decode(RelayPacket.self, from: data.dropFirst(4))
        XCTAssertEqual(result.body, packet.body); XCTAssertEqual(result.id, packet.id)
        for header in [Data(), Data([0,0,0,0]), Data([255,255,255,255]), Data([0,1])] { XCTAssertThrowsError(try FrameCodec.length(header)) }
        XCTAssertThrowsError(try FrameCodec.encode(RelayPacket(kind: "event", body: Data(repeating: 1, count: FrameCodec.maximumSize))))
    }
    func testRoutesRestrictRemoteAccess() {
        for path in ["/api/health", "/api/agents", "/api/workspaces", "/api/sessions?limit=50", "/api/sessions/session_123/message-pages?limit=50&before=20", "/api/sessions/session-123/interactions?pending_only=true"] { XCTAssertTrue(RoutePolicy.allows(method: "GET", path: path), path) }
        XCTAssertTrue(RoutePolicy.allows(method: "POST", path: "/api/sessions"))
        for path in ["/api/settings", "/api/agents/a/tools", "/api/sessions/../../settings", "/api/sessions/%2e%2e", "https://evil.example/api/health", "//evil.example/api/health", "/api/health#fragment", "/api/sessions/a/files", "/api/sessions/非ASCII"] { XCTAssertFalse(RoutePolicy.allows(method: "GET", path: path), path) }
        for method in ["DELETE", "PATCH", "PUT"] { XCTAssertFalse(RoutePolicy.allows(method: method, path: "/api/sessions/a")) }
        XCTAssertFalse(RoutePolicy.allows(method: "POST", path: "/api/sessions?delete=true"))
    }
    func testGatewayMustBeLocal() throws {
        XCTAssertEqual(try LocalGateway.validate("http://127.0.0.1:8000").port, 8000)
        XCTAssertNoThrow(try LocalGateway.validate("http://[::1]:8000"))
        for address in ["http://100.87.136.122:8000", "http://example.com", "file:///tmp/foo", "http://localhost:0", "http://localhost:65536", "http://name:password@localhost", "http://localhost/api", "http://localhost?x=y"] { XCTAssertThrowsError(try LocalGateway.validate(address), address) }
    }
    @MainActor func testTLSAuthenticatesAndTransfersFrames() async throws {
        let key = try Pairing.newKey()
        let listener = try NWListener(using: FrameCodec.parameters(key: key), on: .any)
        var accepted: FramedConnection?
        let received = expectation(description: "authenticated Unicode frame")
        listener.newConnectionHandler = { connection in
            Task { @MainActor in
                let peer = FramedConnection(connection); accepted = peer
                try await peer.start()
                for try await packet in peer.packets {
                    XCTAssertEqual(String(decoding: packet.body!, as: UTF8.self), "你好🙂")
                    try await peer.send(RelayPacket(kind: "response", id: packet.id, status: 200)); received.fulfill(); break
                }
            }
        }
        try await withCheckedThrowingContinuation { (wait: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { state in if case .ready = state { wait.resume() }; if case .failed(let error) = state { wait.resume(throwing: error) } }
            listener.start(queue: .main)
        }
        defer { listener.cancel(); accepted?.close() }
        let pairing = try Pairing(host: "127.0.0.1", port: listener.port!.rawValue, key: key)
        let client = try FramedConnection(pairing: pairing); defer { client.close() }
        try await client.start()
        let packet = RelayPacket(kind: "request", body: Data("你好🙂".utf8))
        try await client.send(packet)
        var iterator = client.packets.makeAsyncIterator()
        let reply = try await iterator.next(); XCTAssertEqual(reply?.id, packet.id)
        await fulfillment(of: [received], timeout: 3)
        // A different shared key cannot get past TLS; no app packet is accepted.
        let wrong = try FramedConnection(pairing: Pairing(host: pairing.host, port: pairing.port, key: Pairing.newKey()))
        do { try await wrong.start(); XCTFail("wrong key authenticated") } catch { }
        wrong.close()
    }
}
