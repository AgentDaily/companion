import SwiftUI

public struct QuendaSettingsView: View {
    @ObservedObject private var configuration: QuendaConfiguration
    private let onSave: () async -> Void
    @State private var gateway: String
    @State private var shared: Bool
    @State private var agent: String
    @State private var saving = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    public init(configuration: QuendaConfiguration, onSave: @escaping () async -> Void = {}) {
        self.configuration = configuration; self.onSave = onSave
        _gateway = State(initialValue: configuration.gateway)
        _shared = State(initialValue: configuration.shared)
        _agent = State(initialValue: configuration.defaultAgent)
    }
    public var body: some View {
        NavigationStack {
            Form {
                #if os(macOS)
                Section("Mac 上的 Quenda") {
                    TextField("本机 Gateway 地址", text: $gateway)
                    Toggle("向配对的 iPhone 提供 Quenda", isOn: $shared)
                    Text("Quenda Gateway 独立运行。保存配置不会启动或停止它。").font(.caption).foregroundStyle(.secondary)
                }
                #else
                Section { Text("Gateway 地址与应用共享开关在 Mac 的 Quenda 设置中配置。").foregroundStyle(.secondary) }
                #endif
                Section("这台设备的偏好") {
                    TextField("新会话默认 Agent ID", text: $agent)
                    Text("默认 Agent 不可用时，使用列表中的第一个 Agent。").font(.caption).foregroundStyle(.secondary)
                }
                if let error { Text(error).foregroundStyle(.red) }
                Button(saving ? "正在保存…" : "保存设置") {
                    saving = true
                    Task {
                        let oldGateway = configuration.gateway, oldShared = configuration.shared, oldAgent = configuration.defaultAgent
                        do {
                            configuration.gateway = gateway; configuration.shared = shared; configuration.defaultAgent = agent
                            try configuration.save(); await onSave(); dismiss()
                        } catch {
                            configuration.gateway = oldGateway; configuration.shared = oldShared; configuration.defaultAgent = oldAgent
                            self.error = error.localizedDescription
                        }
                        saving = false
                    }
                }.disabled(saving)
            }
            .navigationTitle("Quenda 设置")
            .toolbar { Button("取消") { dismiss() } }
        }
        #if os(macOS)
        .frame(width: 480, height: 330)
        #endif
    }
}
