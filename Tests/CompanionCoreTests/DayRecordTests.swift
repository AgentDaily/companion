import XCTest
@testable import CompanionCore
import CompanionUI

private final class DayRecordHTTP: URLProtocol {
    static var requests: [URLRequest] = []
    static var empty = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(contentsOf: buffer.prefix(n)) }
            body = data
        }
        let payload = (try? JSONSerialization.jsonObject(with: body ?? Data())) as? [String: Any]
        let prompt = ((payload?["messages"] as? [[String: Any]])?.first?["content"] as? String) ?? ""
        let contracts = ["hour_digest": ["summary", "mood_tags", "scene_tags", "topic_tags"], "synthesis": ["summary", "todos", "history", "uncertainties"], "events": ["timeline", "events"], "mood": ["observations", "encouragement"], "challenges": ["difficulties", "strategies"], "positives": ["achievements", "recognition"]]
        let fields = contracts.first { prompt.contains("24R 分析阶段：" + $0.key) }?.value
        let content: String
        if Self.empty { content = "" }
        else if let fields {
            let result = Dictionary(uniqueKeysWithValues: fields.map { ($0, $0 == "todos" ? [] : [["text": "讨论了 24R", "sources": [], "quote": ""]] as [[String: Any]]) })
            content = String(decoding: try! JSONSerialization.data(withJSONObject: result), as: UTF8.self)
        } else { content = "## 今日总结\n讨论了 24R。\n## 待办\n- [ ] 验证中英文转写。\n## 对策\n先实测。" }
        let json: [String: Any] = ["message": ["content": content]]
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: json)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
@MainActor private final class DayRecordSpeech: VoiceTranscriptionEngine {
    var owner: String?
    var inserted = false
    var voiceStatus: VoiceStatus { VoiceStatus(ready: true, message: "test") }
    var transcriptionStatus: VoiceStatus { VoiceStatus(ready: true, message: "draft", supportsDraft: true) }
    func startVoice(session: String) throws { inserted = true }
    func startTranscription(session: String) throws { owner = session }
    func startBackgroundTranscription(session: String) throws { owner = session }
    func pushVoice(session: String, samples: [Float]) async throws { XCTAssertEqual(session, owner) }
    func finishVoice(session: String) async throws { inserted = true }
    func finishTranscription(session: String) async throws -> String { owner = nil; return "今天讨论 24R，next step 是实测。" }
    func partialTranscription(session: String) -> String? { "今天讨论 24R" }
    func cancelVoice(session: String) { owner = nil }
}

