import XCTest
@testable import CompanionCore

private final class WorkflowHTTP: URLProtocol {
    static var bodies: [JSONValue] = []
    static var paths: [String] = []
    static var failStage: String?
    static var rejectsBooleanThinking = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            var body = request.httpBody
            if body == nil, let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(contentsOf: buffer.prefix(n)) }
                body = data
            }
            let json = try JSONDecoder().decode(JSONValue.self, from: body ?? Data())
            Self.bodies.append(json); Self.paths.append(request.url!.path)
            if Self.rejectsBooleanThinking, json["think"] == .bool(false) {
                client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: Data(#"{"error":"model only supports named thinking levels"}"#.utf8))
                client?.urlProtocolDidFinishLoading(self); return
            }
            let prompt = json["messages"].array[0]["content"].text
            let phase = ["hour_digest", "events", "mood", "challenges", "positives", "synthesis"].first { prompt.contains("24R 分析阶段：" + $0) } ?? "hour"
            let item: [String: Any] = ["text": phase + " 的独立分析结论", "sources": ["S2"], "quote": ""]
            let fields = ["events": ["timeline", "events"], "mood": ["observations", "encouragement"], "challenges": ["difficulties", "strategies"], "positives": ["achievements", "recognition"]][phase] ?? ["items"]
            let payload: [String: Any] = phase == "synthesis"
                ? ["summary": [item], "todos": [["text": "确认明天的会议", "sources": ["S2"], "quote": "我答应明早确认会议时间"]], "history": [], "uncertainties": []]
                : Dictionary(uniqueKeysWithValues: fields.map { ($0, [item]) })
            let hourPayload: [String: Any] = [
                "summary": [["text": "在办公室修复蓝牙连接，测试通过。", "sources": ["S1"], "quote": ""]],
                "mood_tags": [["text": "疲惫", "sources": ["S1"], "quote": "今天有点累"]],
                "scene_tags": [["text": "办公", "sources": ["S1"], "quote": ""]],
                "topic_tags": [["text": "蓝牙调试", "sources": ["S1"], "quote": ""]]
            ]
            let result = phase == Self.failStage ? " " : String(decoding: try JSONSerialization.data(withJSONObject: phase == "hour_digest" ? hourPayload : payload), as: UTF8.self)
            let response: [String: Any] = request.url!.path == "/api/chat" ? ["message": ["content": result]] : ["choices": [["message": ["content": result]]]]
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try JSONSerialization.data(withJSONObject: response)); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

