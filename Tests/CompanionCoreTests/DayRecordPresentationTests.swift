import XCTest
import SwiftUI
import AppKit
import CompanionCore
@testable import CompanionUI

final class DayRecordPresentationTests: XCTestCase {
    private let sourceID = "DE8667EB-E3B4-4D20-8850-D829488179B5"
    func testScreenshotMarkdownUsesReadableCitationAndShortTitle() throws {
        let source = DayRecordEntry(id: sourceID, kind: .transcript, date: Date(), text: "这识别的结果也不是特别好啊，怎么办呢？")
        let markdown = "# 本小时要点\n- **录音转写识别评估**：今日资料记录了音频转写过程中的识别结果反馈与疑问。\n  引用 [\(sourceID)]，询问处理建议。"
        let entry = DayRecordEntry(kind: .hour, date: source.date, text: markdown, sources: [sourceID])
        let presentation = DayRecordPresentation(entry: entry, resolve: { $0 == self.sourceID ? source : nil })
        let displayed = presentation.display(markdown)
        XCTAssertFalse(displayed.contains(sourceID))
        XCTAssertTrue(displayed.contains("**录音转写识别评估**"), "Retain emphasis for Markdown rendering")
        let attributed = try AttributedString(markdown: displayed, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        XCTAssertFalse(String(attributed.characters).contains("**"))
        let link = try XCTUnwrap(attributed.runs.compactMap { $0.link }.first)
        XCTAssertEqual(presentation.citation(url: link)?.source, source)
        XCTAssertEqual(DayRecordPresentation.title(entry), "录音转写识别评估")
        XCTAssertEqual(entry.text, markdown, "Presentation must not rewrite stored source IDs")
        XCTAssertNil(presentation.citation(url: URL(string: "https://reference/0")!))
        XCTAssertNil(presentation.citation(url: URL(string: "dayrecord-source://reference/999")!))
    }
    func testUnresolvedAndQuendaReferencesDoNotLeakIdentifiers() {
        let unknown = "F4D44BFB-2A35-4F50-A86A-B88F0CF26420"
        let entry = DayRecordEntry(kind: .report, date: Date(), text: "[\(sourceID.lowercased())] [\(unknown)] [quenda:session:message]", sources: [sourceID, sourceID, "quenda:session:message"])
        let presentation = DayRecordPresentation(entry: entry, resolve: { _ in nil })
        XCTAssertEqual(presentation.citations.count, 3)
        XCTAssertTrue(presentation.display(entry.text).contains("未同步"))
        XCTAssertFalse(presentation.display(entry.text).contains(unknown))
        XCTAssertFalse(presentation.display(entry.text).contains(sourceID.lowercased()))
        XCTAssertFalse(presentation.display(entry.text).contains("quenda:session"))
        XCTAssertTrue(presentation.display(entry.text).contains("Quenda 来源"))
    }
    func testTaskIdentitySurvivesRenderingAndCodeFenceIsNotInteractive() {
        let task = "验证 **中英文** [\(sourceID)]"
        let blocks = DayRecordPresentation.blocks("## 待办\n- [ ] \(task)\n- [x] 已完成\n```text\n- [ ] 示例\n```")
        XCTAssertEqual(blocks, [.markdown("## 待办"), .task(task, checked: false), .task("已完成", checked: true), .markdown("```text\n- [ ] 示例\n```")])
    }
    @MainActor func testHistoricalReferenceResolvesFromItsOwnDay() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let library = DayRecordLibrary(directory: dir)
        let date = Date().addingTimeInterval(-86400), day = DayRecordLibrary.day(date)
        let source = DayRecordEntry(id: "report-" + day, kind: .report, date: date, text: "昨日总结")
        try library.merge([source], day: day)
        let store = DayRecordStore(library: library)
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertEqual(store.source(for: source.id), source)
        XCTAssertNil(store.source(for: "quenda:unknown"))
    }
    @MainActor func testReadingLayoutSnapshots() throws {
        guard let directory = ProcessInfo.processInfo.environment["R24_UI_SNAPSHOT"] else { throw XCTSkip("Optional native SwiftUI render") }
        _ = NSApplication.shared
        let date = Date(timeIntervalSince1970: 1791100800)
        let source = DayRecordEntry(id: sourceID, kind: .transcript, date: date, end: date.addingTimeInterval(37), text: "这次中文识别好多了。Let's also check mixed Chinese and English，下午再对比一下。")
        let entry = DayRecordEntry(kind: .hour, date: date, text: "# 本小时要点\n- **录音转写识别评估**：中文和英文混合识别，需要继续对比测试。\n\n引用 [\(sourceID)]，保留用户原始反馈。\n\n## 待办\n- [ ] 对比手机与蓝牙麦克风的效果\n\n## 下一步\n1. 在安静环境下测试。\n2. 加入风扇背景声进行对比。\n\n> 识别质量的变化尚待确认。", sources: [sourceID])
        let presentation = DayRecordPresentation(entry: entry, resolve: { _ in source })
        try snapshot(VStack(alignment: .leading, spacing: 22) {
            Text("HOURLY NOTE").font(.caption).foregroundStyle(.secondary)
            Text("这一小时的记录").font(.system(size: 30, design: .serif))
            DayRecordAnalysisContent(entry: entry, presentation: presentation)
            Spacer()
        }, name: "analysis", directory: directory)
        try snapshot(VStack(alignment: .leading, spacing: 24) {
            Text("已经说过的话。").font(.system(size: 30, design: .serif))
            Text("已识别 · 3 段").font(.subheadline)
            VStack(spacing: 0) {
                DayRecordTranscriptRow(entry: source)
                DayRecordTranscriptRow(entry: DayRecordEntry(kind: .transcript, date: date.addingTimeInterval(-120), text: "今天下午先把页面整理一下。引用可以点开，看回当时说过的话。"))
                DayRecordTranscriptRow(entry: DayRecordEntry(kind: .gap, date: date.addingTimeInterval(-300), text: "这段文字在收音中断前保留，待确认。"))
            }
            Spacer()
        }, name: "transcripts", directory: directory)
    }
    @MainActor private func snapshot<V: View>(_ view: V, name: String, directory: String) throws {
        let host = NSHostingView(rootView: view.padding(24).frame(width: 393, height: 800, alignment: .topLeading).background(Color(red: 0.98, green: 0.977, blue: 0.957)).environment(\.colorScheme, .light))
        host.frame = NSRect(x: 0, y: 0, width: 393, height: 800)
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"))
    }
}
