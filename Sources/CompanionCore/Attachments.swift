import Foundation

public struct OutgoingAttachment: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let mediaType: String
    public let data: Data
    public init(name: String, mediaType: String, data: Data, id: String = UUID().uuidString) {
        self.id = id; self.name = name; self.mediaType = mediaType; self.data = data
    }
    public var payload: JSONValue {
        .object(["name": .string(name), "media_type": .string(mediaType), "data": .string(data.base64EncodedString())])
    }
}

public enum AttachmentLimits {
    public static let maximumBytes = 8 * 1024 * 1024
    public static let maximumCount = 6
    public static let chunkBytes = 256 * 1024
    public static func validate(_ attachments: [OutgoingAttachment]) throws {
        guard attachments.count <= maximumCount, Set(attachments.map(\.id)).count == attachments.count,
              attachments.allSatisfy({ !$0.name.isEmpty && !$0.data.isEmpty }),
              attachments.reduce(0, { $0 + $1.data.count }) <= maximumBytes else {
            throw CompanionError.server("每条消息最多 6 个附件，总大小不超过 8 MB，文件不能为空。")
        }
    }
}

/// Uploads belong to one authenticated application's active conversation.
/// Bytes never enter the generic device registry or a global upload cache.
struct AttachmentBuffer {
    private struct Upload { let name: String; let mediaType: String; let size: Int; var data = Data() }
    private var uploads: [String: Upload] = [:]
    mutating func reset() { uploads.removeAll() }
    mutating func begin(_ value: JSONValue) throws {
        let id = value["id"].text
        guard case .number(let number) = value["size"], number.isFinite, number > 0,
              number <= Double(AttachmentLimits.maximumBytes), number.rounded() == number,
              UUID(uuidString: id) != nil, uploads[id] == nil,
              uploads.count < AttachmentLimits.maximumCount,
              !value["name"].text.isEmpty, value["name"].text.count <= 255,
              !value["media_type"].text.isEmpty, value["media_type"].text.count <= 200 else {
            throw CompanionError.server("附件声明无效。")
        }
        let size = Int(number)
        guard uploads.values.reduce(0, { $0 + $1.size }) + size <= AttachmentLimits.maximumBytes else {
            throw CompanionError.server("附件总大小超过 8 MB。")
        }
        uploads[id] = Upload(name: value["name"].text, mediaType: value["media_type"].text, size: size)
    }
    mutating func append(id: String, data: Data) throws {
        guard var upload = uploads[id], !data.isEmpty, data.count <= AttachmentLimits.chunkBytes,
              upload.data.count + data.count <= upload.size else { throw CompanionError.server("附件分块无效。") }
        upload.data.append(data); uploads[id] = upload
    }
    func payload(ids: [String]) throws -> [JSONValue] {
        guard ids.count <= AttachmentLimits.maximumCount, Set(ids).count == ids.count else { throw CompanionError.invalidFrame }
        return try ids.map { id in
            guard let upload = uploads[id], upload.data.count == upload.size else { throw CompanionError.server("附件传输未完成，请重新选择后发送。") }
            return OutgoingAttachment(name: upload.name, mediaType: upload.mediaType, data: upload.data).payload
        }
    }
}

public struct MessageAttachment: Codable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let media_type: String
    public let size: Int
    public var isImage: Bool { media_type.hasPrefix("image/") }
}

public struct ModelChoice: Codable, Identifiable, Sendable {
    public let provider_id: String
    public let provider_name: String
    public let model_id: String
    public let model_name: String
    public let vision: Bool
    public var id: String { provider_id + "/" + model_id }
}
