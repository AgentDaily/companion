import XCTest
@testable import CompanionCore

final class ConnectionDiagnosticsTests: XCTestCase {
    @MainActor func testPersistedTransportHistoryIsBounded() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("diagnostics.json")
        let diagnostics = ConnectionDiagnostics(file: file)
        for number in 0..<100 { diagnostics.record("nearby.browse.results", "count=\(number)") }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let entries = try decoder.decode([ConnectionDiagnostics.Entry].self, from: Data(contentsOf: file))
        XCTAssertEqual(entries.count, 80)
        XCTAssertEqual(entries.first?.detail, "count=20")
        XCTAssertEqual(entries.last?.detail, "count=99")
    }
    @MainActor func testUnwritableDiagnosticsDoNotInterruptConnectionCode() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: root)
        let diagnostics = ConnectionDiagnostics(file: root.appendingPathComponent("diagnostics.json"))
        diagnostics.record("nearby.browse.timeout")
        XCTAssertEqual(diagnostics.entries.count, 1)
        XCTAssertTrue(diagnostics.summary.contains("nearby.browse.timeout"))
    }
}
