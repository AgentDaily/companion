import Foundation

public struct DayRecordAudioSegment: Codable, Sendable {
    public let id: String
    public let date: Date
    public let audio: Data
    public var seconds: Double { Double(audio.count) / 32000 }
    public init(id: String = UUID().uuidString, date: Date, audio: Data) { self.id = id; self.date = date; self.audio = audio }
}

/// Only transient PCM. Two seconds of context compensate for the local classifier's window;
/// they are never written to retained clips. A network segment never exceeds sixty seconds.
public struct DayRecordSegmenter {
    public static let maximumBytes = 60 * 32000
    public static let silenceBytes = 3 * 32000
    private var context = Data()
    private var pending = Data()
    private var quietBytes = 0
    private var start: Date?
    public var seconds: Double { Double(pending.count) / 32000 }
    public init() {}
    public mutating func reset() { context.removeAll(); pending.removeAll(); quietBytes = 0; start = nil }
    public mutating func append(_ audio: Data, speech: Bool, end: Date) throws -> [DayRecordAudioSegment] {
        guard !audio.isEmpty, audio.count <= 32000, audio.count % 2 == 0 else { throw CompanionError.invalidFrame }
        if start == nil {
            guard speech else {
                context.append(audio); if context.count > 64000 { context.removeFirst(context.count - 64000) }; return []
            }
            pending = context; context.removeAll()
            start = end.addingTimeInterval(-Double(pending.count + audio.count) / 32000)
        }
        pending.append(audio); quietBytes = speech ? 0 : quietBytes + audio.count
        var result: [DayRecordAudioSegment] = []
        if pending.count >= Self.maximumBytes {
            let date = start!
            result.append(DayRecordAudioSegment(date: date, audio: Data(pending.prefix(Self.maximumBytes))))
            pending.removeFirst(Self.maximumBytes); start = date.addingTimeInterval(60)
            if pending.isEmpty { start = nil }; quietBytes = 0
        }
        if quietBytes >= Self.silenceBytes, let segment = flush() { result.append(segment) }
        return result
    }
    public mutating func flush() -> DayRecordAudioSegment? {
        defer { reset() }
        guard let start, !pending.isEmpty else { return nil }
        return DayRecordAudioSegment(date: start, audio: pending)
    }
}
