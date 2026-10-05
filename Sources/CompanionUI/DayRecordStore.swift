import Foundation
import Combine
import CompanionCore

@MainActor public final class DayRecordStore: ObservableObject {
    public let library: DayRecordLibrary
    @Published public var date = Date()
    @Published public private(set) var entries: [DayRecordEntry] = []
    @Published public private(set) var days: [String] = []
    @Published public var settings = DayRecordSettings()
    @Published public var status = "文字与报告保存在这台设备"
    @Published public var error: String?
    @Published public private(set) var busy = false
    @Published public private(set) var online = false
    public var day: String { DayRecordLibrary.day(date) }
    private var request: ((DayRecordRequest) async throws -> DayRecordReply)?
    private var localService = false
    private var syncedVersions: [String: String] = [:]
    private var lastToday = DayRecordLibrary.day(Date())
    private var observation: AnyCancellable?
    public init(library: DayRecordLibrary? = nil) {
        let library = library ?? DayRecordLibrary()
        self.library = library
        do { settings = try library.settings() } catch { self.error = error.localizedDescription }
        observation = library.$revision.dropFirst().sink { [weak self] _ in Task { @MainActor in self?.reload() } }
        reload()
    }
#if os(macOS)
    public convenience init(service: DayRecordService) {
        self.init(library: service.library)
        request = { try await service.handle($0) }; settings = service.settings; online = true; localService = true
    }
#endif
    public func attach(link: CompanionLink?) {
        online = link != nil
        if let link { request = { try await Self.send($0, link: link) } } else { request = nil }
    }
    public static func send(_ request: DayRecordRequest, link: CompanionLink) async throws -> DayRecordReply {
        let reply = try await link.request(request.packet(), timeout: ["report", "organize", "test"].contains(request.action) ? .seconds(900) : .seconds(120))
        guard reply.error == nil, reply.status == 200, let body = reply.body else { throw CompanionError.server(reply.error ?? "24R 未返回有效响应。") }
        return try JSONDecoder().decode(DayRecordReply.self, from: body)
    }
    public func reload() {
        do { entries = try library.entries(day: day); days = library.days() }
        catch { self.error = "本地文字读取失败：\(error.localizedDescription)" }
    }
    public func refresh(allDays: Bool = false) async {
        let today = DayRecordLibrary.day(Date())
        if day == lastToday && today != lastToday { date = Date() }; lastToday = today
        guard !busy, let request else { reload(); return }
        busy = true; defer { busy = false }
        do {
            let catalog = try await request(DayRecordRequest("catalog"))
            if let settings = catalog.settings { try library.save(settings: settings); self.settings = settings }
            status = catalog.message
            if localService { error = nil; reload(); days = catalog.days; return }
            let targets = (allDays ? catalog.days : [day]).filter { syncedVersions[$0] != catalog.versions[$0] || !library.days().contains($0) }
            for day in targets {
                var offset = 0
                var snapshot: [DayRecordEntry] = []
                repeat {
                    let reply = try await request(DayRecordRequest("sync", day: day, offset: offset))
                    snapshot += reply.entries
                    guard let next = reply.next else { break }
                    guard next > offset else { throw CompanionError.invalidFrame }; offset = next
                } while !Task.isCancelled
                if !Task.isCancelled { try library.replace(snapshot, day: day); syncedVersions[day] = catalog.versions[day] }
            }
            error = nil; reload(); days = Array(Set(days + catalog.days)).sorted(by: >)
        } catch { self.error = error.localizedDescription }
    }
    public func save(_ settings: DayRecordSettings, key: String?) async -> Bool {
        guard let request, !busy else { error = "连接 Mac 后保存设置。"; return false }
        busy = true; defer { busy = false }
        do {
            let reply = try await request(DayRecordRequest("settings", settings: settings, apiKey: key))
            let confirmed = reply.settings ?? settings
            try library.save(settings: confirmed); self.settings = confirmed; status = reply.message; error = nil; return true
        } catch { self.error = error.localizedDescription; return false }
    }
    public func completeTask(_ report: DayRecordEntry, text: String, completed: Bool) async {
        guard let request, !busy else { return }
        busy = true; defer { busy = false }
        do {
            var command = DayRecordRequest("task", day: day); command.taskText = text; command.completed = completed
            let reply = try await request(command); try library.merge(reply.entries, day: day); reload()
        } catch { self.error = error.localizedDescription }
    }
    public func taskCompleted(report: DayRecordEntry, text: String) -> Bool {
        entries.first { $0.id == DayRecordEntry.taskID(report: report.id, text: text) }?.completed ?? false
    }
    public func source(for id: String) -> DayRecordEntry? {
        if let entry = entries.first(where: { $0.id.caseInsensitiveCompare(id) == .orderedSame }) { return entry }
        // Historical report/hour IDs contain their day; load only that day's local text.
        guard let range = id.range(of: #"\d{4}-\d{2}-\d{2}"#, options: .regularExpression),
              let records = try? library.entries(day: String(id[range])) else { return nil }
        return records.first { $0.id == id }
    }
    public func exportReport(_ report: DayRecordEntry) -> String {
        report.text.components(separatedBy: .newlines).map { line in
            guard let text = DayRecordEntry.taskText(line) else { return line }
            return (taskCompleted(report: report, text: text) ? "- [x] " : "- [ ] ") + text
        }.joined(separator: "\n")
    }
    public func perform(_ action: String) async {
        guard let request, !busy else { return }
        busy = true; error = nil; status = "正在处理…"
        do {
            var reply = try await request(DayRecordRequest(action, day: day))
            status = reply.message
            while reply.processing && !Task.isCancelled {
                try await Task.sleep(for: .seconds(2))
                reply = try await request(DayRecordRequest("catalog")); status = reply.message
            }
        }
        catch { self.error = error.localizedDescription }
        busy = false
        if action != "test" { await refresh() }
    }
}
