import SwiftUI
import AppKit
import CoreImage.CIFilterBuiltins
import CompanionCore
import CompanionUI

@MainActor final class MacModel: ObservableObject {
    let registry: ApplicationRegistry
    let connection: MacConnectionStore
    let quenda = QuendaStore()
    let configuration = QuendaConfiguration()
    init() {
        registry = ApplicationRegistry()
        connection = MacConnectionStore(registry: registry)
        registerQuenda()
    }
    private func registerQuenda() {
        let application = configuration.application
        if let url = try? LocalGateway.validate(configuration.gateway) {
            registry.register(application) { QuendaApplicationSession(gateway: url, emit: $0) }
        }
    }
    func connectQuenda() async {
        do {
            let url = try LocalGateway.validate(configuration.gateway)
            await quenda.connect { QuendaBackend(gateway: url) }
        } catch { quenda.error = error.localizedDescription }
    }
    func applyQuendaConfiguration() async {
        registerQuenda(); connection.applicationChanged("quenda")
        await connectQuenda()
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    var onTermination: (() -> Void)?
    func applicationWillTerminate(_ notification: Notification) { onTermination?() }
    func applicationDidFinishLaunching(_ notification: Notification) { NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true) }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main struct QuendaCompanionMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = MacModel()
    var body: some Scene {
        WindowGroup("Companion", id: "main") {
            CompanionHome(model: model, connection: model.connection, configuration: model.configuration)
                .frame(minWidth: 880, minHeight: 600)
                .onAppear { delegate.onTermination = { model.connection.stop() } }
        }
        Settings { DeviceSettings(connection: model.connection).padding(24).frame(width: 480) }
        MenuBarExtra("Companion", systemImage: "app.connected.to.app.below.fill") { CompanionMenu(connection: model.connection) }
    }
}

private struct CompanionMenu: View {
    @ObservedObject var connection: MacConnectionStore
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Text(connection.running ? "手机连接已开启 · \(connection.peers) 台设备" : "手机连接未开启")
        Button("打开 Companion") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
        if connection.running { Button("关闭手机连接") { connection.stop() } }
        Divider(); Button("退出") { NSApp.terminate(nil) }
    }
}

private struct CompanionHome: View {
    let model: MacModel
    @ObservedObject var connection: MacConnectionStore
    @ObservedObject var configuration: QuendaConfiguration
    @State private var settings = false
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text("你的应用").font(.largeTitle.bold())
                    Text("在电脑和 iPhone 间使用你的应用，连接由 Companion 统一管理。").foregroundStyle(.secondary)
                    HStack {
                        Label(connection.status, systemImage: connection.running ? "checkmark.circle.fill" : "network")
                        Spacer()
                        Button("设备连接与配对") { settings = true }
                    }.padding().background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
                    NavigationLink(value: "quenda") {
                        ApplicationTile(application: .quenda, status: configuration.shared ? "已向配对的 iPhone 开放" : "仅在这台 Mac 使用")
                            .padding(.horizontal, 18).background(.background, in: RoundedRectangle(cornerRadius: 18))
                    }.buttonStyle(.plain)
                    Text("每个应用有独立设置。录音转录等新应用将在接入后显示于此。").font(.caption).foregroundStyle(.secondary)
                }.padding(32).frame(maxWidth: 820)
            }.navigationTitle("Companion")
            .toolbar { Button { settings = true } label: { Label("设备连接", systemImage: "network") } }
            .navigationDestination(for: String.self) { id in
                if id == "quenda" { QuendaMacView(model: model, store: model.quenda, configuration: model.configuration) }
            }
        }
        .sheet(isPresented: $settings) {
            DeviceSettings(connection: connection).padding(24).frame(width: 480)
            Button("完成") { settings = false }.padding(.bottom, 20)
        }
    }
}

