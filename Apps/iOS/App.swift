import SwiftUI
import CompanionCore
import CompanionUI

@main struct QuendaCompanionApp: App {
    init() {
        ConnectionDiagnostics.shared = .persisted()
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        ConnectionDiagnostics.shared.record("app.start", "version=\(version) build=\(build)")
    }
    @StateObject private var connection = DeviceConnectionStore()
    @StateObject private var quenda = QuendaStore()
    @StateObject private var configuration = QuendaConfiguration()
    @StateObject private var dayRecord = DayRecordPhoneStore()
    @Environment(\.scenePhase) private var scenePhase
    @State private var settings = false
    #if DEBUG
    @State private var diagnosticRunning = false
    #endif
    var body: some Scene {
        WindowGroup {
            PhoneHome(connection: connection, quenda: quenda, configuration: configuration, dayRecord: dayRecord, settings: $settings)
                .task {
                    #if DEBUG
                    if Self.diagnosticMode != nil { await runWirelessDiagnostic(); return }
                    #endif
                    connection.loadPairing()
                    if connection.pairing == nil { settings = true }
                    else { await connection.resume() }
                }
                .task(id: connection.revision) {
                    #if DEBUG
                    if Self.diagnosticMode != nil { return }
                    #endif
                    dayRecord.attach(link: connection.link)
                    guard connection.link != nil else { return }
                    await dayRecord.store.refresh(allDays: true)
                    while !Task.isCancelled {
                        do { try await Task.sleep(for: .seconds(60)) } catch { break }
                        await dayRecord.store.refresh(allDays: true)
                    }
                }
                .onChange(of: dayRecord.running) { _, running in
                    if !running && scenePhase == .background { connection.suspend() }
                }
                .onOpenURL { url in
                    Task {
                        do { try await connection.pair(link: url.absoluteString); settings = !connection.connected }
                        catch { connection.error = error.localizedDescription; settings = true }
                    }
                }
                .onChange(of: scenePhase) { _, phase in
                    #if DEBUG
                    if Self.diagnosticMode != nil {
                        ConnectionDiagnostics.shared.record("debug.awdl.scene", String(describing: phase))
                        if phase == .active && diagnosticRunning { UIApplication.shared.isIdleTimerDisabled = true }
                        if phase == .background {
                            ConnectionDiagnostics.shared.record("debug.awdl.interrupted", "background; result is inconclusive")
                            UIApplication.shared.isIdleTimerDisabled = false
                            connection.suspend()
                        }
                        return
                    }
                    #endif
                    if phase == .active { Task { await connection.resume() } }
                    if phase == .background { quenda.disconnect(); if !dayRecord.running { connection.suspend() } }
                }
        }
    }
    #if DEBUG
    // USB is used only for launching and collecting logs; discovery is AWDL-only.
    // Opt-in, bounded physical diagnostic. Normal app launches never enter this path.
    private static var diagnosticMode: String? {
        guard ProcessInfo.processInfo.environment["COMPANION_DIAGNOSTIC_AWDL_ONLY"] == "1" else { return nil }
        return ProcessInfo.processInfo.environment["COMPANION_DIAGNOSTIC_TRAFFIC"] == "1" ? "traffic" : "idle"
    }
    @MainActor private func runWirelessDiagnostic() async {
        guard let mode = Self.diagnosticMode else { return }
        diagnosticRunning = true
        UIApplication.shared.isIdleTimerDisabled = true
        defer { diagnosticRunning = false; UIApplication.shared.isIdleTimerDisabled = false; connection.suspend() }
        ConnectionDiagnostics.shared.record("debug.awdl.start", "mode=\(mode) run=\(ProcessInfo.processInfo.environment["COMPANION_DIAGNOSTIC_RUN"] ?? "manual")")
        connection.loadPairing()
        await connection.resume()
        guard let link = connection.link else {
            ConnectionDiagnostics.shared.record("debug.awdl.result", "FAIL initial connection"); return
        }
        let started = Date()
        do {
            for _ in 0..<18 {
                try await Task.sleep(for: .seconds(5))
                guard connection.link === link else { throw CompanionError.disconnected }
                if mode == "traffic" {
                    let apps = try await link.applications()
                    ConnectionDiagnostics.shared.record("debug.awdl.reply", "count=\(apps.count)")
                }
            }
            let apps = try await link.applications()
            ConnectionDiagnostics.shared.record("debug.awdl.result", "PASS seconds=\(Int(Date().timeIntervalSince(started))) count=\(apps.count)")
        } catch {
            ConnectionDiagnostics.shared.record("debug.awdl.result", "FAIL seconds=\(Int(Date().timeIntervalSince(started))) errorType=\(String(describing: type(of: error)))")
        }
    }
    #endif

}

