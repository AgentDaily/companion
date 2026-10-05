#if os(macOS)
import XCTest
@testable import CompanionCore

final class DayRecordVaultTests: XCTestCase {
    private func temporary() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("24r-vault-test-" + UUID().uuidString) }
    private func header(_ day: String, type: String) -> String { "---\ndate: \(day)\ntype: \(type)\ngenerator: 24R\nschema_version: 2\n---\n\n" }
    @MainActor func testSelectedVaultIsOnlySourceAndExternalReportsAndTasksAreLive() throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let library = DayRecordLibrary(directory: root.appendingPathComponent("internal"))
        let date = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970)), day = DayRecordLibrary.day(date)
        let transcript = DayRecordEntry(id: "original-1", kind: .transcript, date: date, text: "今天完成测试")
        let hour = DayRecordEntry(id: "hour-1", kind: .hour, date: date, text: "## 本小时摘要\n完成测试 [original-1]", sources: [transcript.id])
        let report = DayRecordEntry(id: "report-" + day, kind: .report, date: date, text: "## 今日总结\n第一版 [original-1]\n## 待办\n- [ ] 明早确认", sources: [transcript.id])
        try library.merge([transcript, hour, report], day: day)
        let legacy = try Data(contentsOf: library.directory.appendingPathComponent(day + ".json"))
        try library.vault.select(parent: root.appendingPathComponent("Obsidian"), library: library)
        let vault = try XCTUnwrap(library.vault.directory)
        let reportFile = vault.appendingPathComponent("Reports/\(day).md"), taskFile = vault.appendingPathComponent("Tasks/\(day).md")
        let exported = try String(contentsOf: reportFile)
        XCTAssertTrue(exported.contains("[[../Transcripts/\(day)#^original-1|"))
        XCTAssertFalse(exported.contains("- [ ] 明早确认")) // one task owner
        XCTAssertEqual(try library.entries(day: day).first { $0.kind == .hour }?.text, hour.text)
        try Data(exported.replacingOccurrences(of: "第一版", with: "Agent 改好的报告").utf8).write(to: reportFile, options: .atomic)
        try Data((header(day, type: "tasks") + "我的任务备注\n- [x] 明早确认\n- [ ] Agent 新建的待办\n").utf8).write(to: taskFile, options: .atomic)
        let current = try library.entries(day: day)
        XCTAssertTrue(current.first { $0.kind == .report }!.text.contains("Agent 改好的报告"))
        XCTAssertTrue(current.contains { $0.kind == .task && $0.text == "明早确认" && $0.completed == true })
        XCTAssertTrue(current.contains { $0.kind == .task && $0.text == "Agent 新建的待办" })
        var completed = try XCTUnwrap(current.first { $0.kind == .task && $0.text == "Agent 新建的待办" }); completed.completed = true
        try library.merge([completed], day: day)
        XCTAssertTrue(try String(contentsOf: taskFile).contains("- [x] Agent 新建的待办"))
        XCTAssertTrue(try String(contentsOf: taskFile).contains("我的任务备注"))
        XCTAssertEqual(try Data(contentsOf: library.directory.appendingPathComponent(day + ".json")), legacy, "No hidden Mac journal writes after selecting a vault")
        let reopened = DayRecordLibrary(directory: library.directory)
        XCTAssertTrue(try reopened.entries(day: day).first { $0.kind == .report }!.text.contains("Agent 改好的报告"))
        try FileManager.default.removeItem(at: reportFile); try FileManager.default.removeItem(at: taskFile)
        XCTAssertFalse(try reopened.entries(day: day).contains { $0.kind == .report }, "Deleted vault report must not reappear from legacy/cache")
    }
    @MainActor func testAgentCanCreateReportAndTasksWhileUnrelatedFoldersAreIgnored() throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let library = DayRecordLibrary(directory: root.appendingPathComponent("internal"))
        try library.vault.select(parent: root.appendingPathComponent("parent"), library: library)
        let vault = try XCTUnwrap(library.vault.directory), day = "2026-10-03"
        for folder in ["Reports", "Tasks", "Other/Reports"] { try FileManager.default.createDirectory(at: vault.appendingPathComponent(folder), withIntermediateDirectories: true) }
        try Data((header(day, type: "daily-report") + "# Agent 日报\n\n外部分析内容").utf8).write(to: vault.appendingPathComponent("Reports/\(day).md"))
        try Data((header(day, type: "tasks") + "- [ ] 外部任务").utf8).write(to: vault.appendingPathComponent("Tasks/\(day).md"))
        try Data("not a 24R file".utf8).write(to: vault.appendingPathComponent("Other/Reports/2026-10-02.md"))
        try Data("personal note".utf8).write(to: vault.appendingPathComponent("Reports/Personal.md"))
        XCTAssertEqual(library.days(), [day])
        XCTAssertTrue(try library.entries(day: day).contains { $0.kind == .report && $0.text.contains("外部分析内容") && $0.text.contains("外部任务") })
        library.vault.synchronize(library)
        XCTAssertEqual(try String(contentsOf: vault.appendingPathComponent("Reports/Personal.md")), "personal note")
        let phone = DayRecordLibrary(directory: root.appendingPathComponent("phone"))
        try phone.replace(library.entries(day: day), day: day)
        try phone.replace([], day: day)
        XCTAssertEqual(try phone.entries(day: day), [], "A full Mac snapshot must remove stale phone records")
    }
    @MainActor func testVaultJSONEditsAndNewCaptureShareSameFile() throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let library = DayRecordLibrary(directory: root.appendingPathComponent("internal")), day = DayRecordLibrary.day(Date())
        var entry = DayRecordEntry(kind: .transcript, date: Date(), text: "原识别结果")
        try library.merge([entry], day: day); try library.vault.select(parent: root.appendingPathComponent("parent"), library: library)
        let file = try XCTUnwrap(library.vault.directory).appendingPathComponent("Transcripts/\(day).json")
        entry.text = "用户校正的识别文本"
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode([entry]).write(to: file, options: .atomic)
        XCTAssertEqual(try library.entries(day: day).first?.text, entry.text)
        try library.merge([DayRecordEntry(kind: .transcript, date: Date(), text: "新片段")], day: day)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let raw = try decoder.decode([DayRecordEntry].self, from: Data(contentsOf: file))
        XCTAssertEqual(raw.count, 2); XCTAssertTrue(raw.contains { $0.text == entry.text })
    }
    @MainActor func testNewVaultCopiesButOpeningExistingVaultDoesNotMerge() throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let library = DayRecordLibrary(directory: root.appendingPathComponent("internal")), day = DayRecordLibrary.day(Date())
        try library.merge([DayRecordEntry(kind: .transcript, date: Date(), text: "旧内容")], day: day)
        try library.vault.select(parent: root.appendingPathComponent("first"), library: library)
        let old = try XCTUnwrap(library.vault.directory)
        try library.vault.select(parent: root.appendingPathComponent("second"), library: library)
        try library.merge([DayRecordEntry(kind: .transcript, date: Date(), text: "新内容")], day: day)
        XCTAssertFalse(try String(contentsOf: old.appendingPathComponent("Transcripts/\(day).json")).contains("新内容"))
        try library.vault.select(parent: old, library: library)
        XCTAssertEqual(try library.entries(day: day).count, 1)
    }
    @MainActor func testMissingVaultNeverFallsBackAndSymlinkNeverRedirectsWrites() throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let library = DayRecordLibrary(directory: root.appendingPathComponent("internal")), day = DayRecordLibrary.day(Date())
        try library.vault.select(parent: root.appendingPathComponent("parent"), library: library)
        let vault = try XCTUnwrap(library.vault.directory), external = root.appendingPathComponent("external")
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: vault.appendingPathComponent("Transcripts"), withDestinationURL: external)
        let original = DayRecordEntry(kind: .transcript, date: Date(), text: "保留原文")
        XCTAssertThrowsError(try library.merge([original], day: day))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: external.path), [])
        try FileManager.default.removeItem(at: vault)
        XCTAssertThrowsError(try library.merge([original], day: day))
        XCTAssertThrowsError(try library.entries(day: day))
        XCTAssertFalse(FileManager.default.fileExists(atPath: vault.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.directory.appendingPathComponent(day + ".json").path))
    }
    @MainActor func testV1MigrationPreservesExternallyEditedReport() throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let library = DayRecordLibrary(directory: root.appendingPathComponent("internal")), day = DayRecordLibrary.day(Date())
        let report = DayRecordEntry(id: "report-" + day, kind: .report, date: Date(), text: "旧的内部正文")
        try library.merge([report], day: day)
        let vault = root.appendingPathComponent("old/24R")
        try FileManager.default.createDirectory(at: vault.appendingPathComponent("Reports"), withIntermediateDirectories: true)
        try Data("{\"version\":1,\"files\":{}}".utf8).write(to: vault.appendingPathComponent(".24r-vault.json"))
        try Data((header(day, type: "daily-report").replacingOccurrences(of: "schema_version: 2", with: "schema_version: 1") + "# 日报\n\n外部已修改\n- [x] 已完成任务").utf8).write(to: vault.appendingPathComponent("Reports/\(day).md"))
        try library.vault.select(parent: vault, library: library)
        let records = try library.entries(day: day)
        XCTAssertTrue(records.contains { $0.kind == .report && $0.text.contains("外部已修改") })
        XCTAssertTrue(records.contains { $0.kind == .task && $0.completed == true })
        XCTAssertFalse(records.contains { $0.text.contains("旧的内部正文") })
    }
}
#endif
