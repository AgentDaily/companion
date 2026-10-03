import SwiftUI
import CompanionCore
import CompanionUI

@main struct QuendaCompanionApp: App {
    @StateObject private var connection = DeviceConnectionStore()
    @StateObject private var quenda = QuendaStore()
    @StateObject private var configuration = QuendaConfiguration()
    @Environment(\.scenePhase) private var scenePhase
    @State private var settings = false
    var body: some Scene {
        WindowGroup {
            PhoneHome(connection: connection, quenda: quenda, configuration: configuration, settings: $settings)
                .task {
                    connection.loadPairing()
                    if connection.pairing == nil { settings = true }
                    else { await connection.resume() }
                }
                .onOpenURL { url in
                    Task {
                        do { try await connection.pair(link: url.absoluteString); settings = !connection.connected }
                        catch { connection.error = error.localizedDescription; settings = true }
                    }
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { Task { await connection.resume() } }
                    if phase == .background { quenda.disconnect(); connection.suspend() }
                }
        }
    }
}

private enum PhoneRoute: Hashable { case application(String), conversation(String) }
private struct QuendaConnectionContext: Hashable { let revision: Int; let applicationRevision: Int; let active: Bool }

private struct PhoneHome: View {
    @ObservedObject var connection: DeviceConnectionStore
    @ObservedObject var quenda: QuendaStore
    @ObservedObject var configuration: QuendaConfiguration
    @Binding var settings: Bool
    @State private var navigation: [PhoneRoute] = []
    private var applications: [CompanionApplication] {
        connection.applications.isEmpty ? [.quenda] : connection.applications
    }
    var body: some View {
        NavigationStack(path: $navigation) {
            List {
                Section("你的 Mac") {
                    Label(connection.state.title, systemImage: connection.connected ? "checkmark.circle.fill" : "network")
                        .foregroundStyle(connection.connected ? .green : .secondary)
                    Text("优先附近连接，不可用时尝试已配置的 Tailscale。").font(.caption).foregroundStyle(.secondary)
                    if let error = connection.error { Text(error).font(.callout).foregroundStyle(.orange) }
                    Button(connection.pairing == nil ? "配对 Mac" : "设备连接与配对") { settings = true }
                }
                Section("应用") {
                    ForEach(applications) { application in
                        if application.id == "quenda" {
                            NavigationLink(value: PhoneRoute.application(application.id)) {
                                ApplicationTile(application: application, status: !connection.connected ? "连接 Mac 后使用" : application.enabled ? "可以打开" : "Mac 尚未启用此应用")
                            }
                        } else {
                            ApplicationTile(application: application, status: "此版本尚未包含对应的 iPhone 界面，请更新 Companion")
                        }
                    }
                }
                Section { Text("每个应用有独立设置，设备配对与连接由 Companion 共用。").font(.caption).foregroundStyle(.secondary) }
            }.navigationTitle("Companion")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button { settings = true } label: { Image(systemName: "network") }.accessibilityLabel("设备连接与配对") } }
            .refreshable { await connection.reconnect() }
            .navigationDestination(for: PhoneRoute.self) { route in
                switch route {
                case .application("quenda"):
                    QuendaPhoneView(store: quenda, connection: connection, configuration: configuration) { navigation.append(.conversation($0)) }
                case .conversation(let id): ConversationView(store: quenda, sessionID: id)
                default: Text("请更新 Companion 以使用这个应用。")
                }
            }
            .onChange(of: navigation) { _, routes in
                if !routes.contains(.application("quenda")) { quenda.disconnect() }
            }
            .sheet(isPresented: $settings) { DevicePairingView(connection: connection) }
        }
        .task(id: QuendaConnectionContext(revision: connection.revision, applicationRevision: connection.applicationRevisions["quenda", default: 0], active: navigation.contains(.application("quenda")))) {
            guard navigation.contains(.application("quenda")), let link = connection.link else { quenda.disconnect(); return }
            guard connection.applications.contains(where: { $0.id == "quenda" && $0.enabled }) else {
                quenda.disconnect(); quenda.error = "请在 Mac 的 Quenda 设置中启用此应用。"; return
            }
            await quenda.connect { QuendaBackend(link: link) }
        }
    }
}

