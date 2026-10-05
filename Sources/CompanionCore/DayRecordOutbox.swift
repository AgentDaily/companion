import Foundation
import Combine

/// Durable speech segments. Remove only after the receiver and local text store acknowledge them.
@MainActor public final class DayRecordOutbox: ObservableObject {
    @Published public private(set) var count = 0
    @Published public private(set) var bytes: Int64 = 0
    public let directory: URL
    private var files: [URL] = []
    private let maximumBytes: Int64
    public init(directory: URL, maximumBytes: Int64 = 4_000_000_000) throws {
        self.directory = directory; self.maximumBytes = maximumBytes
        try reload()
    }
    public func reload() throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { files = []; count = 0; bytes = 0; return }
        files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])
            .filter { $0.pathExtension == "segment" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        count = files.count
        bytes = try files.reduce(0) { $0 + Int64(try $1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
    }
    public func append(_ segment: DayRecordAudioSegment) throws {
        guard UUID(uuidString: segment.id) != nil, !segment.audio.isEmpty, segment.audio.count <= DayRecordSegmenter.maximumBytes, segment.audio.count % 2 == 0,
              segment.date.timeIntervalSince1970.isFinite else { throw CompanionError.invalidFrame }
        let file = directory.appendingPathComponent(String(format: "%016lld", Int64(segment.date.timeIntervalSince1970 * 1000)) + "-" + segment.id + ".segment")
        let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
        let data = try encoder.encode(segment)
        if FileManager.default.fileExists(atPath: file.path) {
            guard try Data(contentsOf: file) == data else { throw CompanionError.server("缓存片段 ID 冲突，原音频已保留。") }; return
        }
        guard bytes + Int64(data.count) <= maximumBytes else { throw CompanionError.server("待转写缓存已达 4 GB，采集已暂停；请连接 Mac 先完成转写。已有音频不会删除。") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var root = directory; var values = URLResourceValues(); values.isExcludedFromBackup = true; try root.setResourceValues(values)
        if let available = try directory.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity {
            guard available > data.count + 128_000_000 else { throw CompanionError.server("手机存储不足，采集已暂停；待转写音频仍保留。") }
        }
        try DayRecordLibrary.write(data, to: file)
        files.append(file); files.sort { $0.lastPathComponent < $1.lastPathComponent }; count = files.count; bytes += Int64(data.count)
    }
    public func first() throws -> DayRecordAudioSegment? {
        guard let file = files.first else { return nil }
        let segment = try PropertyListDecoder().decode(DayRecordAudioSegment.self, from: Data(contentsOf: file))
        guard UUID(uuidString: segment.id) != nil, segment.audio.count <= DayRecordSegmenter.maximumBytes, !segment.audio.isEmpty else { throw CompanionError.invalidFrame }
        return segment
    }
    public func acknowledge(_ id: String) throws {
        guard let index = files.firstIndex(where: { $0.lastPathComponent.hasSuffix("-" + id + ".segment") }) else { return }
        let file = files[index], size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        try FileManager.default.removeItem(at: file); files.remove(at: index); count = files.count; bytes = max(0, bytes - Int64(size))
    }
    public func deliverFirst(send: (DayRecordAudioSegment) async throws -> DayRecordReply,
                             save: ([DayRecordEntry]) throws -> Void) async throws -> (DayRecordAudioSegment, DayRecordReply)? {
        guard let segment = try first() else { return nil }
        let reply = try await send(segment)
        guard reply.completedSegmentID == segment.id else { throw CompanionError.server("Mac 尚未确认片段保存，请更新 Mac Companion；音频缓存会保留。") }
        try save(reply.entries)
        try acknowledge(segment.id)
        return (segment, reply)
    }
}
