import Foundation
import Combine
import CryptoKit

public extension CompanionApplication {
    static let dayRecord = CompanionApplication(id: "24r", name: "24R", summary: "记下今天，理清下一步", symbol: "sun.horizon.fill")
}

public struct DayRecordSettings: Codable, Equatable, Sendable {
    public enum Analysis: String, Codable, CaseIterable, Sendable { case ollama, cloud, quenda }
    public var analysis: Analysis = .ollama
    public var ollamaURL = "http://127.0.0.1:11434"
    public var ollamaModel = ""
    public var keepAlive = "5m"
    public var cloudURL = "https://api.openai.com/v1"
    public var cloudModel = ""
    public var agent = ""
    public var provider = ""
    public var agentModel = ""
    public var workspace = ""
    public var historyDays = 30
    public var historyEnabled = false
    public var reportHour = 21
    public var reportMinute = 30
    public var automatic = true
    public var keywordsEnabled = false
    public var keywords = "开始保留音频\nkeep this audio"
    public var retentionMinutes = 5
    public init() {}
    public func validated() throws -> Self {
        guard (0...23).contains(reportHour), (0...59).contains(reportMinute), [1,5,15].contains(retentionMinutes), (1...90).contains(historyDays), ["0", "5m", "30m", "-1"].contains(keepAlive), keywords.count <= 1000,
              [agent, provider, agentModel, workspace, ollamaModel, cloudModel].allSatisfy({ $0.count <= 200 }),
              [agent, workspace].allSatisfy({ $0.isEmpty || RoutePolicy.validSessionID($0) }) else { throw CompanionError.server("24R 设置超出可用范围。") }
        guard provider.isEmpty == agentModel.isEmpty else { throw CompanionError.server("指定 Quenda Provider 时，请同时填写模型；或两项留空跟随 Agent。") }
        _ = try Self.endpoint(ollamaURL); _ = try Self.endpoint(cloudURL)
        return self
    }
    public static func endpoint(_ value: String) throws -> URL {
        guard let c = URLComponents(string: value), ["http", "https"].contains(c.scheme), c.host?.isEmpty == false, c.user == nil, c.password == nil, c.query == nil, c.fragment == nil, value.count <= 2000, let url = c.url else { throw CompanionError.invalidAddress }
        return url
    }
}

public struct DayRecordEntry: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable { case transcript, hour, report, gap, task }
    public var id: String
    public var kind: Kind
    public var date: Date
    public var end: Date
    public var text: String
    public var completed: Bool? = nil
    public var sources: [String]
    public static func taskText(_ line: String) -> String? {
        guard line.hasPrefix("- [ ] ") || line.hasPrefix("- [x] ") || line.hasPrefix("- [X] ") else { return nil }
        return String(line.dropFirst(6))
    }
    public static func taskID(report: String, text: String) -> String {
        "task-" + SHA256.hash(data: Data((report + "\n" + text).utf8)).map { String(format: "%02x", $0) }.joined()
    }
    public init(id: String = UUID().uuidString, kind: Kind, date: Date, end: Date? = nil, text: String, sources: [String] = []) {
        self.id = id; self.kind = kind; self.date = date; self.end = end ?? date; self.text = text; self.sources = sources
    }
}

