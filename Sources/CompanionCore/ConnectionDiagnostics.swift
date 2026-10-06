import Foundation

/// Bounded transport-only diagnostics: never record endpoints, pairing keys,
/// application requests, transcripts, or message bodies.
@MainActor public final class ConnectionDiagnostics {
    public static var shared = ConnectionDiagnostics()
    public struct Entry: Codable, Equatable {
        public let time: Date
        public let stage: String
        public let detail: String
    }
    public private(set) var entries: [Entry] = []
    private let file: URL?
    public init(file: URL? = nil) { self.file = file }
    public static func persisted() -> ConnectionDiagnostics {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return ConnectionDiagnostics(file: root.appendingPathComponent("Companion/connection-diagnostics.json"))
    }
    public func record(_ stage: String, _ detail: String = "") {
        entries.append(Entry(time: Date(), stage: stage, detail: detail))
        entries = Array(entries.suffix(240))
        guard let file else { return }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(entries).write(to: file, options: .atomic)
        } catch { /* Diagnostics must never prevent connection or recording. */ }
    }
    public var summary: String {
        entries.map { "\($0.time.formatted(date: .omitted, time: .standard)) \($0.stage) \($0.detail)" }.joined(separator: "\n")
    }
}
