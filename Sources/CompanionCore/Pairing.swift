import Foundation
import Security
import Network
import Darwin

public struct Pairing: Equatable, Sendable {
    public let nearbyService: String?
    public let host: String
    public let port: UInt16
    public let key: String
    public init(host: String, port: UInt16 = 8765, key: String, nearbyService: String? = nil) throws {
        guard !host.isEmpty, !host.contains("/"), !host.contains(" "), port > 0 else { throw CompanionError.invalidAddress }
        guard key.count == 64, Data(hex: key) != nil else { throw CompanionError.invalidKey }
        if let nearbyService { guard UUID(uuidString: nearbyService) != nil else { throw CompanionError.invalidAddress } }
        self.nearbyService = nearbyService
        self.host = host; self.port = port; self.key = key.lowercased()
    }
    public init(link: String) throws {
        guard let c = URLComponents(string: link.trimmingCharacters(in: .whitespacesAndNewlines)), c.scheme == "quenda-companion", c.host == "pair" else { throw CompanionError.invalidAddress }
        let values = Dictionary(c.queryItems?.map { ($0.name, $0.value ?? "") } ?? [], uniquingKeysWith: { first, _ in first })
        guard let port = UInt16(values["port"] ?? "8765") else { throw CompanionError.invalidAddress }
        try self.init(host: values["host"] ?? "", port: port, key: values["key"] ?? "", nearbyService: values["nearby"])
    }
    public var remoteHost: String? { host == "nearby" ? nil : host }
    public var link: String {
        var c = URLComponents(); c.scheme = "quenda-companion"; c.host = "pair"
        c.queryItems = [.init(name: "host", value: host), .init(name: "port", value: String(port)), .init(name: "key", value: key)]
        if let nearbyService { c.queryItems?.append(.init(name: "nearby", value: nearbyService)) }
        return c.string!
    }
    public static func newKey() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw CompanionError.server("无法生成配对密钥。") }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
extension Data {
    init?(hex: String) {
        guard hex.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []; var index = hex.startIndex
        while index < hex.endIndex {
            let end = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<end], radix: 16) else { return nil }
            bytes.append(byte); index = end
        }
        self.init(bytes)
    }
}
public enum CredentialStore {
    public static func read(_ account: String) throws -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.quenda.companion", kSecAttrAccount as String: account, kSecReturnData as String: true]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw CompanionError.server("无法读取钥匙串（\(status)）。") }
        return String(data: data, encoding: .utf8)
    }
    public static func write(_ value: String, account: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.quenda.companion", kSecAttrAccount as String: account]
        let attributes: [String: Any] = [kSecValueData as String: Data(value.utf8), kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound { status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil) }
        guard status == errSecSuccess else { throw CompanionError.server("无法保存钥匙串（\(status)）。") }
    }
}
public enum LocalGateway {
    #if os(macOS)
    public static func discover() -> URL {
        let root = ProcessInfo.processInfo.environment["QUENDA_HOME"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".quenda")
        if let data = try? Data(contentsOf: root.appendingPathComponent("gateway/gateway.json")), let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let port = state["port"] as? Int, (1...65535).contains(port) {
            return URL(string: "http://127.0.0.1:\(port)")!
        }
        return URL(string: "http://127.0.0.1:8000")!
    }
    #endif
    public static func validate(_ text: String) throws -> URL {
        guard let c = URLComponents(string: text), c.scheme == "http" || c.scheme == "https", ["127.0.0.1", "localhost", "::1", "[::1]"].contains(c.host ?? ""), c.user == nil, c.password == nil, c.query == nil, c.fragment == nil, c.path.isEmpty || c.path == "/", c.port == nil || (1...65535).contains(c.port!), let url = c.url else { throw CompanionError.server("Gateway 地址必须是本机 HTTP / HTTPS 地址。") }
        return url
    }
    public static func tailscaleAddresses() -> [String] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first; var result = Set<String>()
        while let p = cursor {
            defer { cursor = p.pointee.ifa_next }
            guard let address = p.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: buffer); let octets = ip.split(separator: ".").compactMap { Int($0) }
            if octets.count == 4 && octets[0] == 100 && (64...127).contains(octets[1]) { result.insert(ip) }
        }
        return result.sorted()
    }
}
