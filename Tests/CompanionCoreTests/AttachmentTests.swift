import XCTest
@testable import CompanionCore

final class AttachmentTests: XCTestCase {
    func testUploadRejectsIncompleteDuplicateAndOversizePayloads() throws {
        let id = UUID().uuidString
        let declaration: JSONValue = .object(["id": .string(id), "name": .string("notes.txt"), "media_type": .string("text/plain"), "size": .number(4)])
        var buffer = AttachmentBuffer()
        try buffer.begin(declaration)
        XCTAssertThrowsError(try buffer.begin(declaration))
        XCTAssertThrowsError(try buffer.payload(ids: [id]))
        XCTAssertThrowsError(try buffer.append(id: id, data: Data(repeating: 0, count: 5)))
        try buffer.append(id: id, data: Data("test".utf8))
        XCTAssertEqual(try buffer.payload(ids: [id]).first?["data"].text, Data("test".utf8).base64EncodedString())
        XCTAssertThrowsError(try buffer.payload(ids: [id, id]))
        buffer.reset()
        XCTAssertThrowsError(try buffer.payload(ids: [id]))
        XCTAssertThrowsError(try AttachmentLimits.validate([OutgoingAttachment(name: "empty", mediaType: "text/plain", data: Data())]))
        XCTAssertThrowsError(try AttachmentLimits.validate([OutgoingAttachment(name: "large", mediaType: "text/plain", data: Data(repeating: 0, count: AttachmentLimits.maximumBytes + 1))]))
    }
    func testUploadLimitsApplyToReservedBytesAndEachChunk() throws {
        var buffer = AttachmentBuffer()
        let id = UUID().uuidString
        try buffer.begin(.object(["id": .string(id), "name": .string("large.bin"), "media_type": .string("application/octet-stream"), "size": .number(Double(AttachmentLimits.maximumBytes))]))
        XCTAssertThrowsError(try buffer.begin(.object(["id": .string(UUID().uuidString), "name": .string("extra.txt"), "media_type": .string("text/plain"), "size": .number(1)])))
        XCTAssertThrowsError(try buffer.append(id: id, data: Data(repeating: 0, count: AttachmentLimits.chunkBytes + 1)))
        XCTAssertThrowsError(try buffer.begin(.object(["id": .string(UUID().uuidString), "name": .string("a"), "media_type": .string("text/plain"), "size": .number(.nan)])))
    }
    func testOnlyRequestedManagementRoutesAreOpen() {
        XCTAssertTrue(RoutePolicy.allows(method: "GET", path: "/api/models?agent_id=quenda-code"))
        XCTAssertTrue(RoutePolicy.allows(method: "GET", path: "/api/models/settings/quenda-code"))
        XCTAssertTrue(RoutePolicy.allows(method: "PUT", path: "/api/models/settings/quenda-code"))
        XCTAssertTrue(RoutePolicy.allows(method: "POST", path: "/api/workspaces"))
        for (method, path) in [("DELETE", "/api/workspaces/a"), ("POST", "/api/agents"), ("PUT", "/api/models/settings/a?override=true"), ("PUT", "/api/models/settings/../../config")] {
            XCTAssertFalse(RoutePolicy.allows(method: method, path: path))
        }
    }
}
