#if os(macOS)
import Foundation
import Combine

@MainActor public final class DayRecordService: ObservableObject {
    public let library: DayRecordLibrary
    public let analyzer: DayRecordAnalyzer
    @Published public private(set) var settings: DayRecordSettings
    @Published public private(set) var status = "等待手机开始记录"
    @Published public private(set) var analyzing = false
    private var job: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private var retryAfter = Date.distantPast
    public init(library: DayRecordLibrary? = nil, gateway: @escaping () throws -> URL, analyzer: DayRecordAnalyzer? = nil) {
        let library = library ?? DayRecordLibrary()
        self.library = library; self.analyzer = analyzer ?? DayRecordAnalyzer(gateway: gateway)
        do { settings = try library.settings() }
        catch { settings = DayRecordSettings(); status = "设置读取失败：\(error.localizedDescription)" }
    }
    public func start() {
        guard timer == nil else { return }
        timer = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                do { try await Task.sleep(for: .seconds(30)) } catch { break }
            }
        }
    }
    public func stop() { timer?.cancel(); timer = nil; job?.cancel(); job = nil }
    func recordingFailed(_ error: Error) { status = "文字保存失败：\(error.localizedDescription)" }
    public func save(_ value: DayRecordSettings, apiKey: String?) throws {
        let validated = try value.validated()
        if let apiKey { guard apiKey.count <= 8000 else { throw CompanionError.invalidFrame }; try CredentialStore.write(apiKey, account: DayRecordAnalyzer.keyAccount(for: validated.cloudURL)) }
        try library.save(settings: validated); settings = validated; retryAfter = .distantPast
    }
    public func generate(day: String, report: Bool, refreshHours: Bool = false) async throws {
        guard !analyzing else { throw CompanionError.server("正在整理，请稍后查看。") }
        analyzing = true; status = report ? "正在生成一日总结…" : "正在整理小时记录…"
        defer { analyzing = false }
        do {
            let config = settings
            let entries = try library.entries(day: day)
            let transcripts = entries.filter { $0.kind == .transcript }
            guard !transcripts.isEmpty else { throw CompanionError.server("当天还没有文字记录。") }
            let groups = Dictionary(grouping: transcripts) { Calendar.current.dateInterval(of: .hour, for: $0.date)!.start }
            var hours: [DayRecordEntry] = []
            for start in groups.keys.sorted() {
                let records = groups[start]!.sorted { $0.date < $1.date }
                let id = "hour-\(Int(start.timeIntervalSince1970))"
                if !refreshHours, let current = entries.first(where: { $0.id == id && Set($0.sources) == Set(records.map(\.id)) }) { hours.append(current); continue }
                let result = try await analyzer.analyze(config, entries: records, history: [], report: false, progress: { self.status = $0 })
                try Task.checkCancellation()
                let hour = DayRecordEntry(id: id, kind: .hour, date: start, end: records.last?.end, text: result.0, sources: records.map(\.id))
                guard entries.first(where: { $0.id == id }) == (try library.entries(day: day).first { $0.id == id }) else {
                    throw CompanionError.server("生成期间小时摘要已被修改，已保留最新文件，请重新整理。")
                }
                try library.merge([hour], day: day); hours.append(hour)
            }
            if report {
                let history = try relatedHistory(day: day, query: hours.map(\.text).joined(separator: " "), config: config)
                let result = try await analyzer.analyze(config, entries: hours, history: history, report: true, evidence: transcripts, progress: { self.status = $0 })
                try Task.checkCancellation()
                let entry = DayRecordEntry(id: "report-" + day, kind: .report, date: transcripts[0].date, end: Date(), text: result.0, sources: result.1)
                let before = entries.first { $0.id == entry.id }
                let current = try library.entries(day: day).first { $0.id == entry.id }
                guard before == current else { throw CompanionError.server("生成期间日报或待办已被修改，已保留最新文件，请重新生成。") }
                try library.merge([entry], day: day)
            }
            status = report ? "日报已保存 · 手机连接时同步" : "小时记录已整理"
        } catch { status = "整理未完成：\(error.localizedDescription)"; throw error }
    }
    private func relatedHistory(day: String, query: String, config: DayRecordSettings) throws -> [DayRecordEntry] {
        guard config.historyEnabled else { return [] }
        let cutoff = Date().addingTimeInterval(-Double(config.historyDays) * 86400)
        var candidates: [DayRecordEntry] = []
        for date in library.days() where date < day && date >= DayRecordLibrary.day(cutoff) {
            candidates += try library.entries(day: date).filter { $0.kind == .report && DayRecordAnalyzer.relevance($0.text, query) > 0 }
        }
        return Array(candidates.sorted { DayRecordAnalyzer.relevance($0.text, query) > DayRecordAnalyzer.relevance($1.text, query) }.prefix(4))
    }
    public func tick(now: Date = Date()) async {
        guard settings.automatic, !analyzing, job == nil, now >= retryAfter else { return }
        do {
            for day in library.days().reversed() {
                let entries = try library.entries(day: day)
                let transcripts = entries.filter { $0.kind == .transcript }
                guard let first = transcripts.first else { continue }
                if DayRecordPolicy.dueReport(day: first.date, now: now, settings: settings), !entries.contains(where: { $0.kind == .report && DayRecordPolicy.dueReport(day: first.date, now: $0.end, settings: settings) }) {
                    try await generate(day: day, report: true); return
                }
                let hourStart = Calendar.current.dateInterval(of: .hour, for: now)!.start
                let covered = Set(entries.filter { $0.kind == .hour }.flatMap(\.sources))
                if transcripts.contains(where: { $0.end < hourStart && !covered.contains($0.id) }) {
                    try await generate(day: day, report: false); return
                }
            }
        } catch { retryAfter = now.addingTimeInterval(300); status = "整理待重试：\(error.localizedDescription)" }
    }
    public func handle(_ request: DayRecordRequest) async throws -> DayRecordReply {
        var reply = DayRecordReply()
        switch request.action {
        case "catalog": reply.versions = library.versions(); reply.days = library.days(); reply.settings = settings; reply.message = status; reply.processing = analyzing || job != nil
        case "sync":
            guard let day = request.day else { throw CompanionError.invalidFrame }
            let records = try library.entries(day: day)
            let offset = request.offset ?? 0
            guard offset >= 0, offset <= records.count else { throw CompanionError.invalidFrame }
            let page = Array(records.dropFirst(offset).prefix(8)); reply.entries = page
            reply.next = offset + page.count < records.count ? offset + page.count : nil
        case "task":
            guard let day = request.day, let text = request.taskText, let completed = request.completed,
                  let report = try library.entries(day: day).first(where: { $0.kind == .report }),
                  report.text.components(separatedBy: .newlines).contains(where: { DayRecordEntry.taskText($0) == text }) else { throw CompanionError.invalidFrame }
            var entry = DayRecordEntry(id: DayRecordEntry.taskID(report: report.id, text: text), kind: .task, date: report.date, end: Date(), text: text, sources: [report.id])
            entry.completed = completed; try library.merge([entry], day: day); reply.entries = [entry]
        case "settings":
            guard let settings = request.settings else { throw CompanionError.invalidFrame }
            try save(settings, apiKey: request.apiKey); reply.settings = self.settings; reply.message = "设置已保存到 Mac"
        case "test", "report", "organize":
            guard !analyzing, job == nil else { throw CompanionError.server("正在整理，请稍后查看。") }
            let day = request.day ?? DayRecordLibrary.day(Date())
            guard DayRecordLibrary.validDay(day) else { throw CompanionError.invalidFrame }
            status = request.action == "test" ? "正在测试模型连接…" : "整理任务已开始…"
            job = Task {
                defer { job = nil }
                do {
                    if request.action == "test" { status = try await analyzer.test(settings) }
                    else { try await generate(day: day, report: request.action == "report", refreshHours: request.action == "organize") }
                } catch { status = "未完成：\(error.localizedDescription)" }
            }
            reply.message = status; reply.processing = true
        default: throw CompanionError.invalidFrame
        }
        return reply
    }
}

