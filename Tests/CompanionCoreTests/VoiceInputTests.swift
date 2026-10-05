import XCTest
@testable import CompanionCore

@MainActor private final class FakeVoice: VoiceInputEngine {
    var owner: String?
    var commits = 0
    var cancellations = 0
    var received = 0
    var voiceStatus: VoiceStatus { VoiceStatus(ready: true, busy: owner != nil, message: "ready") }
    func startVoice(session: String) throws {
        guard owner == nil else { throw CompanionError.server("busy") }; owner = session
    }
    func pushVoice(session: String, samples: [Float]) async throws { received += samples.count }
    func finishVoice(session: String) async throws { guard owner == session else { throw CompanionError.disconnected }; commits += 1; owner = nil }
    func cancelVoice(session: String) { if owner == session { cancellations += 1; owner = nil } }
}
final class VoiceInputTests: XCTestCase {
    func testPCMIsLittleEndianClampedAndBounded() throws {
        let data = VoicePCM.encode([0, 1, -1, 2, .nan])
        XCTAssertEqual(Array(data), [0,0,255,127,1,128,255,127,0,0])
        XCTAssertEqual(try VoicePCM.decode(data).count, 5)
        XCTAssertThrowsError(try VoicePCM.decode(Data([1])))
        XCTAssertThrowsError(try VoicePCM.decode(Data(repeating: 0, count: 32002)))
    }
    @MainActor func testFinishCommitsExactlyOnceAndDoesNotReturnText() async throws {
        let engine = FakeVoice(); let handler = VoiceInputApplicationSession(engine: engine); let id = UUID().uuidString
        _ = try await handler.handle(VoiceCommand("start", session: id).packet())
        _ = try await handler.handle(VoiceCommand("audio", session: id, audio: VoicePCM.encode([0.1,0.2])).packet())
        let reply = try await handler.handle(VoiceCommand("finish", session: id, sequence: 1).packet())
        XCTAssertEqual(engine.commits, 1); XCTAssertEqual(engine.received, 2)
        XCTAssertEqual(Set((try JSONSerialization.jsonObject(with: reply.body!) as! [String: Any]).keys), ["ready","busy","message"])
        do { _ = try await handler.handle(VoiceCommand("finish", session: id, sequence: 1).packet()); XCTFail() } catch {}
        XCTAssertEqual(engine.commits, 1)
    }
    @MainActor func testMissingChunkCancelsWithoutCommit() async throws {
        let engine = FakeVoice(); let handler = VoiceInputApplicationSession(engine: engine); let id = UUID().uuidString
        _ = try await handler.handle(VoiceCommand("start", session: id).packet())
        do { _ = try await handler.handle(VoiceCommand("audio", session: id, sequence: 1, audio: VoicePCM.encode([0.2])).packet()); XCTFail() } catch {}
        XCTAssertEqual(engine.commits, 0); XCTAssertEqual(engine.cancellations, 1)
    }
    @MainActor func testDisconnectAndEmptyFinishNeverCommit() async throws {
        let engine = FakeVoice(); let handler = VoiceInputApplicationSession(engine: engine); let id = UUID().uuidString
        _ = try await handler.handle(VoiceCommand("start", session: id).packet()); handler.close()
        XCTAssertEqual(engine.cancellations, 1); XCTAssertEqual(engine.commits, 0)
        let other = VoiceInputApplicationSession(engine: engine); let next = UUID().uuidString
        _ = try await other.handle(VoiceCommand("start", session: next).packet())
        do { _ = try await other.handle(VoiceCommand("finish", session: next).packet()); XCTFail() } catch {}
        XCTAssertEqual(engine.commits, 0); XCTAssertNil(engine.owner)
    }
    @MainActor func testSecondPeerCannotCancelFirstPeer() async throws {
        let engine = FakeVoice(); let first = VoiceInputApplicationSession(engine: engine); let second = VoiceInputApplicationSession(engine: engine)
        let id = UUID().uuidString
        _ = try await first.handle(VoiceCommand("start", session: id).packet())
        do { _ = try await second.handle(VoiceCommand("start", session: UUID().uuidString).packet()); XCTFail() } catch {}
        _ = try await second.handle(VoiceCommand("cancel", session: id).packet()); second.close()
        XCTAssertEqual(engine.owner, id); XCTAssertEqual(engine.cancellations, 0)
        first.close(); XCTAssertEqual(engine.cancellations, 1)
    }
}

@MainActor private final class SlowVoice: VoiceInputEngine {
    var owner: String?
    var finalizing = false
    var commits = 0
    var voiceStatus: VoiceStatus { VoiceStatus(ready: true, busy: owner != nil, message: "ready") }
    func startVoice(session: String) throws { owner = session }
    func pushVoice(session: String, samples: [Float]) async throws {}
    func finishVoice(session: String) async throws {
        finalizing = true
        try await Task.sleep(for: .milliseconds(500))
        guard owner == session else { throw CompanionError.disconnected }; commits += 1; owner = nil
    }
    func cancelVoice(session: String) { if owner == session { owner = nil } }
}
extension VoiceInputTests {
    @MainActor func testApplicationCloseInterruptsFinalizationButKeepsLink() async throws {
        let engine = SlowVoice(), registry = ApplicationRegistry(), key = try Pairing.newKey()
        registry.register(.whisper) { _ in VoiceInputApplicationSession(engine: engine) }
        let server = try RelayServer(registry: registry, host: "127.0.0.1", port: 0, key: key)
        try await server.start(); defer { server.stop() }
        let link = CompanionLink(pairing: try Pairing(host: "127.0.0.1", port: server.port, key: key))
        try await link.connect(); defer { link.close() }
        let id = UUID().uuidString
        _ = try await link.request(VoiceCommand("start", session: id).packet())
        _ = try await link.request(VoiceCommand("audio", session: id, audio: VoicePCM.encode([0.2])).packet())
        let finish = Task { try await link.request(VoiceCommand("finish", session: id, sequence: 1).packet()) }
        for _ in 0..<50 {
            if engine.finalizing { break }; try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(engine.finalizing)
        _ = try await link.request(RelayPacket(kind: "application_close", applicationID: CompanionApplication.whisper.id))
        do { _ = try await finish.value; XCTFail("cancelled finish succeeded") } catch {}
        XCTAssertEqual(engine.commits, 0); XCTAssertNil(engine.owner)
        let catalog = try await link.applications(); XCTAssertEqual(catalog.map(\.id), [CompanionApplication.whisper.id])
    }
    @MainActor func testDisconnectDuringFinalizationDoesNotCommit() async throws {
        let engine = SlowVoice(), registry = ApplicationRegistry(), key = try Pairing.newKey()
        registry.register(.whisper) { _ in VoiceInputApplicationSession(engine: engine) }
        let server = try RelayServer(registry: registry, host: "127.0.0.1", port: 0, key: key)
        try await server.start(); defer { server.stop() }
        let link = CompanionLink(pairing: try Pairing(host: "127.0.0.1", port: server.port, key: key))
        try await link.connect()
        let id = UUID().uuidString
        _ = try await link.request(VoiceCommand("start", session: id).packet())
        _ = try await link.request(VoiceCommand("audio", session: id, audio: VoicePCM.encode([0.2])).packet())
        let finish = Task { try await link.request(VoiceCommand("finish", session: id, sequence: 1).packet()) }
        for _ in 0..<50 { if engine.finalizing { break }; try await Task.sleep(for: .milliseconds(10)) }
        link.close(); _ = try? await finish.value
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(engine.commits, 0); XCTAssertNil(engine.owner)
    }
}
