import XCTest
import AVFoundation
@testable import CompanionCore

final class SpeechNoiseTests: XCTestCase {
    func testStationaryRoomSoundsDoNotContinuouslyUpload() async throws {
        for sound in ["quiet", "fan", "hum"] {
            let detector = SpeechActivityDetector(backend: .silero)
            try await detector.prepare()
            var gate = DayRecordSegmenter(), count = 0, voiced = 0
            var seed: UInt64 = 73
            var low: Float = 0
            for frame in 0..<750 { // Two minutes, same 160 ms input as the phone.
                var samples: [Float] = []
                for i in 0..<2560 {
                    seed = seed &* 6364136223846793005 &+ 1
                    let noise = Float(Int32(truncatingIfNeeded: seed >> 32)) / Float(Int32.max)
                    low = 0.95 * low + 0.05 * noise
                    let t = Double(frame * 2560 + i) / 16000
                    switch sound {
                    case "quiet": samples.append(noise * 0.0005)
                    case "fan": samples.append(low * 0.06)
                    default: samples.append(Float(sin(2 * .pi * 150 * t) + 0.35 * sin(2 * .pi * 300 * t)) * 0.025 + noise * 0.0005)
                    }
                }
                let data = VoicePCM.encode(samples)
                let speech = try await detector.speech(in: data)
                if speech { voiced += 1 }
                count += try gate.append(data, speech: speech, end: Date()).count
            }
            if gate.flush() != nil { count += 1 }
            XCTAssertEqual(count, 0, "\(sound): \(voiced)/750 frames labeled speech produced \(count) uploads without a speaker")
        }
    }
    func testQuietSpeechWithFanStillUploadsAndStopsAfterSpeakerFinishes() async throws {
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/vad-speech16.wav")
        let file = try AVAudioFile(forReading: path)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        let original = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        // Roughly 31 dB and 11 dB speech-to-fan ratios. A 0.03 gain
        // at this noise level is only 0.65 dB SNR and is a documented limitation.
        for gain: Float in [1, 0.1] {
            let detector = SpeechActivityDetector(backend: .silero)
            try await detector.prepare()
            var gate = DayRecordSegmenter(), segments: [DayRecordAudioSegment] = []
            var seed: UInt64 = 73
            var low: Float = 0
            var speechFrames = 0
            for frame in 0..<450 {
                var samples: [Float] = []
                for i in 0..<2560 {
                    seed = seed &* 6364136223846793005 &+ 1
                    let noise = Float(Int32(truncatingIfNeeded: seed >> 32)) / Float(Int32.max)
                    low = 0.95 * low + 0.05 * noise
                    let source = frame * 2560 + i - 16000 * 5
                    let voice = source >= 0 && source < original.count ? original[source] * gain : 0
                    samples.append(voice + low * 0.015)
                }
                let data = VoicePCM.encode(samples)
                let speech = try await detector.speech(in: data)
                if speech { speechFrames += 1 }
                segments += try gate.append(data, speech: speech, end: Date())
                if frame > 140 { XCTAssertFalse(speech, "Noise after speech must not keep VAD active") }
            }
            XCTAssertGreaterThan(speechFrames, 2, "Quiet voice at gain \(gain) must survive noise rejection")
            XCTAssertFalse(segments.isEmpty, "Detected quiet speech must be sent")
            XCTAssertLessThan(segments.reduce(0) { $0 + $1.seconds }, 20, "Fan must not extend the utterance indefinitely")
            XCTAssertNil(gate.flush())
        }
    }

}
