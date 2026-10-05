#if os(macOS)
import Foundation

public struct WhisperEndpoint: Codable {
    public let port: UInt16
    public let pid: Int32
    public let version: Int
    public let ephemeralAudio: Bool?
    public init(port: UInt16, ephemeralAudio: Bool = false) { self.port = port; pid = ProcessInfo.processInfo.processIdentifier; version = 1; self.ephemeralAudio = ephemeralAudio }
    public static let credentialAccount = "whisper-anywhere-local-key"
    public static var file: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Whisper Anywhere/companion-service.json") }
    public func save() throws {
        try FileManager.default.createDirectory(at: Self.file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: Self.file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.file.path)
    }
    public static func pairing() throws -> Pairing {
        guard let data = try? Data(contentsOf: file), let endpoint = try? JSONDecoder().decode(Self.self, from: data), endpoint.version == 1, endpoint.port > 0,
              let key = try CredentialStore.read(credentialAccount) else { throw CompanionError.server("请先打开 Mac 上的 Whisper Anywhere。") }
        return try Pairing(host: "127.0.0.1", port: endpoint.port, key: key)
    }
}

/// The app host forwards audio to the independently running local input app.
@MainActor public final class WhisperProxySession: CompanionApplicationSession {
    private var link: CompanionLink?
    private var closed = false
    public init() {}
    public func handle(_ packet: RelayPacket) async throws -> RelayPacket {
        guard !closed, packet.kind == "voice", let body = packet.body,
              let command = try? JSONDecoder().decode(VoiceCommand.self, from: body),
              ["status", "start", "audio", "finish", "cancel"].contains(command.action) else { throw CompanionError.invalidFrame }
        if link == nil {
            let candidate = CompanionLink(pairing: try WhisperEndpoint.pairing())
            link = candidate
            do { try await candidate.connect() } catch { candidate.close(); link = nil; throw error }
        }
        guard !closed, let link else { throw CompanionError.disconnected }
        return try await link.request(packet, timeout: command.action == "finish" ? .seconds(120) : .seconds(15))
    }
    public func close() { closed = true; link?.close(); link = nil }
}
#endif
