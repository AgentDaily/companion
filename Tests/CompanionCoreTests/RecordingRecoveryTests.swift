import XCTest
@testable import CompanionCore

@MainActor final class RecordingRecoveryTests: XCTestCase {
    func testVideoInterruptionResumesWithoutNewUserStart() throws {
        var starts = 0, pauses = 0
        var states: [RecordingRecovery.Status] = []
        let recovery = RecordingRecovery(activate: { starts += 1 }, suspend: { pauses += 1 }, changed: { states.append($0) })
        try recovery.start()
        recovery.interruptionBegan()
        XCTAssertTrue(recovery.requested, "System interruption must preserve the user's intent to record")
        recovery.interruptionEnded(shouldResume: true)
        XCTAssertEqual(starts, 2, "Video ending must restart the microphone")
        XCTAssertEqual(pauses, 1)
        XCTAssertEqual(states, [.recording, .interrupted, .recording])
        recovery.stop()
    }
    func testInterruptedStreamKeepsTailAndAcceptsAudioAfterResume() async throws {
        let frames = MicrophoneAudioStream()
        let stream = frames.open(capacity: 24)
        let recovery = RecordingRecovery(activate: {}, suspend: { frames.suspend() }, changed: {
            switch $0 {
            case .recording: frames.resume()
            case .interrupted: frames.event(.interrupted)
            case .waiting: frames.event(.waiting)
            case .stopped: frames.finish()
            }
        })
        let first = Array(repeating: Float(0.25), count: 2577)
        let second = Array(repeating: Float(-0.3), count: 2560)
        try recovery.start()
        frames.append(first, end: Date())
        recovery.interruptionBegan()
        frames.append(Array(repeating: 0, count: 2560), end: Date()) // Not captured during interruption.
        recovery.interruptionEnded(shouldResume: true)
        frames.append(second, end: Date())
        recovery.stop()
        var parts: [Data] = [], markers: [String] = []
        for try await event in stream {
            switch event {
            case .audio(let audio): parts.append(audio); markers.append("audio")
            case .interrupted: markers.append("interrupted")
            case .resumed: markers.append("resumed")
            case .waiting: markers.append("waiting")
            }
        }
        XCTAssertEqual(parts.reduce(Data(), +), VoicePCM.encode(first + second))
        XCTAssertEqual(markers, ["resumed", "audio", "audio", "interrupted", "resumed", "audio"])
    }
    func testManualStopDuringInterruptionPreventsAllAutomaticRestarts() throws {
        var starts = 0
        let recovery = RecordingRecovery(activate: { starts += 1 }, suspend: {}, changed: { _ in })
        try recovery.start(); recovery.interruptionBegan(); recovery.stop()
        recovery.interruptionEnded(shouldResume: true); recovery.foreground()
        XCTAssertEqual(starts, 1); XCTAssertFalse(recovery.requested)
        XCTAssertEqual(recovery.status, .stopped)
    }
    func testNoResumeHintWaitsForForegroundAndDuplicateEndDoesNotRestartAgain() throws {
        var starts = 0
        let recovery = RecordingRecovery(activate: { starts += 1 }, suspend: {}, changed: { _ in })
        try recovery.start(); recovery.interruptionBegan()
        recovery.interruptionEnded(shouldResume: false)
        XCTAssertEqual(starts, 1); XCTAssertEqual(recovery.status, .waiting)
        recovery.foreground()
        recovery.interruptionEnded(shouldResume: true)
        XCTAssertEqual(starts, 2); XCTAssertEqual(recovery.status, .recording)
        recovery.stop()
    }
    func testForegroundRecoversWhenSystemOmitsEndNotification() throws {
        var starts = 0
        let recovery = RecordingRecovery(activate: { starts += 1 }, suspend: {}, changed: { _ in })
        try recovery.start(); recovery.interruptionBegan(); recovery.foreground()
        XCTAssertEqual(starts, 2); XCTAssertEqual(recovery.status, .recording)
        recovery.stop()
    }
    func testTemporaryActivationFailureRetriesWithoutLosingRecordingIntent() async throws {
        var starts = 0
        let resumed = expectation(description: "resumed after temporary audio contention")
        let recovery = RecordingRecovery(activate: {
            starts += 1
            if starts == 2 { throw CompanionError.server("audio still occupied") }
        }, suspend: {}, changed: { if $0 == .recording && starts == 3 { resumed.fulfill() } })
        try recovery.start(); recovery.interruptionBegan(); recovery.interruptionEnded(shouldResume: true)
        XCTAssertTrue(recovery.requested); XCTAssertEqual(recovery.status, .waiting)
        await fulfillment(of: [resumed], timeout: 3)
        XCTAssertEqual(starts, 3); recovery.stop()
    }
    func testManualStopCancelsPendingActivationRetry() async throws {
        var starts = 0
        let recovery = RecordingRecovery(activate: {
            starts += 1
            if starts > 1 { throw CompanionError.server("audio still occupied") }
        }, suspend: {}, changed: { _ in })
        try recovery.start(); recovery.interruptionBegan(); recovery.interruptionEnded(shouldResume: true)
        recovery.stop()
        try await Task.sleep(for: .milliseconds(1200))
        XCTAssertEqual(starts, 2); XCTAssertEqual(recovery.status, .stopped)
    }

}
