import Foundation
import SwiftUI
import CompanionCore

/// Each application owns a separate settings namespace on each device.
@MainActor public final class QuendaConfiguration: ObservableObject {
    @Published public var gateway: String
    @Published public var shared: Bool
    @Published public var defaultAgent: String
    @Published public private(set) var revision = 0
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        #if os(macOS)
        gateway = defaults.string(forKey: "app.quenda.gateway") ?? defaults.string(forKey: "gateway") ?? LocalGateway.discover().absoluteString
        #else
        gateway = defaults.string(forKey: "app.quenda.gateway") ?? "http://127.0.0.1:8000"
        #endif
        shared = defaults.object(forKey: "app.quenda.shared") as? Bool ?? true
        defaultAgent = defaults.string(forKey: "app.quenda.defaultAgent") ?? "quenda-code"
    }
    public func save() throws {
        #if os(macOS)
        _ = try LocalGateway.validate(gateway)
        defaults.set(gateway, forKey: "app.quenda.gateway")
        defaults.set(shared, forKey: "app.quenda.shared")
        #endif
        defaults.set(defaultAgent.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "app.quenda.defaultAgent")
        revision += 1
    }
    public var application: CompanionApplication {
        let base = CompanionApplication.quenda
        return CompanionApplication(id: base.id, name: base.name, summary: base.summary, symbol: base.symbol, enabled: shared)
    }
}

public struct ApplicationTile: View {
    public let application: CompanionApplication
    public let status: String
    public init(application: CompanionApplication, status: String) { self.application = application; self.status = status }
    public var body: some View {
        HStack(spacing: 16) {
            Image(systemName: application.symbol).font(.system(size: 28)).foregroundStyle(.tint)
                .frame(width: 60, height: 60).background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 16))
            VStack(alignment: .leading, spacing: 5) {
                Text(application.name).font(.title3.bold())
                Text(application.summary).font(.subheadline).foregroundStyle(.secondary)
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").foregroundStyle(.secondary)
        }.padding(.vertical, 10)
    }
}
