import Foundation

public struct CompanionApplication: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let summary: String
    public let symbol: String
    public let enabled: Bool
    public init(id: String, name: String, summary: String, symbol: String, enabled: Bool = true) {
        self.id = id; self.name = name; self.summary = summary; self.symbol = symbol; self.enabled = enabled
    }
    public static let quenda = CompanionApplication(id: "quenda", name: "Quenda", summary: "与电脑上的 Agent 对话，继续你的会话", symbol: "bubble.left.and.bubble.right.fill")
}

/// One instance per application per authenticated peer. Application code owns
/// its jobs and stream recovery; the host only routes opaque messages.
@MainActor public protocol CompanionApplicationSession: AnyObject {
    func handle(_ packet: RelayPacket) async throws -> RelayPacket
    func close()
}

@MainActor public final class ApplicationRegistry {
    private struct Entry {
        let application: CompanionApplication
        let makeSession: (@escaping @MainActor (RelayPacket) async throws -> Void) -> any CompanionApplicationSession
    }
    private var entries: [String: Entry] = [:]
    public init() {}
    public var applications: [CompanionApplication] { entries.values.map(\.application).sorted { $0.id < $1.id } }
    public func register(_ application: CompanionApplication, makeSession: @escaping (@escaping @MainActor (RelayPacket) async throws -> Void) -> any CompanionApplicationSession) {
        entries[application.id] = Entry(application: application, makeSession: makeSession)
    }
    public func session(for id: String, emit: @escaping @MainActor (RelayPacket) async throws -> Void) throws -> any CompanionApplicationSession {
        guard let entry = entries[id], entry.application.enabled else { throw CompanionError.server("此应用未在 Mac 上启用。") }
        return entry.makeSession(emit)
    }
}
