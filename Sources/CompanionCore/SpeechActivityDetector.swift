import Foundation
import AVFoundation
import SoundAnalysis

/// Serialized local speech detection. 24R on iPhone selects CPU-only processing
/// for the entire recording, so locking the screen does not change compute access.
/// Optional Apple classification falls back to a warm CPU detector after failure.
public final class SpeechActivityDetector: NSObject, SNResultsObserving, @unchecked Sendable {
    private let queue = DispatchQueue(label: "24r.speech-activity", qos: .utility)
    public enum Backend: Sendable { case system, webRTC, silero }
    private let backend: Backend
    private var neural: NeuralSpeechDetector?
    private var analyzer: SNAudioStreamAnalyzer?
    private var cpu: CPUSpeechDetector?
    private let format: AVAudioFormat
    private var position: AVAudioFramePosition = 0
    private let lock = NSLock()
    private var confidence: Double = 0
    private var failure: Error?
    public init(backend: Backend = .system) {
        self.backend = backend
        format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        super.init()
    }
    public func prepare() async throws {
        try await withCheckedThrowingContinuation { (wait: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    if self.backend == .silero {
                        self.neural = try NeuralSpeechDetector(); wait.resume(); return
                    }
                    self.cpu = try CPUSpeechDetector()
                    if self.backend == .system {
                        do {
                            let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
                            guard request.knownClassifications.contains("speech") else { throw CompanionError.invalidFrame }
                            request.windowDuration = CMTime(seconds: 1, preferredTimescale: 16000); request.overlapFactor = 0.5
                            let analyzer = SNAudioStreamAnalyzer(format: self.format)
                            try analyzer.add(request, withObserver: self)
                            self.analyzer = analyzer
                        } catch {
                            self.lock.lock(); self.failure = error; self.lock.unlock()
                        }
                    }
                    wait.resume()
                } catch { wait.resume(throwing: error) }
            }
        }
    }
    public func speech(in pcm: Data) async throws -> Bool {
        try await withCheckedThrowingContinuation { wait in
            queue.async {
                do {
                    if let neural = self.neural { wait.resume(returning: try neural.speech(in: pcm)); return }
                    guard let cpu = self.cpu else { throw CompanionError.server("本机语音检测尚未初始化。") }
                    let cpuSpeech = try cpu.speech(in: pcm)
                    self.lock.lock(); let failed = self.failure != nil; self.lock.unlock()
                    if failed { self.analyzer?.removeAllRequests(); self.analyzer = nil }
                    guard let analyzer = self.analyzer else { wait.resume(returning: cpuSpeech); return }
                    let samples = try VoicePCM.decode(pcm)
                    guard let buffer = AVAudioPCMBuffer(pcmFormat: self.format, frameCapacity: AVAudioFrameCount(samples.count)) else { throw CompanionError.invalidFrame }
                    buffer.frameLength = AVAudioFrameCount(samples.count)
                    samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: $0.count) }
                    analyzer.analyze(buffer, atAudioFramePosition: self.position); self.position += Int64(samples.count)
                    self.lock.lock(); let failedDuringAnalysis = self.failure != nil; let speech = self.confidence >= 0.45; self.lock.unlock()
                    // Failure may arrive during analyze. Never turn classifier failure
                    // into a microphone interruption or treat all audio as speech.
                    wait.resume(returning: failedDuringAnalysis ? cpuSpeech : speech)
                } catch { wait.resume(throwing: error) }
            }
        }
    }
    public func request(_ request: any SNRequest, didProduce result: any SNResult) {
        guard let result = result as? SNClassificationResult else { return }
        let speech = result.classifications.filter { $0.identifier == "speech" || $0.identifier.hasSuffix("_speech") || $0.identifier == "conversation" }.map(\.confidence).max() ?? 0
        lock.lock(); confidence = speech; lock.unlock()
    }
    public func request(_ request: any SNRequest, didFailWithError error: Error) { lock.lock(); failure = error; lock.unlock() }
    public func requestDidComplete(_ request: any SNRequest) {}
}