/// Text-only storage. Audio is deliberately absent from the document/wire schema.
@MainActor public final class DayRecordLibrary: ObservableObject {
    @Published public private(set) var revision = 0
    public let directory: URL
#if os(macOS)
    public let vault: DayRecordVault
#endif
    private var cache: [String: [DayRecordEntry]] = [:]
    private var cacheVersions: [String: String] = [:]
    public init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Companion/24R", isDirectory: true)
#if os(macOS)
        vault = DayRecordVault(configuration: self.directory.appendingPathComponent("vault-location.json"))
        vault.synchronize(self)
#endif
    }
    public static func day(_ date: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"; return f.string(from: date)
    }
    public static func validDay(_ day: String) -> Bool {
        day.count == 10 && day.enumerated().allSatisfy { [4,7].contains($0.offset) ? $0.element == "-" : $0.element.isASCII && $0.element.isNumber }
    }
    public func invalidate() { cache.removeAll(); cacheVersions.removeAll(); revision += 1 }
    func legacyEntries(day: String) throws -> [DayRecordEntry] {
        guard Self.validDay(day) else { throw CompanionError.invalidFrame }
        let file = directory.appendingPathComponent(day + ".json")
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        return try JSONDecoder().decode([DayRecordEntry].self, from: Data(contentsOf: file))
    }
    public func days() -> [String] {
#if os(macOS)
        if vault.configured { return vault.days() }
#endif
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return Set(files.filter { $0.pathExtension == "json" }.map { $0.deletingPathExtension().lastPathComponent }.filter(Self.validDay)).union(cache.keys).sorted(by: >)
    }
    public func versions() -> [String: String] {
        var result: [String: String] = [:]
        for day in days() {
#if os(macOS)
            if vault.configured { result[day] = vault.version(day: day); continue }
#endif
            let attributes = try? FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(day + ".json").path)
            result[day] = "\((attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)-\(attributes?[.size] as? Int ?? 0)"
        }
        return result
    }
    public func entries(day: String) throws -> [DayRecordEntry] {
        guard Self.validDay(day) else { throw CompanionError.invalidFrame }
#if os(macOS)
        if vault.configured {
            let version = vault.version(day: day)
            if version != "unavailable", cacheVersions[day] == version, let cached = cache[day] { return cached }
            let records = try vault.entries(day: day)
            cache[day] = records; cacheVersions[day] = version
            if cache.count > 4 { for key in cache.keys where key != day { cache[key] = nil; cacheVersions[key] = nil; if cache.count <= 4 { break } } }
            return records
        }
#endif
        if let saved = cache[day] { return saved }
        let file = directory.appendingPathComponent(day + ".json")
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        let result = try JSONDecoder().decode([DayRecordEntry].self, from: Data(contentsOf: file))
        cache[day] = result; return result
    }
    public func merge(_ incoming: [DayRecordEntry], day: String) throws {
        guard incoming.allSatisfy({ $0.id.count <= 200 && $0.text.utf8.count <= 160_000 && $0.sources.count <= 3000 && $0.sources.allSatisfy { $0.count <= 300 } }) else { throw CompanionError.invalidFrame }
#if os(macOS)
        if vault.configured {
            guard Self.validDay(day) else { throw CompanionError.invalidFrame }
            try vault.merge(incoming, day: day, library: self)
            cache[day] = nil; cacheVersions[day] = nil; revision += 1; return
        }
#endif
        var records = try entries(day: day)
        for entry in incoming {
            if let index = records.firstIndex(where: { $0.id == entry.id }) { records[index] = entry } else { records.append(entry) }
        }
        records.sort { $0.date == $1.date ? $0.id < $1.id : $0.date < $1.date }
        guard records != cache[day] else { return }
        try Self.write(JSONEncoder().encode(records), to: directory.appendingPathComponent(day + ".json"))
        cache[day] = records; revision += 1
        // A day on disk is the source of truth; avoid retaining months of transcripts in memory.
        if cache.count > 4 { for key in cache.keys where key != day { cache[key] = nil; if cache.count <= 4 { break } } }
    }
    /// Authoritative snapshot from the Mac; deletions must not leave stale phone records behind.
    public func replace(_ records: [DayRecordEntry], day: String) throws {
        guard Self.validDay(day), records.allSatisfy({ $0.text.utf8.count <= 160_000 && $0.id.count <= 200 }) else { throw CompanionError.invalidFrame }
#if os(macOS)
        guard !vault.configured else { throw CompanionError.server("资料库直接读写，不接受镜像快照覆盖。") }
#endif
        try Self.write(JSONEncoder().encode(records), to: directory.appendingPathComponent(day + ".json"))
        cache[day] = records; revision += 1
    }
    public func settings() throws -> DayRecordSettings {
        let file = directory.appendingPathComponent("settings.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return DayRecordSettings() }
        return try JSONDecoder().decode(DayRecordSettings.self, from: Data(contentsOf: file)).validated()
    }
    public func save(settings: DayRecordSettings) throws {
        try Self.write(JSONEncoder().encode(settings.validated()), to: directory.appendingPathComponent("settings.json")); revision += 1
    }
    public static func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
#if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
#endif
    }
}

public struct DayRecordRequest: Codable, Sendable {
    public var action: String
    public var day: String?
    public var offset: Int?
    public var segment: DayRecordAudioSegment? = nil
    public var voice: VoiceCommand?
    public var settings: DayRecordSettings?
    public var taskText: String? = nil
    public var completed: Bool? = nil
    public var apiKey: String?
    public init(_ action: String, day: String? = nil, offset: Int? = nil, voice: VoiceCommand? = nil, settings: DayRecordSettings? = nil, apiKey: String? = nil) {
        self.action = action; self.day = day; self.offset = offset; self.voice = voice; self.settings = settings; self.apiKey = apiKey
    }
    public func packet() throws -> RelayPacket { RelayPacket(kind: "24r", body: try JSONEncoder().encode(self), applicationID: "24r") }
}
public struct DayRecordReply: Codable, Sendable {
    public var entries: [DayRecordEntry] = []
    public var days: [String] = []
    public var next: Int? = nil
    public var settings: DayRecordSettings? = nil
    public var transcript: String? = nil
    public var completedSegmentID: String? = nil
    public var message: String = ""
    public var processing = false
    public var versions: [String: String] = [:]
    public init() {}
}

public enum DayRecordPolicy {
    public static func keyword(in text: String, settings: DayRecordSettings) -> String? {
        guard settings.keywordsEnabled else { return nil }
        return settings.keywords.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.first { phrase in
            guard !phrase.isEmpty else { return false }
            let pattern = NSRegularExpression.escapedPattern(for: phrase)
            let boundary = phrase.allSatisfy({ $0.isASCII })
            return text.range(of: boundary ? "(?i)(?<![a-z0-9])" + pattern + "(?![a-z0-9])" : pattern, options: .regularExpression) != nil
        }
    }
    public static func dueReport(day: Date, now: Date, settings: DayRecordSettings, calendar: Calendar = .current) -> Bool {
        guard let time = calendar.date(bySettingHour: settings.reportHour, minute: settings.reportMinute, second: 0, of: day) else { return false }
        return now >= time
    }
}
