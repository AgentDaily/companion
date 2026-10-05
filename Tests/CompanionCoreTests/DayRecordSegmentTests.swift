import XCTest
import AVFoundation
import SoundAnalysis
import SwiftUI
@testable import CompanionCore
import CompanionUI

final class DayRecordSegmentTests: XCTestCase {
    func testSilenceNeverUploadsAndPauseDropsSilenceOnlyContext() throws {
        var gate = DayRecordSegmenter()
        for i in 0..<900 { XCTAssertTrue(try gate.append(Data(repeating: 0, count: 5120), speech: false, end: Date(timeIntervalSince1970: Double(i))).isEmpty) }
        XCTAssertEqual(gate.seconds, 0); XCTAssertNil(gate.flush())
    }
    func testLongSpeechIsCutAtSixtySecondsWithoutMissingOrDuplicatingSamples() throws {
        var gate = DayRecordSegmenter(), segments: [DayRecordAudioSegment] = []
        let data = VoicePCM.encode(Array(repeating: 0.2, count: 2560))
        for i in 0..<800 { segments += try gate.append(data, speech: true, end: Date(timeIntervalSince1970: Double(i + 1) * 0.16)) }
        if let tail = gate.flush() { segments.append(tail) }
        XCTAssertEqual(segments.map(\.seconds), [60,60,8])
        XCTAssertEqual(segments.reduce(0) { $0 + $1.audio.count }, 800 * data.count)
        XCTAssertEqual(segments[1].date.timeIntervalSince(segments[0].date), 60, accuracy: 0.001)
        for segment in segments {
            var command = DayRecordRequest("segment"); command.segment = segment
            XCTAssertLessThanOrEqual(try FrameCodec.encode(command.packet()).count, FrameCodec.maximumSize + 4)
        }
    }
    func testThreeSecondPauseFlushAndShortPauseDoesNotSplit() throws {
        var gate = DayRecordSegmenter()
        let second = Data(repeating: 1, count: 32000)
        _ = try gate.append(second, speech: true, end: Date())
        _ = try gate.append(second, speech: false, end: Date())
        _ = try gate.append(second, speech: false, end: Date())
        XCTAssertTrue(try gate.append(second, speech: true, end: Date()).isEmpty)
        XCTAssertTrue(try gate.append(second, speech: false, end: Date()).isEmpty)
        XCTAssertTrue(try gate.append(second, speech: false, end: Date()).isEmpty)
        let sent = try gate.append(second, speech: false, end: Date())
        XCTAssertEqual(sent.count, 1); XCTAssertEqual(sent[0].seconds, 7); XCTAssertNil(gate.flush())
    }
    func testManualPauseFlushesPartialAndResetDropsDisconnectedAudio() throws {
        var gate = DayRecordSegmenter()
        let chunk = Data(repeating: 2, count: 5120)
        _ = try gate.append(chunk, speech: true, end: Date())
        XCTAssertEqual(gate.flush()?.audio, chunk); XCTAssertNil(gate.flush())
        _ = try gate.append(chunk, speech: true, end: Date()); gate.reset(); XCTAssertNil(gate.flush())
    }
    func testAppleSpeechClassifierAcceptsOnDeviceAudioWithoutFiles() async throws {
        let detector = SpeechActivityDetector(); try await detector.prepare()
        for _ in 0..<12 { _ = try await detector.speech(in: Data(repeating: 0, count: 5120)) }
        if let fixture = ProcessInfo.processInfo.environment["R24_SPEECH_FIXTURE"] {
            let file = try AVAudioFile(forReading: URL(fileURLWithPath: fixture))
            XCTAssertEqual(file.processingFormat.sampleRate, 16000)
            XCTAssertEqual(file.processingFormat.channelCount, 1)
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 2560)!
            var speechFrames = 0
            while file.framePosition < file.length {
                try file.read(into: buffer, frameCount: 2560)
                let samples = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
                if try await detector.speech(in: VoicePCM.encode(samples)) { speechFrames += 1 }
            }
            XCTAssertGreaterThan(speechFrames, 0, "Known speech must open the upload gate")
        }
    }
    func testAnalysisFailureDoesNotStopCapture() async throws {
        let detector = SpeechActivityDetector()
        try await detector.prepare()
        let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
        detector.request(request, didFailWithError: NSError(domain: "com.apple.SoundAnalysis", code: 2,
            userInfo: [NSLocalizedDescriptionKey: "Error during analysis"]))
        // This is the same awaited call inside the phone microphone loop. A throw
        // exits that loop and stops the microphone, even though capture still works.
        var segmenter = DayRecordSegmenter()
        for _ in 0..<25 {
            let audio = Data(repeating: 0, count: 5120)
            let speech = try await detector.speech(in: audio)
            XCTAssertTrue(try segmenter.append(audio, speech: speech, end: Date()).isEmpty)
        }
        XCTAssertNil(segmenter.flush(), "Recovery must not upload silence as speech")
    }
    func testCPUDetectionKeepsSpeechAndFlushesAfterSilence() async throws {
        let detector = SpeechActivityDetector(backend: .webRTC)
        try await detector.prepare()
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/vad-speech16.wav")
        let file = try AVAudioFile(forReading: path)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 2560)!
        var gate = DayRecordSegmenter(), segments: [DayRecordAudioSegment] = []
        var voicedFrames = 0
        while file.framePosition < file.length {
            try file.read(into: buffer, frameCount: 2560)
            let samples = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
            let audio = VoicePCM.encode(samples)
            let speech = try await detector.speech(in: audio)
            if speech { voicedFrames += 1 }
            segments += try gate.append(audio, speech: speech, end: Date())
        }
        XCTAssertGreaterThan(voicedFrames, 10, "Real speech must be detected on the CPU-only phone path")
        for _ in 0..<40 {
            let audio = Data(repeating: 0, count: 5120)
            let speech = try await detector.speech(in: audio)
            segments += try gate.append(audio, speech: speech, end: Date())
        }
        XCTAssertFalse(segments.isEmpty, "Speech must still produce uploads after returning to silence")
        XCTAssertNil(gate.flush(), "Silence must close the speech segment instead of opening new segments")
        XCTAssertTrue(segments.allSatisfy { $0.seconds <= 60 })
    }
    @MainActor func testNativeVisualSnapshot() throws {
        guard let directory = ProcessInfo.processInfo.environment["R24_UI_SNAPSHOT"] else { throw XCTSkip("Optional native SwiftUI render") }
        let root = URL(fileURLWithPath: directory)
        let library = DayRecordLibrary(directory: root.appendingPathComponent("fixture"))
        let store = DayRecordStore(library: library)
        let view = DayRecordView(store: store).frame(width: 1120, height: 850)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 1120, height: 850)
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { XCTFail("No SwiftUI render"); return }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { XCTFail("No PNG"); return }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try png.write(to: root.appendingPathComponent("24r-native-mac.png"))
    }
}
