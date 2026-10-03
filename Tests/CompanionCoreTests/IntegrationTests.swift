import XCTest
@testable import CompanionCore
import CompanionUI

final class IntegrationTests: XCTestCase {
    private func fixture() throws -> URL {
        guard let address = ProcessInfo.processInfo.environment["QUENDA_FIXTURE_URL"], let url = URL(string: address) else { throw XCTSkip("Run scripts/test.sh for the isolated Gateway integration tests.") }
        return url
    }
    @MainActor private func setup() async throws -> (RelayServer, Backend, URL, String, String) {
        let url = try fixture(); let key = try Pairing.newKey()
        let relay = try RelayServer(gateway: url, host: "127.0.0.1", port: 0, key: key)
        try await relay.start()
        let client = try Backend(pairing: Pairing(host: "127.0.0.1", port: relay.port, key: key))
        try await client.connect()
        let data = try await client.request(method: "POST", path: "/api/sessions", body: .object(["agent_id":.string("quenda-code")]))
        let session = try JSONDecoder().decode(SessionInfo.self, from: data)
        return (relay, client, url, session.id, key)
    }
    @MainActor func testNearbyDiscoveryAndAuthenticatedRelay() async throws {
        let url = try fixture(), key = try Pairing.newKey(), service = UUID().uuidString
        let server = try RelayServer(gateway: url, host: "", port: 0, key: key, nearbyService: service)
        try await server.start(); defer { server.stop() }
        let pairing = try Pairing(host: "nearby", key: key, nearbyService: service)
        let backend = try Backend(pairing: pairing); defer { backend.close() }
        try await backend.connect()
        let agents = try JSONDecoder().decode([Agent].self, from: await backend.request(path: "/api/agents"))
        XCTAssertEqual(agents.first?.name, "测试 Agent")
        let wrong = try Backend(pairing: Pairing(host: "nearby", key: Pairing.newKey(), nearbyService: service))
        defer { wrong.close() }
        do { try await wrong.connect(); XCTFail("unauthenticated nearby peer accepted") } catch { }
    }
    @MainActor func testRepeatedGatewayWebSocketHandshake() async throws {
        let url = try fixture(); let gateway = GatewayClient(baseURL: url)
        let data = try await gateway.request(method: "POST", path: "/api/sessions", body: JSONEncoder().encode(JSONValue.object(["agent_id":.string("quenda-code")])))
        let id = try JSONDecoder().decode(SessionInfo.self, from:data.body).id
        for _ in 0..<20 {
            let socket = try gateway.channel(sessionID:id)
            _ = try await socket.start()
            socket.close()
        }
    }
    @MainActor func testRelayChatPermissionsInteractionAndRoutes() async throws {
        let (server, backend, _, id, _) = try await setup()
        defer { backend.close(); server.stop() }
        let agents = try JSONDecoder().decode([Agent].self, from: await backend.request(path: "/api/agents"))
        XCTAssertEqual(agents.first?.name, "测试 Agent")
        do { _ = try await backend.request(path: "/api/settings"); XCTFail("private route allowed") } catch { }
        let stream = try await backend.watch(id); var events = stream.makeAsyncIterator()
        try await backend.send(.object(["type":.string("user_message"),"content":.string("你好")]))
        let start = try await events.next(); XCTAssertEqual(start?.type,"stream_start")
        let chunk = try await events.next(); XCTAssertEqual(chunk?.content.text,"你好，")
        let permission = try await events.next(); XCTAssertEqual(permission?.type,"permission_requested")
        try await backend.send(.object(["type":.string("permission_response"),"request_id":.string("permission-1"),"decision":.string("allow")]))
        let resolved = try await events.next(); XCTAssertEqual(resolved?.type,"permission_resolved")
        _ = try await events.next()
        let end = try await events.next(); XCTAssertEqual(end?.content.text,"你好，世界")
        let history = try JSONDecoder().decode(MessagePage.self, from: await backend.request(path: "/api/sessions/\(id)/message-pages?limit=50"))
        XCTAssertEqual(history.items.map(\.role),["user","assistant"])
        try await backend.send(.object(["type":.string("user_message"),"content":.string("interaction")]))
        _ = try await events.next()
        let interaction = try await events.next(); XCTAssertEqual(interaction?.type,"interaction_requested")
        try await backend.send(.object(["type":.string("interaction_response"),"interaction_id":.string("interaction-1"),"answers":.array([.object(["question_id":.string("question-1"),"selected_option_ids":.array([.string("translate")]),"value":.string("")])])]))
        _ = try await events.next()
        let response = try await events.next(); XCTAssertEqual(response?.content.text,"已选择翻译")
        let pending = try JSONDecoder().decode([JSONValue].self, from: await backend.request(path:"/api/sessions/\(id)/interactions?pending_only=true"))
        XCTAssertTrue(pending.isEmpty)
    }
    @MainActor func testSwitchingSessionsRejectsStaleCommand() async throws {
        let (server, backend, url, firstID, _) = try await setup()
        defer { backend.close(); server.stop() }
        let data = try await backend.request(method:"POST",path:"/api/sessions",body:.object(["agent_id":.string("quenda-code")]))
        let secondID = try JSONDecoder().decode(SessionInfo.self,from:data).id
        _ = try await backend.watch(firstID)
        _ = try await backend.watch(secondID)
        do {
            try await backend.send(.object(["type":.string("user_message"),"content":.string("stale draft")]),sessionID:firstID)
            XCTFail("stale command reached the new session")
        } catch { }
        let (stats, _) = try await URLSession.shared.data(from:url.appendingPathComponent("test/stats/\(secondID)"))
        XCTAssertTrue(try JSONDecoder().decode(JSONValue.self,from:stats)["commands"].array.isEmpty)
    }
    @MainActor func testStoreReconnectDoesNotResendUserMessage() async throws {
        let (initial, backend, url, id, key) = try await setup(); backend.close()
        let port = initial.port
        let pairing = try Pairing(host:"127.0.0.1",port:port,key:key)
        let store = ClientStore(); defer { store.disconnect() }
        await store.connect { try Backend(pairing: pairing) }
        XCTAssertTrue(store.connected)
        await store.open(id); XCTAssertTrue(store.streamConnected)
        try await store.send("slow")
        await initial.stopAndWait();
        let replacement = try RelayServer(gateway:url,host:"127.0.0.1",port:port,key:key)
        try await replacement.start(); defer { replacement.stop() }
        for _ in 0..<80 {
            if store.streamConnected && store.messages.last?.content == "恢复前恢复后" { break }
            try await Task.sleep(for:.milliseconds(100))
        }
        XCTAssertTrue(store.streamConnected)
        XCTAssertEqual(store.messages.last?.content,"恢复前恢复后")
        let (stats, _) = try await URLSession.shared.data(from:url.appendingPathComponent("test/stats/\(id)"))
        let value = try JSONDecoder().decode(JSONValue.self,from:stats)
        XCTAssertEqual(value["commands"].array.filter { $0["type"].text == "user_message" }.count,1)
    }
    @MainActor func testReconnectReplaysActiveStreamAndInterrupt() async throws {
        let (server, backend, _, id, key) = try await setup(); defer { server.stop() }
        let stream = try await backend.watch(id); var events = stream.makeAsyncIterator()
        try await backend.send(.object(["type":.string("user_message"),"content":.string("slow")]))
        _ = try await events.next(); _ = try await events.next(); backend.close()
        let next = try Backend(pairing:Pairing(host:"127.0.0.1",port:server.port,key:key)); defer { next.close() }
        try await next.connect()
        let replay = try await next.watch(id); var iterator = replay.makeAsyncIterator()
        let start = try await iterator.next(); XCTAssertEqual(start?.metadata?["resumed"],.bool(true))
        let chunk = try await iterator.next(); XCTAssertEqual(chunk?.content.text,"恢复前")
        try await next.send(.object(["type":.string("interrupt")]))
        let terminal = try await iterator.next(); XCTAssertEqual(terminal?.type,"stream_interrupted")
    }
    @MainActor func testExistingGatewayReadOnlyViaTailscaleInterface() async throws {
        guard let address = ProcessInfo.processInfo.environment["QUENDA_LIVE_GATEWAY"], let url = URL(string:address), let host = LocalGateway.tailscaleAddresses().first else { throw XCTSkip("Optional read-only live Gateway / Tailscale probe.") }
        let key = try Pairing.newKey()
        let relay = try RelayServer(gateway:url,host:"127.0.0.1",port:0,key:key)
        try await relay.start(); defer { relay.stop() }
        let serve = TailscaleServe()
        try await serve.start(localPort: relay.port, publicPort: 8765); defer { serve.stop() }
        let backend = try Backend(pairing:Pairing(host:host,port:8765,key:key)); defer { backend.close() }
        try await backend.connect()
        let agents = try JSONDecoder().decode([Agent].self,from:await backend.request(path:"/api/agents"))
        let sessions = try JSONDecoder().decode([SessionInfo].self,from:await backend.request(path:"/api/sessions?limit=1"))
        XCTAssertFalse(agents.isEmpty)
        if let session = sessions.first {
            _ = try JSONDecoder().decode(MessagePage.self,from:await backend.request(path:"/api/sessions/\(session.id)/message-pages?limit=1"))
        }
    }
}
