import Foundation

public enum JSONValue: Codable, Hashable, Sendable {
    case string(String), number(Double), bool(Bool), object([String: JSONValue]), array([JSONValue]), null
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode([String: JSONValue].self) { self = .object(v) }
        else { self = .array(try c.decode([JSONValue].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    public subscript(_ key: String) -> JSONValue { if case .object(let v) = self { return v[key] ?? .null }; return .null }
    public var text: String { if case .string(let v) = self { return v }; return "" }
    public var array: [JSONValue] { if case .array(let v) = self { return v }; return [] }
    public var flag: Bool { if case .bool(let v) = self { return v }; return false }
}

public struct Agent: Codable, Identifiable, Sendable { public let id: String; public let name: String }
public struct Workspace: Codable, Identifiable, Sendable { public let id: String; public let name: String }
public struct SessionInfo: Codable, Identifiable, Sendable {
    public let id: String
    public let agent_id: String
    public let title: String?
    public let agent_name: String?
    public let updated_at: String
    public let status: String
    public var displayTitle: String { title?.isEmpty == false ? title! : "新会话" }
}
public struct ChatMessage: Codable, Identifiable, Sendable {
    public let id: String
    public let role: String
    public let content: String
}
public struct MessagePage: Codable, Sendable {
    public let items: [ChatMessage]
    public let before: Int
    public let has_more: Bool
}
public struct GatewayEvent: Codable, Sendable {
    public let type: String
    public let content: JSONValue
    public let metadata: [String: JSONValue]?
}
public struct PendingPermission: Identifiable {
    public let id: String
    public let request: JSONValue
    public init(id: String, request: JSONValue) { self.id = id; self.request = request }
    public var summary: String { request["description"].text.isEmpty ? request["tool_name"].text : request["description"].text }
}
public enum CompanionError: LocalizedError {
    case invalidAddress, invalidKey, disconnected, timeout, invalidFrame, server(String)
    public var errorDescription: String? {
        switch self {
        case .invalidAddress: return "地址无效，请填写主机地址和端口。"
        case .invalidKey: return "配对密钥应为 64 位十六进制字符。"
        case .disconnected: return "连接已断开。"
        case .timeout: return "连接超时，请检查 Mac Companion、Tailscale 和电脑唤醒状态。"
        case .invalidFrame: return "连接协议无效或消息超过大小限制。"
        case .server(let message): return message
        }
    }
}

public struct APIReply: Sendable { public let status: Int; public let body: Data }
public struct RelayPacket: Codable, Sendable {
    public var applicationID: String? = nil
    public var kind: String
    public var id: String = UUID().uuidString
    public var method: String? = nil
    public var path: String? = nil
    public var body: Data? = nil
    public var status: Int? = nil
    public var sessionID: String? = nil
    public var error: String? = nil
    public init(kind: String, id: String = UUID().uuidString, method: String? = nil, path: String? = nil, body: Data? = nil, status: Int? = nil, sessionID: String? = nil, error: String? = nil, applicationID: String? = nil) {
        self.applicationID = applicationID
        self.kind = kind; self.id = id; self.method = method; self.path = path; self.body = body; self.status = status; self.sessionID = sessionID; self.error = error
    }
}