private struct QuendaPhoneView: View {
    @ObservedObject var store: QuendaStore
    @ObservedObject var connection: DeviceConnectionStore
    @ObservedObject var configuration: QuendaConfiguration
    let onCreated: (String) -> Void
    @State private var creating = false
    @State private var settings = false
    var body: some View {
        List {
            Section {
                Label(store.connected ? "Quenda 已连接" : store.connecting ? "正在连接 Quenda…" : "Quenda 未连接", systemImage: store.connected ? "checkmark.circle" : "bubble.left.and.bubble.right")
                    .foregroundStyle(store.connected ? .green : .secondary)
                if let error = store.error {
                    Text(error).font(.callout).foregroundStyle(.orange)
                    Button("重新连接 Quenda") { Task { await connect() } }.disabled(store.connecting || !connection.connected)
                }
                if !connection.connected { Text("请返回 Companion 首页，连接你的 Mac。").foregroundStyle(.secondary) }
            }
            Section("会话") {
                ForEach(store.sessions) { session in
                    NavigationLink(value: PhoneRoute.conversation(session.id)) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(session.displayTitle).lineLimit(2)
                            Text(session.agent_name ?? session.agent_id).font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 4)
                    }
                }
                if store.sessions.isEmpty { Text(store.connected ? "创建一个会话，开始使用 Quenda。" : "连接 Quenda 后查看会话。").foregroundStyle(.secondary) }
            }
        }
        .navigationTitle("Quenda")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { Button { settings = true } label: { Image(systemName: "gearshape") }.accessibilityLabel("Quenda 设置") }
            ToolbarItem(placement: .topBarTrailing) { Button { creating = true } label: { Image(systemName: "square.and.pencil") }.disabled(!store.connected).accessibilityLabel("新会话") }
        }
        .refreshable { do { try await store.refresh() } catch { store.error = error.localizedDescription } }
        .sheet(isPresented: $creating) { NewSessionView(store: store, defaultAgent: configuration.defaultAgent, onCreated: onCreated) }
        .sheet(isPresented: $settings) { QuendaSettingsView(configuration: configuration) }
    }
    @MainActor private func connect() async {
        guard let link = connection.link else { store.disconnect(); return }
        guard connection.applications.contains(where: { $0.id == "quenda" && $0.enabled }) else {
            store.disconnect(); store.error = "请在 Mac 的 Quenda 设置中启用此应用。"; return
        }
        await store.connect { QuendaBackend(link: link) }
    }
}

private struct DevicePairingView: View {
    @ObservedObject var connection: DeviceConnectionStore
    @State private var link = ""
    @State private var saving = false
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section("配对你的 Mac") {
                    Text("在 Mac Companion 的「设备连接与配对」中开启手机连接，用相机扫描二维码，或粘贴配对链接。所有应用共用这次配对。")
                    SecureField("quenda-companion://pair?…", text: $link).textInputAutocapitalization(.never).autocorrectionDisabled()
                    PasteButton(payloadType: String.self) { strings in link = strings.first ?? "" }
                    Button(saving ? "正在连接…" : "保存并连接") {
                        saving = true
                        Task {
                            do { try await connection.pair(link: link); if connection.connected { dismiss() } }
                            catch { connection.error = error.localizedDescription }
                            saving = false
                        }
                    }.disabled(link.isEmpty || saving)
                }
                if let pairing = connection.pairing {
                    Section("当前连接") {
                        Text(connection.state.title)
                        Text(pairing.nearbyService == nil ? "此配对仅含远程地址。重新扫描 Mac 的二维码可启用附近优先。" : pairing.remoteHost == nil ? "附近点对点 Wi-Fi" : "附近优先 · Tailscale 回退")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("重新连接 Mac") { Task { await connection.reconnect() } }.disabled(connection.connecting || saving)
                    }
                }
                if let error = connection.error { Section { Text(error).foregroundStyle(.red) } }
                Section {
                    Text("附近连接无需热点，开启 Wi-Fi 并允许本地网络访问即可。远程连接需要两台设备连接 Tailscale。配对信息保存在 iPhone 钥匙串。")
                    Text("切到后台后设备连接会暂停，回到 App 时恢复。应用负责保存和恢复自己的任务。")
                }
            }.navigationTitle("设备连接与配对").toolbar { Button("完成") { dismiss() } }
        }
    }
}
