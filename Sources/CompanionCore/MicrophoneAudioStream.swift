import Foundation

public enum MicrophoneEvent: Sendable {
    case audio(Data)
    case interrupted
    case waiting
    case resumed
}

/// Bounded microphone data and ordered lifecycle markers, shared with recovery tests.
public final class MicrophoneAudioStream: @unchecked Sendable {
    public init() {}
    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<MicrophoneEvent, Error>.Continuation?
    private var samples: [Float] = []
    private var running = false
    private var lastEnd = Date()
    private var pcm: (@Sendable (Data, Date) -> Void)?
    private var level: (@Sendable (Float) -> Void)?
    public var pcmHandler: (@Sendable (Data, Date) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return pcm }
        set { lock.lock(); pcm = newValue; lock.unlock() }
    }
    public var levelHandler: (@Sendable (Float) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return level }
        set { lock.lock(); level = newValue; lock.unlock() }
    }
    public func open(capacity: Int) -> AsyncThrowingStream<MicrophoneEvent, Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingOldest(capacity)) { continuation in
            lock.lock(); self.continuation = continuation; samples = []; running = false; lock.unlock()
        }
    }
    public func resume() { lock.lock(); running = true; yield(.resumed); lock.unlock() }
    public func event(_ event: MicrophoneEvent) { lock.lock(); yield(event); lock.unlock() }
    public func append(_ chunk: [Float], end: Date) {
        lock.lock(); defer { lock.unlock() }
        guard running else { return }
        lastEnd = end; samples.append(contentsOf: chunk)
        level?(sqrt(chunk.reduce(Float(0)) { $0 + $1 * $1 } / Float(max(1, chunk.count))))
        while samples.count >= 2560 {
            let data = VoicePCM.encode(Array(samples.prefix(2560))); samples.removeFirst(2560)
            pcm?(data, end.addingTimeInterval(-Double(samples.count) / 16000))
            yield(.audio(data))
        }
    }
    public func suspend() {
        lock.lock(); defer { lock.unlock() }
        if running, !samples.isEmpty {
            let data = VoicePCM.encode(samples); pcm?(data, lastEnd); yield(.audio(data))
        }
        samples = []; running = false
    }
    public func discardPending() { lock.lock(); samples = []; lock.unlock() }
    public func finish() { lock.lock(); running = false; continuation?.finish(); continuation = nil; lock.unlock() }
    public func fail(_ error: Error) { lock.lock(); running = false; continuation?.finish(throwing: error); continuation = nil; lock.unlock() }
    private func yield(_ event: MicrophoneEvent) {
        if case .dropped = continuation?.yield(event) {
            running = false; continuation?.finish(throwing: CompanionError.server("音频处理跟不上采集，记录已暂停。")); continuation = nil
        }
    }
}
