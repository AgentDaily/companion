import Foundation

/// Explicit opt-in sink. No file exists until start() succeeds; no pre-trigger samples enter it.
public final class RetainedAudio: @unchecked Sendable {
    private let lock = NSLock()
    private var handle: FileHandle?
    private var started = Date.distantFuture
    private var deadline = Date.distantPast
    private var bytes: UInt32 = 0
    public init() {}
    deinit { try? stop() }
    public func start(directory: URL, seconds: Int, now: Date = Date()) throws -> URL {
        lock.lock(); defer { lock.unlock() }
        guard handle == nil, (1...900).contains(seconds) else { throw CompanionError.server("音频已在保留中，或时长无效。") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var directory = directory; var values = URLResourceValues(); values.isExcludedFromBackup = true; try directory.setResourceValues(values)
        let url = directory.appendingPathComponent(UUID().uuidString + ".wav")
        guard FileManager.default.createFile(atPath: url.path, contents: Self.header(0), attributes: [.posixPermissions: 0o600]) else { throw CompanionError.server("无法创建保留片段。") }
#if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
#endif
        handle = try FileHandle(forUpdating: url); try handle?.seekToEnd(); bytes = 0; started = now; deadline = now.addingTimeInterval(Double(seconds))
        return url
    }
    public func append(_ data: Data, capturedAt end: Date) throws {
        lock.lock(); defer { lock.unlock() }
        guard let handle else { return }
        let begin = end.addingTimeInterval(-Double(data.count) / 32000)
        guard begin >= started, begin < deadline else { return }
        let count = min(data.count, max(0, Int(deadline.timeIntervalSince(begin) * 16000)) * 2)
        guard count > 0 else { return }
        try handle.seekToEnd(); try handle.write(contentsOf: data.prefix(count)); bytes += UInt32(count)
        // Keep even an interrupted explicit recording playable.
        try handle.seek(toOffset: 0); try handle.write(contentsOf: Self.header(bytes))
    }
    public func stop() throws {
        lock.lock(); defer { lock.unlock() }
        let old = handle; handle = nil
        try old?.synchronize(); try old?.close()
    }
    private static func header(_ bytes: UInt32) -> Data {
        var d = Data("RIFF".utf8)
        func u32(_ n: UInt32) { var n = n.littleEndian; withUnsafeBytes(of: &n) { d.append(contentsOf: $0) } }
        func u16(_ n: UInt16) { var n = n.littleEndian; withUnsafeBytes(of: &n) { d.append(contentsOf: $0) } }
        u32(bytes + 36); d.append(Data("WAVEfmt ".utf8)); u32(16); u16(1); u16(1); u32(16000); u32(32000); u16(2); u16(16); d.append(Data("data".utf8)); u32(bytes); return d
    }
}
