import XCTest
@testable import CompanionCore

final class MicrophoneSessionOwnershipTests: XCTestCase {
    @MainActor func testOpeningAndClosingIdleQuendaVoiceCannotDeactivate24RCapture() throws {
        let session = MicrophoneSessionOwnership(), recorder = UUID(), chatVoice = UUID()
        var active = false
        try session.activate(owner: recorder) { active = true }
        // ConversationView enters/leaves by cancelling its idle PhoneVoiceStore.
        for _ in 0..<3 { session.release(owner: chatVoice) { active = false } }
        XCTAssertTrue(active, "Idle Quenda voice cleanup stopped 24R's shared audio session")
        session.release(owner: recorder) { active = false }
        XCTAssertFalse(active)
    }
    @MainActor func testSecondRecorderCannotReconfigureAudioAndOwnerCanRecover() throws {
        let session = MicrophoneSessionOwnership(), recorder = UUID(), chatVoice = UUID()
        var activations = 0
        try session.activate(owner: recorder) { activations += 1 }
        XCTAssertThrowsError(try session.activate(owner: chatVoice) { XCTFail("Second recorder changed the shared session") })
        session.release(owner: chatVoice) { XCTFail("Failed start deactivated the owner") }
        // Interruption recovery belongs to the original recorder.
        try session.activate(owner: recorder) { activations += 1 }
        XCTAssertEqual(activations, 2)
        session.release(owner: recorder) {}
        try session.activate(owner: chatVoice) { activations += 1 }
        session.release(owner: recorder) { XCTFail("Late cleanup deactivated the new recorder") }
        XCTAssertEqual(activations, 3)
    }
    @MainActor func testFailedActivationAndRepeatedStopDoNotRetainOwnership() throws {
        let session = MicrophoneSessionOwnership(), recorder = UUID(), chatVoice = UUID()
        XCTAssertThrowsError(try session.activate(owner: recorder) { throw CompanionError.disconnected })
        try session.activate(owner: chatVoice) {}
        var releases = 0
        session.release(owner: chatVoice) { releases += 1 }
        session.release(owner: chatVoice) { releases += 1 }
        XCTAssertEqual(releases, 1)
        try session.activate(owner: recorder) {}
    }
}
