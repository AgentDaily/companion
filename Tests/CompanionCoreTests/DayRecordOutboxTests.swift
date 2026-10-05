import XCTest
@testable import CompanionCore

final class DayRecordOutboxTests: XCTestCase {
    @MainActor func testOfflineSpeechSurvivesRestartFailureAndAcknowledgement() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = DayRecordAudioSegment(date: Date().addingTimeInterval(-86400), audio: Data(repeating: 3, count: 1_920_000))
        let second = DayRecordAudioSegment(date: Date(), audio: Data(repeating: 5, count: 32000))
        let queue = try DayRecordOutbox(directory: directory)
        try queue.append(first); try queue.append(second); try queue.append(first)
        XCTAssertEqual(queue.count, 2); XCTAssertLessThan(queue.bytes, 1_960_000) // binary payload, no base64 disk overhead
        let restarted = try DayRecordOutbox(directory: directory)
        XCTAssertEqual(try restarted.first()?.audio, first.audio)
        // A failed request / missing acknowledgement keeps the same first segment for retry.
        XCTAssertEqual(try restarted.first()?.id, first.id)
        XCTAssertEqual(try DayRecordOutbox(directory: directory).first()?.id, first.id)
        try restarted.acknowledge(first.id)
        XCTAssertEqual(try restarted.first()?.id, second.id)
        try restarted.acknowledge(second.id)
        XCTAssertEqual(restarted.count, 0); XCTAssertEqual(restarted.bytes, 0)
        XCTAssertNil(try DayRecordOutbox(directory: directory).first())
    }
    @MainActor func testTransportFailureWrongAckAndLocalSaveFailureNeverDeleteAudio() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = try DayRecordOutbox(directory: directory)
        let segment = DayRecordAudioSegment(date: Date(), audio: Data(repeating: 1, count: 32000))
        try queue.append(segment)
        for scenario in 0..<3 {
            do {
                _ = try await queue.deliverFirst(send: { _ in
                    if scenario == 0 { throw CompanionError.invalidFrame }
                    var reply = DayRecordReply(); reply.completedSegmentID = scenario == 1 ? "wrong-id" : segment.id
                    return reply
                }, save: { _ in if scenario == 2 { throw CompanionError.invalidFrame } })
                XCTFail("unacknowledged audio removed")
            } catch { }
            XCTAssertEqual(try DayRecordOutbox(directory: directory).first()?.id, segment.id)
        }
        _ = try await queue.deliverFirst(send: { _ in
            var reply = DayRecordReply(); reply.completedSegmentID = segment.id; reply.transcript = ""; return reply
        }, save: { _ in })
        XCTAssertEqual(queue.count, 0)
    }
    @MainActor func testFullQueueRejectsNewSegmentWithoutDeletingOldAudio() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = try DayRecordOutbox(directory: directory, maximumBytes: 40000)
        let segment = DayRecordAudioSegment(date: Date(), audio: Data(repeating: 1, count: 32000))
        try queue.append(segment)
        XCTAssertThrowsError(try queue.append(DayRecordAudioSegment(date: Date(), audio: segment.audio)))
        XCTAssertEqual(try queue.first()?.id, segment.id); XCTAssertEqual(queue.count, 1)
    }
}
