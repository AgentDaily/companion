import Foundation
import CoreML

/// Bundled Silero VAD. Explicit CPU-only execution keeps the phone's recording
/// path independent of GPU availability when locked or behind another app.
final class NeuralSpeechDetector {
    private let model: MLModel
    private var hidden: MLMultiArray
    private var cell: MLMultiArray
    private var context = Array(repeating: Float(0), count: 64)
    private var pending: [Float] = []
    private var onsetFrames = 0
    private var active = false

    init() throws {
#if SWIFT_PACKAGE
        let bundle = Bundle.module
#else
        let bundle = Bundle.main
#endif
        guard let url = bundle.url(forResource: "silero_vad", withExtension: "mlmodelc") else {
            throw CompanionError.server("缺少本机人声检测模型，请重新安装 Companion。")
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuOnly
        model = try MLModel(contentsOf: url, configuration: configuration)
        hidden = try Self.zeroState(); cell = try Self.zeroState()
    }
    private static func zeroState() throws -> MLMultiArray {
        let state = try MLMultiArray(shape: [1, 1, 128], dataType: .float16)
        state.dataPointer.assumingMemoryBound(to: Float16.self).update(repeating: 0, count: 128)
        return state
    }
    func speech(in pcm: Data) throws -> Bool {
        guard !pcm.isEmpty, pcm.count <= 32000, pcm.count % 2 == 0 else { throw CompanionError.invalidFrame }
        pending += try VoicePCM.decode(pcm)
        var consumed = 0, detected = false
        while pending.count - consumed >= 512 {
            let chunk = Array(pending[consumed..<consumed + 512])
            let probability = try predict(context + chunk)
            context = Array(chunk.suffix(64)); consumed += 512
            if probability < 0.35 {
                onsetFrames = 0; active = false
            } else if probability >= 0.5 || onsetFrames > 0 {
                onsetFrames = min(8, onsetFrames + 1)
                if onsetFrames >= 8 { active = true } // 256 ms confirmed onset.
            }
            detected = detected || active
        }
        pending.removeFirst(consumed)
        return consumed > 0 ? detected : active
    }
    private func predict(_ samples: [Float]) throws -> Float {
        try autoreleasepool {
            let audio = try MLMultiArray(shape: [1, 1, 576], dataType: .float16)
            let pointer = audio.dataPointer.assumingMemoryBound(to: Float16.self)
            for i in samples.indices { pointer[i] = Float16(samples[i]) }
            let input = try MLDictionaryFeatureProvider(dictionary: ["audio": audio, "h": hidden, "c": cell])
            let output = try model.prediction(from: input)
            guard let nextHidden = output.featureValue(for: "h_out")?.multiArrayValue,
                  let nextCell = output.featureValue(for: "c_out")?.multiArrayValue,
                  let value = output.featureValue(for: "probability")?.multiArrayValue else {
                throw CompanionError.server("人声检测模型返回格式不正确。")
            }
            hidden = nextHidden; cell = nextCell
            let probability = value[0].floatValue
            guard probability.isFinite else { throw CompanionError.invalidFrame }
            return probability
        }
    }
}