private enum PhoneRoute: Hashable { case application(String), conversation(String) }

private struct PhoneHome: View {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var connection: DeviceConnectionStore
    @ObservedObject var quenda: QuendaStore
    @ObservedObject var configuration: QuendaConfiguration
    @ObservedObject var dayRecord: DayRecordPhoneStore
    @Binding var settings: Bool
    @State private var navigation: [PhoneRoute] = []
    private var quendaContext: QuendaConnectionContext {
        QuendaConnectionContext(revision: connection.revision, applicationRevision: connection.applicationRevisions["quenda", default: 0], active: navigation.contains(.application("quenda")), foreground: scenePhase != .background)
    }
    private var applications: [CompanionApplication] {
        let available = connection.applications.isEmpty ? [CompanionApplication.quenda] : connection.applications
        return available.contains(where: { $0.id == "24r" }) ? available : available + [.dayRecord]
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
                        if ["quenda", "whisper-anywhere", "24r"].contains(application.id) {
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
            .refreshable { await connection.refresh() }
            .navigationDestination(for: PhoneRoute.self) { route in
                switch route {
                case .application("24r"):
                    DayRecordView(store: dayRecord.store, capture: dayRecord)
                case .application("quenda"):
                    QuendaPhoneView(store: quenda, connection: connection, configuration: configuration) { navigation.append(.conversation($0)) }
                case .application("whisper-anywhere"):
                    if dayRecord.running {
                        VStack(spacing: 20) { Text("24R 正在使用麦克风"); Button("暂停 24R，使用语音输入") { dayRecord.pause() } }
                    } else { VoiceInputView(connection: connection) }
                case .conversation(let id): ConversationView(store: quenda, sessionID: id, voiceLink: dayRecord.running ? nil : connection.link)
                default: Text("请更新 Companion 以使用这个应用。")
                }
            }
            .onChange(of: navigation) { _, routes in
                if !routes.contains(.application("quenda")) { quenda.disconnect() }
            }
            .sheet(isPresented: $settings) { DevicePairingView(connection: connection) }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if navigation.last != .application("24r") {
                DayRecordRecordingBar(capture: dayRecord)
            }
        }
        .task(id: quendaContext) {
            guard quendaContext.active, let link = connection.link else { quenda.disconnect(); return }
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
        .sheet(isPresented: $settings) { QuendaSettingsView(configuration: configuration, store: store) }
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
                        Text(pairing.nearbyService == nil ? "此配对仅含远程地址。重新扫描 Mac 的二维码可启用附近优先。" : pairing.remoteHost == nil ? "附近连接" : "附近优先 · Tailscale 回退")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("重新连接 Mac") { Task { await connection.reconnect() } }.disabled(connection.connecting || saving)
                    }
                }
                if let error = connection.error { Section { Text(error).foregroundStyle(.red) } }
                Section("连接诊断") {
                    Text("版本 \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")（\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—")）")
                        .font(.caption).foregroundStyle(.secondary)
                    ShareLink("分享最近的连接记录", item: ConnectionDiagnostics.shared.summary)
                    Text("只包含发现、连接阶段和网络错误，不包含配对密钥、录音或对话内容。").font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    Text("附近连接请开启 Wi-Fi 并允许本地网络访问。目前建议两台设备接入同一局域网；无共同网络的直连仍在修复。远程连接需要两台设备连接 Tailscale。配对信息保存在 iPhone 钥匙串。")
                    Text("24R 记录期间保持音频会话与设备连接；其他情况下切到后台暂停连接，回到 App 恢复。")
                }
            }.navigationTitle("设备连接与配对").toolbar { Button("完成") { dismiss() } }
        }
    }
}
