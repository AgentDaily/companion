import Foundation

extension CompanionApplication {
    public static let whisper = CompanionApplication(id: "whisper-anywhere", name: "Whisper Anywhere", summary: "用手机麦克风说话，在 Mac 光标处输入文字", symbol: "mic.fill")
}

public enum VoiceDestination: String, Codable, Sendable { case cursor, draft }

public struct VoiceCommand: Codable, Sendable {
    public var action: String
    public var session: String
    public var sequence: Int
    public var audio: Data?
    public var destination: VoiceDestination?
    public var background: Bool? = nil
    public init(_ action: String, session: String = "", sequence: Int = 0, audio: Data? = nil, destination: VoiceDestination? = nil) {
        self.action = action; self.session = session; self.sequence = sequence; self.audio = audio; self.destination = destination
    }
    public func packet() throws -> RelayPacket {
        RelayPacket(kind: "voice", body: try JSONEncoder().encode(self), applicationID: CompanionApplication.whisper.id)
    }
}
public struct VoiceStatus: Codable, Sendable {
    public var ready: Bool
    public var busy: Bool
    public var message: String
    public var supportsLiveTranscript: Bool?
    public var supportsDraft: Bool?
    public var transcript: String?
    public init(ready: Bool, busy: Bool = false, message: String, supportsDraft: Bool? = nil, transcript: String? = nil, supportsLiveTranscript: Bool? = nil) { self.ready = ready; self.busy = busy; self.message = message; self.supportsDraft = supportsDraft; self.transcript = transcript; self.supportsLiveTranscript = supportsLiveTranscript }
}
public enum VoicePCM {
    public static func encode(_ samples: [Float]) -> Data {
        var data = Data(capacity: samples.count * 2)
        for sample in samples {
            let value = Int16((max(-1, min(1, sample.isFinite ? sample : 0)) * 32767).rounded())
            let bits = UInt16(bitPattern: value)
            data.append(UInt8(truncatingIfNeeded: bits)); data.append(UInt8(truncatingIfNeeded: bits >> 8))
        }
        return data
    }
    public static func decode(_ data: Data) throws -> [Float] {
        guard !data.isEmpty, data.count <= 32_000, data.count % 2 == 0 else { throw CompanionError.server("音频块无效。") }
        let bytes = Array(data)
        return stride(from: 0, to: bytes.count, by: 2).map { Float(Int16(bitPattern: UInt16(bytes[$0]) | UInt16(bytes[$0 + 1]) << 8)) / 32768 }
    }
}

@MainActor public protocol VoiceInputEngine: AnyObject {
    var voiceStatus: VoiceStatus { get }
    func startVoice(session: String) throws
    func pushVoice(session: String, samples: [Float]) async throws
    func finishVoice(session: String) async throws
    func cancelVoice(session: String)
}

/// Explicit opt-in: a cursor-only engine must never be used as a draft engine.
@MainActor public protocol VoiceTranscriptionEngine: VoiceInputEngine {
    var transcriptionStatus: VoiceStatus { get }
    func partialTranscription(session: String) -> String?
    func startTranscription(session: String) throws
    func startBackgroundTranscription(session: String) throws
    func finishTranscription(session: String) async throws -> String
}

public extension VoiceTranscriptionEngine {
    func partialTranscription(session: String) -> String? { nil }
    func startBackgroundTranscription(session: String) throws { throw CompanionError.server("此识别引擎尚不支持后台低优先级转写。") }
}

/// Owns one authenticated peer's utterance. Only an explicit, complete finish
/// may insert text; cancellation and disconnection never finalize it.
@MainActor public final class VoiceInputApplicationSession: CompanionApplicationSession {
    private let engine: any VoiceInputEngine
    private var active: String?
    private var finishing: String?
    private var sequence = 0
    private var sampleCount = 0
    private var destination: VoiceDestination = .cursor
    private var closed = false
    private var deadline: Task<Void, Never>?
    public init(engine: any VoiceInputEngine) { self.engine = engine }
    public func handle(_ packet: RelayPacket) async throws -> RelayPacket {
        guard !closed, packet.kind == "voice", let body = packet.body else { throw CompanionError.invalidFrame }
        let command = try JSONDecoder().decode(VoiceCommand.self, from: body)
        let requestedDestination = command.destination ?? .cursor
        var transcript: String?
        if requestedDestination == .draft && !(engine is any VoiceTranscriptionEngine) { throw CompanionError.server("请更新 Mac 上的 Whisper Anywhere，以支持 Quenda 语音输入。") }
        switch command.action {
        case "status": break
        case "start":
            guard active == nil, finishing == nil, UUID(uuidString: command.session) != nil else { throw CompanionError.server("录音会话无效或正在使用。") }
            if requestedDestination == .draft, let transcription = engine as? any VoiceTranscriptionEngine {
                if command.background == true { try transcription.startBackgroundTranscription(session: command.session) }
                else { try transcription.startTranscription(session: command.session) }
            }
            else { try engine.startVoice(session: command.session) }
            destination = requestedDestination
            active = command.session; sequence = 0; sampleCount = 0
            deadline = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 600_000_000_000)
                guard !Task.isCancelled else { return }; self?.cancel()
            }
        case "audio":
            try validate(command)
            do {
                guard command.sequence == sequence, let audio = command.audio else { throw CompanionError.server("音频顺序不完整，请重新录音。") }
                let samples = try VoicePCM.decode(audio)
                guard sampleCount + samples.count <= 16_000 * 600 else { throw CompanionError.server("单次输入最长 10 分钟。") }
                sequence += 1; sampleCount += samples.count
                try await engine.pushVoice(session: command.session, samples: samples)
                guard active == command.session, !closed else { throw CompanionError.disconnected }
                if destination == .draft, let transcription = engine as? any VoiceTranscriptionEngine { transcript = transcription.partialTranscription(session: command.session) }
            } catch { cancel(); throw error }
        case "finish":
            try validate(command)
            guard command.sequence == sequence, sampleCount > 0 else { cancel(); throw CompanionError.server("音频尚未传输完整。") }
            // Remove ownership before awaiting to forbid duplicate finalization.
            active = nil; finishing = command.session
            do {
                if destination == .draft, let transcription = engine as? any VoiceTranscriptionEngine { transcript = try await transcription.finishTranscription(session: command.session) }
                else { try await engine.finishVoice(session: command.session) }
                guard !closed, finishing == command.session, !Task.isCancelled else { throw CompanionError.disconnected }
                finishing = nil; deadline?.cancel(); deadline = nil
            }
            catch { engine.cancelVoice(session: command.session); finishing = nil; deadline?.cancel(); deadline = nil; throw error }
        case "cancel":
            if active == command.session || finishing == command.session { cancel() }
        default: throw CompanionError.server("不支持的语音操作。")
        }
        var status = engine.voiceStatus
        if requestedDestination == .draft, let transcription = engine as? any VoiceTranscriptionEngine {
            status = transcription.transcriptionStatus; status.supportsDraft = true; status.transcript = transcript
        }
        return RelayPacket(kind: "response", body: try JSONEncoder().encode(status), status: 200)
    }
    private func validate(_ command: VoiceCommand) throws {
        guard active == command.session, active != nil, (command.destination ?? .cursor) == destination else { throw CompanionError.server("录音会话已结束。") }
    }
    private func cancel() {
        if let active { engine.cancelVoice(session: active) }
        if let finishing { engine.cancelVoice(session: finishing) }
        finishing = nil
        active = nil; deadline?.cancel(); deadline = nil
    }
    public func close() { closed = true; cancel() }
}