/// One phone owns one short utterance. The upstream recognizer arbitrates with Whisper Anywhere.
@MainActor public final class DayRecordApplicationSession: CompanionApplicationSession {
    private let service: DayRecordService
    private var proxy: (any CompanionApplicationSession)?
    private let makeProxy: () -> any CompanionApplicationSession
    private let verifyAudioPolicy: () throws -> Void
    private var partial = ""
    private var active: (id: String, date: Date, end: Date?)?
    private var closed = false
    public init(service: DayRecordService) {
        self.service = service; makeProxy = { WhisperProxySession() }
        verifyAudioPolicy = {
            let endpoint = try JSONDecoder().decode(WhisperEndpoint.self, from: Data(contentsOf: WhisperEndpoint.file))
            guard endpoint.ephemeralAudio == true else { throw CompanionError.server("请更新并重启 Whisper Anywhere，24R 需要不写音频临时文件的版本。") }
        }
    }
    init(service: DayRecordService, makeProxy: @escaping () -> any CompanionApplicationSession, verifyAudioPolicy: @escaping () throws -> Void) {
        self.service = service; self.makeProxy = makeProxy; self.verifyAudioPolicy = verifyAudioPolicy
    }
    public func handle(_ packet: RelayPacket) async throws -> RelayPacket {
        guard !closed, packet.kind == "24r", let body = packet.body else { throw CompanionError.invalidFrame }
        let request = try JSONDecoder().decode(DayRecordRequest.self, from: body)
        var reply: DayRecordReply
        if request.action == "segment" {
            guard let segment = request.segment, UUID(uuidString: segment.id) != nil,
                  !segment.audio.isEmpty, segment.audio.count <= DayRecordSegmenter.maximumBytes, segment.audio.count % 2 == 0,
                  segment.date.timeIntervalSince1970.isFinite, segment.date >= Date(timeIntervalSince1970: 946684800), segment.date.timeIntervalSinceNow < 300 else { throw CompanionError.invalidFrame }
            let day = DayRecordLibrary.day(segment.date)
            if let existing = try service.library.entries(day: day).first(where: { $0.id == segment.id && $0.kind == .transcript }) {
                var result = DayRecordReply(); result.entries = [existing]; result.transcript = existing.text; result.completedSegmentID = segment.id
                return RelayPacket(kind: "reply", id: packet.id, body: try JSONEncoder().encode(result), status: 200, applicationID: "24r")
            }
            func forward(_ command: VoiceCommand) async throws -> RelayPacket {
                try await handle(DayRecordRequest("voice", voice: command).packet())
            }
            _ = try await forward(VoiceCommand("start", session: segment.id))
            active = (segment.id, segment.date, segment.date.addingTimeInterval(segment.seconds))
            var sequence = 0
            do {
                for offset in stride(from: 0, to: segment.audio.count, by: 32000) {
                    try Task.checkCancellation()
                    _ = try await forward(VoiceCommand("audio", session: segment.id, sequence: sequence, audio: segment.audio.subdata(in: offset..<min(offset + 32000, segment.audio.count))))
                    sequence += 1
                }
                var result = try await forward(VoiceCommand("finish", session: segment.id, sequence: sequence))
                guard let body = result.body else { throw CompanionError.invalidFrame }
                var completed = try JSONDecoder().decode(DayRecordReply.self, from: body)
                completed.completedSegmentID = segment.id
                result.body = try JSONEncoder().encode(completed)
                result.id = packet.id; return result
            } catch { preserveInterruption(); active = nil; proxy?.close(); proxy = nil; throw error }
        } else if request.action == "voice" {
            guard var command = request.voice else { throw CompanionError.invalidFrame }
            if command.action == "start" {
                guard active == nil, UUID(uuidString: command.session) != nil else { throw CompanionError.invalidFrame }
                try verifyAudioPolicy()
                proxy = makeProxy(); active = (command.session, Date(), nil); partial = ""
            }
            command.destination = .draft; command.background = true
            guard ["start", "audio", "finish", "cancel"].contains(command.action), let active, active.id == command.session, let proxy else { throw CompanionError.invalidFrame }
            do {
                let response = try await proxy.handle(command.packet())
                guard response.error == nil, response.status == 200, let data = response.body else { throw CompanionError.server(response.error ?? "转写服务未响应。") }
                let voice = try JSONDecoder().decode(VoiceStatus.self, from: data)
                reply = DayRecordReply(); reply.transcript = voice.transcript
                if let text = voice.transcript { partial = text }
                if command.action == "finish" {
                    let text = (voice.transcript ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty {
                        let entry = DayRecordEntry(id: active.id, kind: .transcript, date: active.date, end: active.end ?? Date(), text: text)
                        try service.library.merge([entry], day: DayRecordLibrary.day(entry.date)); reply.entries = try service.library.entries(day: DayRecordLibrary.day(entry.date)).filter { $0.id == entry.id }
                    }
                    self.active = nil; proxy.close(); self.proxy = nil
                } else if command.action == "cancel" { self.active = nil; proxy.close(); self.proxy = nil }
            } catch {
                preserveInterruption(); self.active = nil; proxy.close(); self.proxy = nil; throw error
            }
        } else { reply = try await service.handle(request) }
        return RelayPacket(kind: "reply", id: packet.id, body: try JSONEncoder().encode(reply), status: 200, applicationID: "24r")
    }
    private func preserveInterruption() {
        guard let active, !partial.isEmpty else { return }
        let entry = DayRecordEntry(id: active.id, kind: .gap, date: active.date, end: Date(), text: "转写中断 · 以下为未校正的临时文字，不自动纳入总结：\n" + partial)
        do { try service.library.merge([entry], day: DayRecordLibrary.day(active.date)) }
        catch { service.recordingFailed(error) }
        partial = ""
    }
    public func close() { preserveInterruption(); closed = true; active = nil; proxy?.close(); proxy = nil }
}
#endif