final class DayRecordWorkflowTests: XCTestCase {
    @MainActor private func analyzer() -> DayRecordAnalyzer {
        WorkflowHTTP.bodies = []; WorkflowHTTP.paths = []; WorkflowHTTP.failStage = nil; WorkflowHTTP.rejectsBooleanThinking = false
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [WorkflowHTTP.self]
        return DayRecordAnalyzer(gateway: { URL(string: "http://127.0.0.1:1")! }, session: URLSession(configuration: config))
    }
    @MainActor func testHourlyDigestUsesOneCallAndNoDailyAnalysisOrHistory() async throws {
        for provider in [DayRecordSettings.Analysis.ollama, .cloud] {
            let analyzer = analyzer()
            var settings = DayRecordSettings(); settings.analysis = provider; settings.ollamaModel = "fixture"; settings.cloudModel = "fixture"; settings.cloudURL = "http://workflow.invalid/v1"; settings.historyEnabled = true
            let source = DayRecordEntry(kind: .transcript, date: Date(), text: "今天有点累。到了办公室，蓝牙连接修复了，测试通过。")
            let history = DayRecordEntry(kind: .report, date: Date().addingTimeInterval(-86400), text: "不应进入小时摘要的历史")
            let result = try await analyzer.analyze(settings, entries: [source], history: [history], report: false)
            XCTAssertEqual(WorkflowHTTP.bodies.count, 1)
            XCTAssertEqual(result.1, [source.id])
            XCTAssertTrue(result.0.hasPrefix("## 本小时摘要"))
            XCTAssertTrue(result.0.contains("## 标签"))
            for tag in ["疲惫", "办公", "蓝牙调试"] { XCTAssertTrue(result.0.contains(tag)) }
            for heading in ["## 待办", "## 下一步", "## 心情与支持", "## 困难与对策", "## 值得肯定的事"] { XCTAssertFalse(result.0.contains(heading)) }
            let prompt = WorkflowHTTP.bodies[0]["messages"].array[0]["content"].text
            XCTAssertFalse(prompt.contains(history.text))
            XCTAssertFalse(prompt.contains("低落时具体、温和地理解和鼓励"))
        }
    }
    func testHourlyDigestBoundsSummaryAndDropsUnsubstantiatedMoodTags() {
        let source = DayRecordEntry(id: "source", kind: .transcript, date: Date(), text: "今天很开心，测试通过了。")
        let format = DayRecordFindings(material: "[source] 原文", sources: [source.id])
        let fact = DayRecordFindings.Item(text: String(repeating: "长", count: 200), sources: ["S1"])
        let result = DayRecordHourDigest.render([
            "summary": Array(repeating: fact, count: 5),
            "mood_tags": [.init(text: "开心", sources: ["S1"], quote: "很开心"), .init(text: "开心", sources: ["S1"], quote: "很开心"), .init(text: "沮丧", sources: ["S1"], quote: "我很沮丧"), .init(text: "焦虑症", sources: ["S1"], quote: "很开心")],
            "scene_tags": [], "topic_tags": []
        ], format: format, entries: [source])
        XCTAssertEqual(result.filter { $0 == "长" }.count, 270)
        XCTAssertEqual(result.components(separatedBy: "开心").count - 1, 1)
        XCTAssertFalse(result.contains("沮丧")); XCTAssertFalse(result.contains("焦虑症"))
        XCTAssertFalse(result.contains("**场景**"))
    }
    @MainActor func testOptionalLocalOllamaHourlyDigest() async throws {
        guard let model = ProcessInfo.processInfo.environment["R24_OLLAMA_SMOKE_MODEL"] else { throw XCTSkip("Optional real local Ollama check") }
        var settings = DayRecordSettings(); settings.ollamaModel = model
        let analyzer = DayRecordAnalyzer(gateway: { URL(string: "http://127.0.0.1:1")! })
        let source = DayRecordEntry(kind: .transcript, date: Date(), text: "我到办公室了。今天有点累，不过蓝牙连接终于修复了，测试也通过了，挺开心。明早我答应确认会议时间。")
        let result = try await analyzer.analyze(settings, entries: [source], history: [], report: false)
        XCTAssertTrue(result.0.hasPrefix("## 本小时摘要"))
        XCTAssertFalse(result.0.contains("## 待办"))
        XCTAssertLessThan(result.0.count, 1500)
        try result.0.write(toFile: "/tmp/24r-hour-digest-smoke.md", atomically: true, encoding: .utf8)
        for category in ["**情绪线索**", "**场景**", "**主题**"] { XCTAssertTrue(result.0.contains(category)) }
    }
    @MainActor func testDirectProvidersRunFiveSeparateCallsAndRetainEveryFinding() async throws {
        for provider in [DayRecordSettings.Analysis.ollama, .cloud] {
            let analyzer = analyzer()
            var settings = DayRecordSettings(); settings.analysis = provider; settings.ollamaModel = "fixture"; settings.cloudModel = "fixture"; settings.cloudURL = "http://workflow.invalid/v1"
            let source = DayRecordEntry(id: "original-1", kind: .transcript, date: Date(), text: "今天有点沮丧，但终于解决了蓝牙连接的问题。下午去了办公室。我答应明早确认会议时间。")
            let hour = DayRecordEntry(id: "hour-fixture", kind: .hour, date: source.date, text: "小时总结", sources: [source.id])
            var updates: [String] = []
            let result = try await analyzer.analyze(settings, entries: [hour], history: [], report: true, evidence: [source], progress: { updates.append($0) })
            XCTAssertEqual(WorkflowHTTP.bodies.count, 5)
            XCTAssertEqual(updates.count, 5); XCTAssertTrue(updates.last!.contains("5/5"))
            let prompts = WorkflowHTTP.bodies.map { $0["messages"].array[0]["content"].text }
            for (index, phase) in ["events", "mood", "challenges", "positives", "synthesis"].enumerated() {
                XCTAssertTrue(prompts[index].contains("24R 分析阶段：" + phase))
                XCTAssertTrue(prompts[index].contains(source.text), "Use original mood/event evidence alongside summaries")
            }
            for phase in ["events", "mood", "challenges", "positives"] {
                XCTAssertTrue(prompts.last!.contains(phase + " 的独立分析结论"))
                XCTAssertTrue(result.0.contains(phase + " 的独立分析结论"), "Synthesis cannot discard a specialist result")
            }
            XCTAssertTrue(result.0.contains("- [ ] 我答应明早确认会议时间"))
            XCTAssertTrue(result.0.contains("## 历史关联\n未启用历史关联。"))
            XCTAssertTrue(result.1.contains(source.id))
            XCTAssertTrue(WorkflowHTTP.paths.allSatisfy { $0 == (provider == .ollama ? "/api/chat" : "/v1/chat/completions") })
            if provider == .ollama {
                XCTAssertEqual(WorkflowHTTP.bodies[0]["keep_alive"].text, settings.keepAlive)
                XCTAssertEqual(WorkflowHTTP.bodies[0]["think"], .bool(false))
            }
        }
    }
    @MainActor func testThinkingControlRejectionFallsBackWithoutBreakingWorkflow() async throws {
        let analyzer = analyzer()
        WorkflowHTTP.rejectsBooleanThinking = true
        var settings = DayRecordSettings(); settings.ollamaModel = "named-thinking-fixture"
        let source = DayRecordEntry(id: "original-1", kind: .transcript, date: Date(), text: "我答应明早确认会议时间")
        let hour = DayRecordEntry(kind: .hour, date: source.date, text: source.text, sources: [source.id])
        let result = try await analyzer.analyze(settings, entries: [hour], history: [], report: true, evidence: [source])
        XCTAssertEqual(WorkflowHTTP.bodies.count, 10, "Each server rejection is retried once using the model default")
        for index in stride(from: 0, to: 10, by: 2) {
            XCTAssertEqual(WorkflowHTTP.bodies[index]["think"], .bool(false))
            XCTAssertEqual(WorkflowHTTP.bodies[index + 1]["think"], .null)
        }
        XCTAssertTrue(result.0.contains("- [ ] 我答应明早确认会议时间"))
    }
    @MainActor func testFailedMiddleStageStopsAndKeepsExistingReport() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let analyzer = analyzer(), library = DayRecordLibrary(directory: dir), date = Date(), day = DayRecordLibrary.day(Date())
        let source = DayRecordEntry(id: "original-1", kind: .transcript, date: date, text: "今天遇到问题")
        let start = Calendar.current.dateInterval(of: .hour, for: date)!.start
        let hour = DayRecordEntry(id: "hour-\(Int(start.timeIntervalSince1970))", kind: .hour, date: start, text: "已整理", sources: [source.id])
        let old = DayRecordEntry(id: "report-" + day, kind: .report, date: date, text: "原来的完整日报")
        try library.merge([source, hour, old], day: day)
        let service = DayRecordService(library: library, gateway: { URL(string: "http://127.0.0.1:1")! }, analyzer: analyzer)
        var settings = DayRecordSettings(); settings.ollamaModel = "fixture"; try service.save(settings, apiKey: nil)
        WorkflowHTTP.failStage = "mood"
        do { try await service.generate(day: day, report: true); XCTFail("Empty stage must fail the workflow") } catch {}
        XCTAssertEqual(WorkflowHTTP.bodies.count, 2, "Do not continue or synthesize incomplete work")
        XCTAssertEqual(try library.entries(day: day).first { $0.kind == .report }, old)
        XCTAssertFalse(service.analyzing)
        XCTAssertTrue(service.status.contains("未完成"))
    }
    @MainActor func testCancellationBeforeWorkflowMakesNoModelRequest() async throws {
        let analyzer = analyzer()
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await analyzer.analyze(DayRecordSettings(), entries: [DayRecordEntry(kind: .hour, date: Date(), text: "资料")], history: [], report: true)
        }
        do { _ = try await task.value; XCTFail("Cancelled analysis returned a report") } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertTrue(WorkflowHTTP.bodies.isEmpty)
    }
    func testStructuredReferencesRejectUnknownIDsAndUnverifiableTasks() throws {
        let source = DayRecordEntry(id: "original", kind: .transcript, date: Date(), text: "我答应明早确认会议时间。")
        let format = DayRecordFindings(material: "[original] 原文", sources: [source.id])
        XCTAssertEqual(format.material, "[S1] 原文")
        XCTAssertThrowsError(try format.decode(#"{"items":[{"text":"猜测","sources":["S999"],"quote":""}]}"#, fields: ["items"]))
        let valid = try format.decode(#"{"items":[{"text":"确认会议","sources":["S1"],"quote":"我答应明早确认会议时间"}]}"#, fields: ["items"])
        let item = try XCTUnwrap(valid["items"]?.first)
        XCTAssertTrue(format.supportedTask(item, evidence: [source]))
        XCTAssertFalse(format.supportedTask(.init(text: "去公园", sources: ["S1"], quote: "我答应去公园"), evidence: [source]))
        XCTAssertEqual(format.render([item], tasks: true), "- [ ] 确认会议 [original]")
    }
    @MainActor func testOptionalLocalOllamaWorkflow() async throws {
        guard let model = ProcessInfo.processInfo.environment["R24_OLLAMA_SMOKE_MODEL"] else { throw XCTSkip("Optional real local Ollama check") }
        var settings = DayRecordSettings(); settings.ollamaModel = model
        let analyzer = DayRecordAnalyzer(gateway: { URL(string: "http://127.0.0.1:1")! })
        let base = Calendar.current.startOfDay(for: Date()).addingTimeInterval(9 * 3600)
        let samples = ["我现在在家。这个问题昨天没解决，今天觉得有点沮丧，不知道先从哪里开始。", "现在到办公室了，上午终于把蓝牙连接修好了，测试也通过了，挺开心。", "下午会议改到明天了，我答应明早确认时间。晚上想去公园，但还没决定。视频里的人说他很难过，那不是我。"]
        let originals = samples.enumerated().map { DayRecordEntry(kind: .transcript, date: base.addingTimeInterval(Double($0.offset) * 7200), text: $0.element) }
        let hours = originals.map { DayRecordEntry(kind: .hour, date: $0.date, text: $0.text, sources: [$0.id]) }
        var steps = 0
        let report = try await analyzer.analyze(settings, entries: hours, history: [], report: true, evidence: originals, progress: { status in
            steps += 1
            try? status.write(toFile: "/tmp/24r-workflow-smoke-progress.txt", atomically: true, encoding: .utf8)
        })
        XCTAssertEqual(steps, 5)
        for title in ["活动动线与重要事件", "心情与支持", "困难与对策", "值得肯定的事"] { XCTAssertTrue(report.0.contains("## " + title)) }
        try report.0.write(toFile: "/tmp/24r-workflow-smoke.md", atomically: true, encoding: .utf8)
    }
    @MainActor func testQuendaReceivesOneAutonomousGoalWithoutDirectProviderWorkflow() async throws {
        guard let address = ProcessInfo.processInfo.environment["QUENDA_FIXTURE_URL"], let gateway = URL(string: address) else { throw XCTSkip("Isolated Gateway required") }
        var settings = DayRecordSettings(); settings.analysis = .quenda; settings.agent = "24r-autonomous-test"
        let analyzer = DayRecordAnalyzer(gateway: { gateway })
        let entry = DayRecordEntry(kind: .hour, date: Date(), text: "今天取得了进展，但有些疲惫。")
        let result = try await analyzer.analyze(settings, entries: [entry], history: [], report: true)
        XCTAssertTrue(result.0.contains("自主分析完成"))
        XCTAssertFalse(result.0.contains("我先检查"), "Persist the final agent deliverable, not intermediate planning text")
        let backend = QuendaBackend(gateway: gateway); defer { backend.close() }
        let sessions = try JSONDecoder().decode([SessionInfo].self, from: await backend.request(path: "/api/sessions"))
        let own = sessions.filter { $0.agent_id == settings.agent }
        XCTAssertEqual(own.count, 1, "One delegated goal/session, not five prescribed phases")
        let id = try XCTUnwrap(own.first?.id)
        let page = try JSONDecoder().decode(MessagePage.self, from: await backend.request(path: "/api/sessions/\(id)/message-pages?limit=10"))
        let prompts = page.items.filter { $0.role == "user" }
        XCTAssertEqual(prompts.count, 1)
        let prompt = try XCTUnwrap(prompts.first?.content)
        XCTAssertTrue(prompt.contains("自主决定")); XCTAssertFalse(prompt.contains("24R 分析阶段："))
        XCTAssertTrue(prompt.contains("未开启历史关联"))
        for topic in ["心情", "困难", "赞赏", "活动动线"] { XCTAssertTrue(prompt.contains(topic)) }
    }
}
