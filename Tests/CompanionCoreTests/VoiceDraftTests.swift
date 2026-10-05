import XCTest
@testable import CompanionCore

@MainActor private final class DraftEngine: VoiceTranscriptionEngine {
    var owner: String?
    var captures = 0
    var insertions = 0
    var transcriptions = 0
    var delay = false
    var finalizing = false
    var voiceStatus: VoiceStatus { VoiceStatus(ready: true, busy: owner != nil, message: "cursor") }
    var transcriptionStatus: VoiceStatus { VoiceStatus(ready: true, busy: owner != nil, message: "draft", supportsDraft: true) }
    func partialTranscription(session: String) -> String? { owner == session ? "帮我分析" : nil }
    func startVoice(session: String) throws { captures += 1; owner = session }
    func startTranscription(session: String) throws { owner = session }
    func pushVoice(session: String, samples: [Float]) async throws { guard owner == session else { throw CompanionError.disconnected } }
    func finishVoice(session: String) async throws { guard owner == session else { throw CompanionError.disconnected }; insertions += 1; owner = nil }
    func finishTranscription(session: String) async throws -> String {
        finalizing = true
        if delay { try await Task.sleep(for: .milliseconds(80)) }
        guard owner == session else { throw CompanionError.disconnected }
        transcriptions += 1; owner = nil
        return "帮我分析这份资料。"
    }
    func cancelVoice(session: String) { if owner == session { owner = nil } }
}

@MainActor private final class CursorOnlyEngine: VoiceInputEngine {
    var starts = 0
    var voiceStatus: VoiceStatus { VoiceStatus(ready: true, message: "cursor only") }
    func startVoice(session: String) throws { starts += 1 }
    func pushVoice(session: String, samples: [Float]) async throws {}
    func finishVoice(session: String) async throws {}
    func cancelVoice(session: String) {}
}

final class VoiceDraftTests: XCTestCase {
    @MainActor func testDraftReturnsTextOnceWithoutCapturingOrInsertingAtMacCursor() async throws {
        let engine = DraftEngine(), handler = VoiceInputApplicationSession(engine: engine), id = UUID().uuidString
        let statusReply = try await handler.handle(VoiceCommand("status", destination: .draft).packet())
        let status = try JSONDecoder().decode(VoiceStatus.self, from: statusReply.body!)
        XCTAssertEqual(status.supportsDraft, true); XCTAssertNil(status.transcript)
        _ = try await handler.handle(VoiceCommand("start", session: id, destination: .draft).packet())
        let partial = try await handler.handle(VoiceCommand("audio", session: id, audio: VoicePCM.encode([0.2]), destination: .draft).packet())
        XCTAssertEqual(try JSONDecoder().decode(VoiceStatus.self, from: partial.body!).transcript, "帮我分析")
        do { _ = try await handler.handle(VoiceCommand("finish", session: id, sequence: 1).packet()); XCTFail("destination changed during recording") } catch { }
        let reply = try await handler.handle(VoiceCommand("finish", session: id, sequence: 1, destination: .draft).packet())
        XCTAssertEqual(try JSONDecoder().decode(VoiceStatus.self, from: reply.body!).transcript, "帮我分析这份资料。")
        XCTAssertEqual(engine.transcriptions, 1); XCTAssertEqual(engine.captures, 0); XCTAssertEqual(engine.insertions, 0)
        do { _ = try await handler.handle(VoiceCommand("finish", session: id, sequence: 1, destination: .draft).packet()); XCTFail("duplicate finalization") } catch { }
        XCTAssertEqual(engine.transcriptions, 1)
    }
    @MainActor func testCursorModeNeverReturnsTranscriptEvenWithDraftCapableEngine() async throws {
        let engine = DraftEngine(), handler = VoiceInputApplicationSession(engine: engine), id = UUID().uuidString
        _ = try await handler.handle(VoiceCommand("start", session: id).packet())
        let audioReply = try await handler.handle(VoiceCommand("audio", session: id, audio: VoicePCM.encode([0.1])).packet())
        XCTAssertNil(try JSONDecoder().decode(VoiceStatus.self, from: audioReply.body!).transcript)
        do { _ = try await handler.handle(VoiceCommand("finish", session: id, sequence: 1, destination: .draft).packet()); XCTFail("cursor session leaked transcript") } catch { }
        let reply = try await handler.handle(VoiceCommand("finish", session: id, sequence: 1).packet())
        XCTAssertNil(try JSONDecoder().decode(VoiceStatus.self, from: reply.body!).transcript)
        XCTAssertEqual(engine.insertions, 1); XCTAssertEqual(engine.transcriptions, 0)
    }
    @MainActor func testLegacyEngineRejectsDraftBeforeStartingCursorInput() async throws {
        let engine = CursorOnlyEngine(), handler = VoiceInputApplicationSession(engine: engine)
        for action in ["status", "start"] {
            do { _ = try await handler.handle(VoiceCommand(action, session: UUID().uuidString, destination: .draft).packet()); XCTFail("legacy engine accepted draft") } catch { }
        }
        XCTAssertEqual(engine.starts, 0)
    }
    @MainActor func testClosingDuringDraftFinalizationDiscardsResult() async throws {
        let engine = DraftEngine(); engine.delay = true
        let handler = VoiceInputApplicationSession(engine: engine), id = UUID().uuidString
        _ = try await handler.handle(VoiceCommand("start", session: id, destination: .draft).packet())
        _ = try await handler.handle(VoiceCommand("audio", session: id, audio: VoicePCM.encode([0.1]), destination: .draft).packet())
        let finish = Task { try await handler.handle(VoiceCommand("finish", session: id, sequence: 1, destination: .draft).packet()) }
        while !engine.finalizing { await Task.yield() }
        handler.close()
        do { _ = try await finish.value; XCTFail("closed draft returned text") } catch { }
        XCTAssertEqual(engine.transcriptions, 0); XCTAssertEqual(engine.insertions, 0)
    }
}