final class DayRecordTests: XCTestCase {
    private func temporary() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("24r-test-" + UUID().uuidString) }
    @MainActor func testTextSurvivesRestartAndSyncIsIdempotentWithoutAudioOrKey() throws {
        let dir = temporary(); defer { try? FileManager.default.removeItem(at: dir) }
        let library = DayRecordLibrary(directory: dir), date = Date()
        let day = DayRecordLibrary.day(date)
        let entry = DayRecordEntry(kind: .transcript, date: date, text: "中英文 mixed text")
        try library.merge([entry], day: day); try library.merge([entry], day: day)
        var settings = DayRecordSettings(); settings.agent = "24r-agent"; try library.save(settings: settings)
        let reopened = DayRecordLibrary(directory: dir)
        XCTAssertEqual(try reopened.entries(day: day), [entry]); XCTAssertEqual(try reopened.settings(), settings)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted(), [day + ".json", "settings.json"].sorted())
        XCTAssertThrowsError(try library.merge([entry], day: "../outside"))
        let phone = DayRecordLibrary(directory: dir.appendingPathComponent("phone"))
        let packet = try JSONEncoder().encode(DayRecordReply())
        XCTAssertFalse(String(decoding: packet, as: UTF8.self).contains("apiKey"))
        try phone.merge(reopened.entries(day: day), day: day); try phone.merge(reopened.entries(day: day), day: day)
        XCTAssertEqual(try phone.entries(day: day).count, 1)
    }
    func testRetentionCreatesNoDefaultFileAndNeverIncludesPreTriggerOrPostLimitSamples() throws {
        let dir = temporary(); defer { try? FileManager.default.removeItem(at: dir) }
        let sink = RetainedAudio(), start = Date(timeIntervalSince1970: 1000)
        let audio = VoicePCM.encode(Array(repeating: 0.25, count: 16000))
        try sink.append(audio, capturedAt: start)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
        let file = try sink.start(directory: dir, seconds: 1, now: start)
        try sink.append(audio, capturedAt: start.addingTimeInterval(0.5)) // straddles trigger; dropped
        try sink.append(audio, capturedAt: start.addingTimeInterval(1))
        try sink.append(audio, capturedAt: start.addingTimeInterval(2)) // beyond limit
        try sink.stop(); try sink.append(audio, capturedAt: start.addingTimeInterval(3))
        let data = try Data(contentsOf: file)
        XCTAssertEqual(data.count, 44 + audio.count); XCTAssertEqual(data.dropFirst(44), audio)
        XCTAssertEqual(String(decoding: data.prefix(4), as: UTF8.self), "RIFF")
    }
    func testProviderCredentialsAreScopedToEndpoint() {
        XCTAssertNotEqual(DayRecordAnalyzer.keyAccount(for: "https://a.example/v1"), DayRecordAnalyzer.keyAccount(for: "https://b.example/v1"))
        XCTAssertEqual(DayRecordAnalyzer.keyAccount(for: "https://a.example/v1"), DayRecordAnalyzer.keyAccount(for: "https://a.example/v1/"))
    }
    func testKeywordOptInAndEnglishBoundariesAndSchedule() throws {
        var config = DayRecordSettings(); config.keywords = "开始保留音频\nkeep this audio"
        XCTAssertNil(DayRecordPolicy.keyword(in: "开始保留音频", settings: config))
        config.keywordsEnabled = true
        XCTAssertNotNil(DayRecordPolicy.keyword(in: "请开始保留音频。", settings: config))
        XCTAssertNotNil(DayRecordPolicy.keyword(in: "Please KEEP THIS AUDIO!", settings: config))
        XCTAssertNil(DayRecordPolicy.keyword(in: "keep this audiophile", settings: config))
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let day = calendar.date(from: DateComponents(year: 2026, month: 10, day: 4))!
        XCTAssertFalse(DayRecordPolicy.dueReport(day: day, now: day.addingTimeInterval(21 * 3600), settings: config, calendar: calendar))
        XCTAssertTrue(DayRecordPolicy.dueReport(day: day, now: day.addingTimeInterval(22 * 3600), settings: config, calendar: calendar))
        config.retentionMinutes = 60; XCTAssertThrowsError(try config.validated())
    }
    @MainActor private func service(_ dir: URL) throws -> DayRecordService {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [DayRecordHTTP.self]
        DayRecordHTTP.requests = []; DayRecordHTTP.empty = false
        let analyzer = DayRecordAnalyzer(gateway: { URL(string: "http://127.0.0.1:1")! }, session: URLSession(configuration: config))
        let service = DayRecordService(library: DayRecordLibrary(directory: dir), gateway: { URL(string: "http://127.0.0.1:1")! }, analyzer: analyzer)
        var settings = DayRecordSettings(); settings.ollamaModel = "test"; try service.save(settings, apiKey: nil)
        return service
    }
    @MainActor func testScheduledReportCatchesUpAndSurvivesRestartWithoutDuplicateCalls() async throws {
        let dir = temporary(); defer { try? FileManager.default.removeItem(at: dir) }
        let service = try service(dir)
        let today = Calendar.current.startOfDay(for: Date()); let date = today.addingTimeInterval(-3600)
        let entry = DayRecordEntry(kind: .transcript, date: date, text: "讨论手机端 24R")
        let day = DayRecordLibrary.day(date)
        try service.library.merge([entry], day: day)
        // A previous day always has a passed report deadline, including test runs before 21:30.
        await service.tick(now: today.addingTimeInterval(86400))
        let records = try service.library.entries(day: day)
        XCTAssertEqual(records.filter { $0.kind == .hour }.count, 1)
        XCTAssertEqual(records.filter { $0.kind == .report }.count, 1)
        XCTAssertEqual(DayRecordHTTP.requests.count, 6)
        await service.tick()
        XCTAssertEqual(DayRecordHTTP.requests.count, 6, "existing report and hours must not be regenerated")
        let reopened = DayRecordLibrary(directory: dir)
        XCTAssertEqual(try reopened.entries(day: day), records)
        let report = records.first { $0.kind == .report }!
        XCTAssertTrue(report.sources.contains { $0.hasPrefix("hour-") })
        XCTAssertTrue(DayRecordHTTP.requests.allSatisfy { $0.url?.path == "/api/chat" })
    }
    @MainActor func testManualHourRefreshRebuildsCachedHoursAndKeepsDailyReport() async throws {
        let dir = temporary(); defer { try? FileManager.default.removeItem(at: dir) }
        let service = try service(dir), date = Date(), day = DayRecordLibrary.day(Date())
        let source = DayRecordEntry(kind: .transcript, date: date, text: "讨论蓝牙连接")
        let report = DayRecordEntry(id: "report-" + day, kind: .report, date: date, text: "已有日报")
        try service.library.merge([source, report], day: day)
        try await service.generate(day: day, report: false)
        XCTAssertEqual(DayRecordHTTP.requests.count, 1)
        try await service.generate(day: day, report: false)
        XCTAssertEqual(DayRecordHTTP.requests.count, 1, "Automatic jobs reuse unchanged hourly digests")
        try await service.generate(day: day, report: false, refreshHours: true)
        XCTAssertEqual(DayRecordHTTP.requests.count, 2, "Explicit organize can replace old heavy hourly reports")
        let entries = try service.library.entries(day: day)
        XCTAssertEqual(entries.first { $0.kind == .report }, report)
        XCTAssertTrue(entries.first { $0.kind == .hour }!.text.hasPrefix("## 本小时摘要"))
    }
    @MainActor func testTaskCompletionPersistsAndRejectsInventedActions() async throws {
        let dir = temporary(); defer { try? FileManager.default.removeItem(at: dir) }
        let service = try service(dir), date = Date(), day = DayRecordLibrary.day(Date())
        let report = DayRecordEntry(id: "report-" + day, kind: .report, date: date, text: "## 待办\n- [ ] 验证中英文")
        try service.library.merge([report], day: day)
        var request = DayRecordRequest("task", day: day); request.taskText = "验证中英文"; request.completed = true
        _ = try await service.handle(request); _ = try await service.handle(request)
        let reloaded = DayRecordLibrary(directory: dir)
        let tasks = try reloaded.entries(day: day).filter { $0.kind == .task }
        XCTAssertEqual(tasks.count, 1); XCTAssertEqual(tasks.first?.completed, true)
        request.taskText = "不存在的任务"
        do { _ = try await service.handle(request); XCTFail("invented task accepted") } catch {}
    }
    @MainActor func testEmptyModelResultDoesNotSaveSuccessfulSummary() async throws {
        let dir = temporary(); defer { try? FileManager.default.removeItem(at: dir) }
        let service = try service(dir); DayRecordHTTP.empty = true
        let date = Date(), day = DayRecordLibrary.day(date)
        try service.library.merge([DayRecordEntry(kind: .transcript, date: date, text: "原文必须保留")], day: day)
        do { try await service.generate(day: day, report: true); XCTFail("empty analysis accepted") } catch {}
        XCTAssertEqual(try service.library.entries(day: day).map(\.kind), [.transcript])
        DayRecordHTTP.empty = false
    }
    @MainActor func testAuthenticated24RRelayPersistsBeforeReplyAndResyncsAfterReconnect() async throws {
        let dir = temporary(); defer { try? FileManager.default.removeItem(at: dir) }
        let service = try service(dir), engine = DayRecordSpeech(), registry = ApplicationRegistry()
        registry.register(.dayRecord) { _ in DayRecordApplicationSession(service: service, makeProxy: { VoiceInputApplicationSession(engine: engine) }, verifyAudioPolicy: {}) }
        let key = try Pairing.newKey(), server = try RelayServer(registry: registry, host: "127.0.0.1", port: 0, key: key)
        try await server.start(); defer { server.stop() }
        let pairing = try Pairing(host: "127.0.0.1", port: server.port, key: key)
        let link = CompanionLink(pairing: pairing); try await link.connect(); defer { link.close() }
        let id = UUID().uuidString
        _ = try await DayRecordStore.send(DayRecordRequest("voice", voice: VoiceCommand("start", session: id)), link: link)
        let partial = try await DayRecordStore.send(DayRecordRequest("voice", voice: VoiceCommand("audio", session: id, audio: VoicePCM.encode([0.2]))), link: link)
        XCTAssertEqual(partial.transcript, "今天讨论 24R")
        let result = try await DayRecordStore.send(DayRecordRequest("voice", voice: VoiceCommand("finish", session: id, sequence: 1)), link: link)
        XCTAssertEqual(result.entries.count, 1); XCTAssertFalse(engine.inserted)
        link.close()
        let second = CompanionLink(pairing: pairing); try await second.connect(); defer { second.close() }
        let day = DayRecordLibrary.day(Date())
        let sync = try await DayRecordStore.send(DayRecordRequest("sync", day: day), link: second)
        XCTAssertEqual(sync.entries, result.entries)
        // Analysis acknowledgement returns immediately; catalog/audio need not await the model response.
        let job = try await DayRecordStore.send(DayRecordRequest("report", day: day), link: second)
        XCTAssertTrue(job.processing)
        _ = try await DayRecordStore.send(DayRecordRequest("catalog"), link: second)
        while service.analyzing { try await Task.sleep(for: .milliseconds(20)) }
        service.stop()
    }
    @MainActor func testOneMinuteSegmentThroughAuthenticatedRelayAndReplayIsIdempotent() async throws {
        let dir = temporary(); defer { try? FileManager.default.removeItem(at: dir) }
        let service = try service(dir), engine = DayRecordSpeech(), registry = ApplicationRegistry()
        registry.register(.dayRecord) { _ in DayRecordApplicationSession(service: service, makeProxy: { VoiceInputApplicationSession(engine: engine) }, verifyAudioPolicy: {}) }
        let key = try Pairing.newKey(), server = try RelayServer(registry: registry, host: "127.0.0.1", port: 0, key: key)
        try await server.start(); defer { server.stop() }
        let link = CompanionLink(pairing: try Pairing(host: "127.0.0.1", port: server.port, key: key)); try await link.connect(); defer { link.close() }
        let start = Date().addingTimeInterval(-60)
        let segment = DayRecordAudioSegment(date: start, audio: Data(repeating: 1, count: DayRecordSegmenter.maximumBytes))
        var request = DayRecordRequest("segment"); request.segment = segment
        let reply = try await DayRecordStore.send(request, link: link)
        XCTAssertEqual(reply.entries.count, 1); XCTAssertEqual(reply.entries.first?.date, start)
        XCTAssertEqual(reply.entries.first?.end, start.addingTimeInterval(60)); XCTAssertFalse(engine.inserted)
        let repeatReply = try await DayRecordStore.send(request, link: link)
        XCTAssertEqual(repeatReply.entries, reply.entries)
        XCTAssertEqual(try service.library.entries(day: DayRecordLibrary.day(start)).count, 1)
    }
    @MainActor func testOfflineDayOldSegmentThroughRelayIsAcceptedAndReplayIsIdempotent() async throws {
        let dir = temporary(); defer { try? FileManager.default.removeItem(at: dir) }
        let service = try service(dir), engine = DayRecordSpeech(), registry = ApplicationRegistry()
        registry.register(.dayRecord) { _ in DayRecordApplicationSession(service: service, makeProxy: { VoiceInputApplicationSession(engine: engine) }, verifyAudioPolicy: {}) }
        let key = try Pairing.newKey(), server = try RelayServer(registry: registry, host: "127.0.0.1", port: 0, key: key)
        try await server.start(); defer { server.stop() }
        let link = CompanionLink(pairing: try Pairing(host: "127.0.0.1", port: server.port, key: key)); try await link.connect(); defer { link.close() }
        let start = Date().addingTimeInterval(-86400)
        let segment = DayRecordAudioSegment(date: start, audio: Data(repeating: 1, count: DayRecordSegmenter.maximumBytes))
        var request = DayRecordRequest("segment"); request.segment = segment
        let reply = try await DayRecordStore.send(request, link: link)
        XCTAssertEqual(reply.entries.count, 1); XCTAssertEqual(reply.entries.first?.date, start)
        XCTAssertEqual(reply.entries.first?.end, start.addingTimeInterval(60)); XCTAssertFalse(engine.inserted)
        let repeatReply = try await DayRecordStore.send(request, link: link)
        XCTAssertEqual(repeatReply.entries, reply.entries)
        XCTAssertEqual(try service.library.entries(day: DayRecordLibrary.day(start)).count, 1)
    }
    @MainActor func testInterruptedTranscriptionRetainsOnlyMarkedPartialText() async throws {
        let dir = temporary(); defer { try? FileManager.default.removeItem(at: dir) }
        let service = try service(dir), engine = DayRecordSpeech()
        let session = DayRecordApplicationSession(service: service, makeProxy: { VoiceInputApplicationSession(engine: engine) }, verifyAudioPolicy: {})
        let id = UUID().uuidString
        _ = try await session.handle(DayRecordRequest("voice", voice: VoiceCommand("start", session: id)).packet())
        _ = try await session.handle(DayRecordRequest("voice", voice: VoiceCommand("audio", session: id, audio: VoicePCM.encode([0.1]))).packet())
        session.close()
        let records = try service.library.entries(day: DayRecordLibrary.day(Date()))
        XCTAssertEqual(records.count, 1); XCTAssertEqual(records[0].kind, .gap); XCTAssertTrue(records[0].text.contains("未校正")); XCTAssertNil(engine.owner)
    }
    @MainActor func testLegacyAudioBackendRejectedBeforeCapture() async throws {
        let dir = temporary(); defer { try? FileManager.default.removeItem(at: dir) }
        let service = try service(dir), engine = DayRecordSpeech()
        let session = DayRecordApplicationSession(service: service, makeProxy: { XCTFail("created unsafe engine"); return VoiceInputApplicationSession(engine: engine) }, verifyAudioPolicy: { throw CompanionError.server("unsafe audio storage") })
        do { _ = try await session.handle(DayRecordRequest("voice", voice: VoiceCommand("start", session: UUID().uuidString)).packet()); XCTFail("unsafe backend accepted") } catch {}
        XCTAssertNil(engine.owner)
    }
}
