import XCTest
import Network
@testable import CompanionCore
import CompanionUI

@MainActor private final class EchoApplication: CompanionApplicationSession {
    let name: String
    let emit: @MainActor (RelayPacket) async throws -> Void
    var handled = 0
    var closed = false
    init(name: String, emit: @escaping @MainActor (RelayPacket) async throws -> Void) { self.name = name; self.emit = emit }
    func handle(_ packet: RelayPacket) async throws -> RelayPacket {
        handled += 1
        if packet.kind == "publish" { try await emit(RelayPacket(kind: "event", body: Data(name.utf8), sessionID: "same-session")) }
        return RelayPacket(kind: "response", body: Data(name.utf8), status: 200)
    }
    func close() { closed = true }
}

final class ApplicationTests: XCTestCase {
    @MainActor func testCatalogAndApplicationsWorkWithoutQuendaAndStayIsolated() async throws {
        let registry = ApplicationRegistry(), key = try Pairing.newKey()
        var notes: EchoApplication?, transcription: EchoApplication?
        registry.register(CompanionApplication(id: "notes", name: "Notes", summary: "", symbol: "note")) {
            let app = EchoApplication(name: "notes", emit: $0); notes = app; return app
        }
        registry.register(CompanionApplication(id: "transcription", name: "Transcription", summary: "", symbol: "mic")) {
            let app = EchoApplication(name: "transcription", emit: $0); transcription = app; return app
        }
        registry.register(CompanionApplication(id: "quenda", name: "Quenda", summary: "", symbol: "bubble", enabled: false)) { _ in
            XCTFail("disabled application instantiated"); return EchoApplication(name: "disabled", emit: { _ in })
        }
        let server = try RelayServer(registry: registry, host: "127.0.0.1", port: 0, key: key)
        try await server.start(); defer { server.stop() }
        let link = CompanionLink(pairing: try Pairing(host: "127.0.0.1", port: server.port, key: key))
        try await link.connect(); defer { link.close() }
        let catalog = try await link.applications()
        XCTAssertEqual(catalog.map(\.id), ["notes", "quenda", "transcription"])
        XCTAssertFalse(catalog.first { $0.id == "quenda" }!.enabled)
        let notesEvents = link.events(applicationID: "notes"), transcriptionEvents = link.events(applicationID: "transcription")
        var noteIterator = notesEvents.makeAsyncIterator(), transcriptionIterator = transcriptionEvents.makeAsyncIterator()
        _ = try await link.request(RelayPacket(kind: "publish", applicationID: "transcription"))
        _ = try await link.request(RelayPacket(kind: "publish", applicationID: "notes"))
        let noteEvent = try await noteIterator.next(), transcriptionEvent = try await transcriptionIterator.next()
        XCTAssertEqual(noteEvent?.applicationID, "notes")
        XCTAssertEqual(transcriptionEvent?.applicationID, "transcription")
        XCTAssertEqual(noteEvent?.sessionID, transcriptionEvent?.sessionID)
        XCTAssertEqual(notes?.handled, 1); XCTAssertEqual(transcription?.handled, 1)
        for id in ["quenda", "unknown"] {
            do { _ = try await link.request(RelayPacket(kind: "publish", applicationID: id)); XCTFail("unavailable app accepted") } catch { }
        }
        let adapter = Backend(link: link); adapter.close()
        let response = try await link.request(RelayPacket(kind: "echo", applicationID: "notes"))
        XCTAssertEqual(String(decoding: response.body!, as: UTF8.self), "notes")
        XCTAssertEqual(link.state, .connected(.remote))
        link.close()
        await server.stopAndWait()
        XCTAssertEqual(notes?.closed, true); XCTAssertEqual(transcription?.closed, true)
    }
    @MainActor func testChangingOneApplicationKeepsDeviceAndOtherApplicationAlive() async throws {
        let registry = ApplicationRegistry(), key = try Pairing.newKey()
        var notes: EchoApplication?, transcription: EchoApplication?
        let noteDescriptor = CompanionApplication(id: "notes", name: "Notes", summary: "", symbol: "note")
        registry.register(noteDescriptor) { let app = EchoApplication(name: "notes", emit: $0); notes = app; return app }
        registry.register(CompanionApplication(id: "transcription", name: "Transcription", summary: "", symbol: "mic")) {
            let app = EchoApplication(name: "transcription", emit: $0); transcription = app; return app
        }
        let server = try RelayServer(registry: registry, host: "127.0.0.1", port: 0, key: key)
        try await server.start(); defer { server.stop() }
        let store = DeviceConnectionStore(pairing: try Pairing(host: "127.0.0.1", port: server.port, key: key))
        defer { store.suspend() }; await store.resume()
        let link = try XCTUnwrap(store.link), connectionRevision = store.revision
        _ = try await link.request(RelayPacket(kind: "echo", applicationID: "notes"))
        _ = try await link.request(RelayPacket(kind: "echo", applicationID: "transcription"))
        registry.register(CompanionApplication(id: "notes", name: "Notes", summary: "", symbol: "note", enabled: false)) { _ in
            XCTFail("disabled app instantiated"); return EchoApplication(name: "disabled", emit: { _ in })
        }
        server.applicationChanged("notes")
        for _ in 0..<50 {
            if store.applicationRevisions["notes"] == 1 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(store.applicationRevisions["notes"], 1)
        XCTAssertFalse(try XCTUnwrap(store.applications.first { $0.id == "notes" }).enabled)
        XCTAssertTrue(store.link === link); XCTAssertEqual(store.revision, connectionRevision)
        XCTAssertEqual(notes?.closed, true); XCTAssertEqual(transcription?.closed, false)
        do { _ = try await link.request(RelayPacket(kind: "echo", applicationID: "notes")); XCTFail("disabled app accepted") } catch { }
        _ = try await link.request(RelayPacket(kind: "echo", applicationID: "transcription"))
        XCTAssertEqual(transcription?.handled, 2)
    }
    @MainActor func testNearbyWinsWhenBothAddressesArePresent() async throws {
        let key = try Pairing.newKey(), registry = ApplicationRegistry()
        let server = try RelayServer(registry: registry, host: "127.0.0.1", port: 0, key: key)
        try await server.start(); defer { server.stop() }
        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: server.port)!)
        var discoveries = 0
        let pairing = try Pairing(host: "127.0.0.1", port: 1, key: key, nearbyService: UUID().uuidString)
        XCTAssertEqual(try Pairing(link: pairing.link), pairing)
        let link = CompanionLink(pairing: pairing) { _ in discoveries += 1; return endpoint }
        var states: [CompanionConnectionState] = []
        link.onState = { states.append($0) }
        defer { link.close() }
        try await link.connect(); _ = try await link.applications()
        XCTAssertEqual(link.state, .connected(.nearby)); XCTAssertEqual(discoveries, 1)
        XCTAssertEqual(states, [.discovering, .connectingNearby, .connected(.nearby)])
    }
    @MainActor func testUnavailableNearbyFallsBackAndDoesNotReplayRequests() async throws {
        let key = try Pairing.newKey(), registry = ApplicationRegistry()
        var application: EchoApplication?
        registry.register(CompanionApplication(id: "notes", name: "Notes", summary: "", symbol: "note")) {
            let app = EchoApplication(name: "notes", emit: $0); application = app; return app
        }
        let server = try RelayServer(registry: registry, host: "127.0.0.1", port: 0, key: key)
        try await server.start(); defer { server.stop() }
        let pairing = try Pairing(host: "127.0.0.1", port: server.port, key: key, nearbyService: UUID().uuidString)
        let link = CompanionLink(pairing: pairing) { _ in throw CompanionError.timeout }
        defer { link.close() }
        try await link.connect()
        _ = try await link.request(RelayPacket(kind: "echo", applicationID: "notes"))
        XCTAssertEqual(link.state, .connected(.remote)); XCTAssertEqual(application?.handled, 1)
    }
    @MainActor func testClosingDuringDiscoveryNeverFallsBack() async throws {
        let started = expectation(description: "discovery started")
        let pairing = try Pairing(host: "127.0.0.1", port: 1, key: Pairing.newKey(), nearbyService: UUID().uuidString)
        let link = CompanionLink(pairing: pairing) { _ in
            started.fulfill(); try await Task.sleep(for: .seconds(60)); throw CompanionError.timeout
        }
        var remoteAttempts = 0
        link.onState = { if $0 == .connectingRemote { remoteAttempts += 1 } }
        let connection = Task { try await link.connect() }
        await fulfillment(of: [started], timeout: 1)
        link.close()
        do { try await connection.value; XCTFail("closed connection succeeded") } catch { }
        XCTAssertEqual(remoteAttempts, 0); XCTAssertEqual(link.state, .disconnected)
    }
    @MainActor func testDeviceConnectionDoesNotRequireApplicationHealth() async throws {
        let key = try Pairing.newKey(), registry = ApplicationRegistry()
        registry.register(.quenda) { QuendaApplicationSession(gateway: URL(string: "http://127.0.0.1:1")!, emit: $0) }
        let server = try RelayServer(registry: registry, host: "127.0.0.1", port: 0, key: key)
        try await server.start(); defer { server.stop() }
        let pairing = try Pairing(host: "127.0.0.1", port: server.port, key: key)
        let store = DeviceConnectionStore(pairing: pairing); defer { store.suspend() }
        await store.resume()
        XCTAssertTrue(store.connected); XCTAssertEqual(store.applications.map(\.id), ["quenda"])
        let backend = Backend(link: try XCTUnwrap(store.link)); defer { backend.close() }
        do { try await backend.connect(); XCTFail("offline Quenda accepted") } catch { }
        XCTAssertTrue(store.connected)
        _ = try await store.link?.applications()
        store.suspend(); XCTAssertFalse(store.connected)
    }
    @MainActor func testQuendaConfigurationMigrationAndNamespace() throws {
        let suite = "companion-tests-\(UUID().uuidString)"
        let isolated = UserDefaults(suiteName: suite)!
        defer { isolated.removePersistentDomain(forName: suite) }
        isolated.set("http://127.0.0.1:4321", forKey: "gateway")
        isolated.set("untouched", forKey: "app.transcription.model")
        let configuration = QuendaConfiguration(defaults: isolated)
        XCTAssertEqual(configuration.gateway, "http://127.0.0.1:4321")
        configuration.gateway = "http://127.0.0.1:5432"; configuration.shared = false; configuration.defaultAgent = "local-agent"
        try configuration.save()
        let restored = QuendaConfiguration(defaults: isolated)
        XCTAssertFalse(restored.shared); XCTAssertEqual(restored.defaultAgent, "local-agent")
        XCTAssertEqual(restored.gateway, "http://127.0.0.1:5432")
        XCTAssertEqual(isolated.string(forKey: "app.transcription.model"), "untouched")
    }
}
