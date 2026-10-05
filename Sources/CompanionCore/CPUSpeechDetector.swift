import Foundation
import CVAD

/// WebRTC's fixed-point VAD. No GPU, Core ML, network, or file access.
/// Owned by the speech detector's serial queue; carries partial 10 ms frames.
final class CPUSpeechDetector {
    private let instance: OpaquePointer
    private var pending: [Int16] = []
    private var lastDecision = false

    init() throws {
        guard let instance = fvad_new() else { throw CompanionError.server("无法初始化本机语音检测。") }
        self.instance = instance
        fvad_set_sample_rate(instance, 16000)
        fvad_set_mode(instance, 2)
    }
    deinit { fvad_free(instance) }

    func speech(in pcm: Data) throws -> Bool {
        guard !pcm.isEmpty, pcm.count % 2 == 0, pcm.count <= 32000 else { throw CompanionError.invalidFrame }
        pcm.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            for offset in stride(from: 0, to: bytes.count, by: 2) {
                pending.append(Int16(bitPattern: UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8))
            }
        }
        var voiced = 0, frames = 0
        try pending.withUnsafeBufferPointer { samples in
            for offset in stride(from: 0, to: pending.count - pending.count % 160, by: 160) {
                let result = fvad_process(instance, samples.baseAddress!.advanced(by: offset), 160)
                guard result >= 0 else { throw CompanionError.invalidFrame }
                voiced += Int(result); frames += 1
            }
        }
        pending.removeFirst(frames * 160)
        // Reject isolated 10 ms transients; short final buffers retain the prior decision.
        if frames > 0 { lastDecision = voiced > 0 && voiced * 4 >= frames }
        return lastDecision
    }
}