private struct QuendaMacView: View {
    let model: MacModel
    @ObservedObject var store: QuendaStore
    @ObservedObject var configuration: QuendaConfiguration
    @State private var selection: String?
    @State private var creating = false
    @State private var settings = false
    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section {
                    Label(store.connected ? "Quenda 已连接" : "Quenda 未连接", systemImage: store.connected ? "checkmark.circle" : "exclamationmark.circle")
                        .foregroundStyle(store.connected ? .green : .secondary).font(.caption)
                }
                Section("会话") {
                    ForEach(store.sessions) { session in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(session.displayTitle).lineLimit(1)
                            Text(session.agent_name ?? session.agent_id).font(.caption).foregroundStyle(.secondary)
                        }.tag(session.id)
                    }
                }
            }.navigationTitle("Quenda")
            .toolbar {
                Button { creating = true } label: { Image(systemName: "square.and.pencil") }.disabled(!store.connected)
                Button { Task { do { try await store.refresh() } catch { store.error = error.localizedDescription } } } label: { Image(systemName: "arrow.clockwise") }.disabled(!store.connected)
                Button { settings = true } label: { Label("Quenda 设置", systemImage: "gearshape") }
            }.navigationSplitViewColumnWidth(min: 240, ideal: 280)
        } detail: {
            if let selection { ConversationView(store: store, sessionID: selection).id(selection) }
            else {
                VStack(spacing: 20) {
                    Image(systemName: "bubble.left.and.bubble.right.fill").font(.system(size: 48)).foregroundStyle(.tint)
                    Text("Quenda").font(.largeTitle)
                    Text("连接本机 Gateway，继续你的会话。").foregroundStyle(.secondary)
                    if let error = store.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                    if !store.connected { Button(store.connecting ? "正在连接…" : "连接 Quenda") { Task { await model.connectQuenda() } }.disabled(store.connecting) }
                    Button("Quenda 设置") { settings = true }
                }.padding(30)
            }
        }
        .task { if !store.connected { await model.connectQuenda() } }
        .sheet(isPresented: $creating) { NewSessionView(store: store, defaultAgent: configuration.defaultAgent) { selection = $0 }.frame(width: 450, height: 320) }
        .sheet(isPresented: $settings) { QuendaSettingsView(configuration: configuration) { await model.applyQuendaConfiguration() } }
    }
}

private struct DeviceSettings: View {
    @ObservedObject var connection: MacConnectionStore
    @State private var copied = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("设备连接与配对").font(.title2.bold())
            Label("优先使用附近点对点 Wi-Fi", systemImage: "wifi").font(.headline)
            Text("无需热点或互联网。开启两台设备的 Wi-Fi，并允许 Companion 访问本地网络。").foregroundStyle(.secondary)
            Toggle("附近不可用时允许 Tailscale 远程连接", isOn: $connection.remoteEnabled).disabled(connection.running || connection.starting)
            if connection.remoteEnabled {
                TextField("Mac 的 Tailscale IPv4 地址", text: $connection.host).textFieldStyle(.roundedBorder).disabled(connection.running || connection.starting)
            }
            HStack {
                if connection.running { Button("关闭手机连接") { connection.stop(); copied = false } }
                else { Button(connection.starting ? "正在开启…" : "开启手机连接") { Task { await connection.start() } }.disabled(connection.starting) }
                Text(connection.status).font(.caption).foregroundStyle(.secondary)
            }
            if !connection.remoteStatus.isEmpty { Text(connection.remoteStatus).font(.caption).foregroundStyle(.secondary) }
            if let pairing = connection.pairing {
                HStack(alignment: .top, spacing: 18) {
                    if let qr = qrImage(pairing.link) { Image(nsImage: qr).interpolation(.none).resizable().frame(width: 150, height: 150).padding(8).background(.white) }
                    VStack(alignment: .leading, spacing: 12) {
                        Text("所有应用共用这次设备配对").font(.caption.bold())
                        Text(pairing.remoteHost == nil ? "附近连接" : "附近优先 · Tailscale 回退").font(.caption)
                        Text("iPhone 相机扫码，或将配对链接粘贴到手机 App。").font(.caption)
                        Button(copied ? "已复制" : "复制配对链接") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(pairing.link, forType: .string); copied = true }
                        Text("已连接 \(connection.peers) 台设备").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text("配对链接包含访问密钥，请只保存到自己的设备。重置后旧链接立即失效。").font(.caption).foregroundStyle(.secondary)
                Button("重置配对密钥") { Task { await connection.rotateKey(); copied = false } }.disabled(connection.starting)
            }
            if let error = connection.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            Text("应用配置在各应用内管理。关闭窗口后 Companion 仍在菜单栏运行；电脑需要保持唤醒。").font(.caption).foregroundStyle(.secondary)
        }
    }
    private func qrImage(_ text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator(); filter.message = Data(text.utf8)
        guard let output = filter.outputImage, let image = CIContext().createCGImage(output.transformed(by: CGAffineTransform(scaleX: 6, y: 6)), from: output.extent.applying(CGAffineTransform(scaleX: 6, y: 6))) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
}
