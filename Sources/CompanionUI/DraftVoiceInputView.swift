#if os(iOS)
import SwiftUI
import CompanionCore

/// Uses the same phone microphone and Whisper service as cursor dictation,
/// with an explicit destination and a capability check before recording.
struct DraftVoiceInputView: View {
    let link: CompanionLink?
    let onTranscript: (String) -> Void
    @StateObject private var store = PhoneVoiceStore(destination: .draft)
    @AppStorage("app.whisper-anywhere.noiseReduction") private var noiseReduction = true
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    private var idle: Bool { store.phase == .idle }
    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()
                Image(systemName: store.phase == .recording ? "waveform" : "mic.fill")
                    .font(.system(size: 46)).foregroundStyle(.tint)
                    .symbolEffect(.pulse, isActive: store.phase == .recording)
                Text(heading).font(.title2.bold())
                Text(store.message).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                if store.phase == .recording {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let seconds = max(0, Int(context.date.timeIntervalSince(store.recordingStartedAt ?? context.date)))
                        Text(String(format: "%02d:%02d", seconds / 60, seconds % 60)).font(.title3.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    ProgressView(value: Double(min(store.level * 12, 1))).frame(maxWidth: 180)
                }
                if store.phase == .starting || store.phase == .finishing { ProgressView() }
                Button {
                    if store.phase == .recording { store.finish() }
                    else if idle { store.start(noiseReduction: noiseReduction) }
                } label: {
                    Label(store.phase == .recording ? "结束并填入草稿" : "开始说话", systemImage: store.phase == .recording ? "stop.fill" : "mic.fill")
                        .font(.headline).padding(.horizontal, 16).padding(.vertical, 10)
                }.buttonStyle(.borderedProminent)
                    .disabled(store.phase == .starting || store.phase == .finishing || (idle && !store.ready))
                if idle && !store.ready {
                    Button("检查 Whisper Anywhere") { Task { await store.refresh(link: link) } }
                }
                Spacer()
                Text("声音在 Mac 的 Whisper Anywhere 中识别。\n识别文字追加到当前草稿，由你检查后发送。")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }.padding(28).frame(maxWidth: .infinity)
                .background(Color(uiColor: .systemGroupedBackground))
                .navigationTitle("Quenda 语音输入").navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("取消") { store.cancel(); dismiss() } }
        }
        .presentationDetents([.medium, .large])
        .task(id: link.map(ObjectIdentifier.init)) { store.cancel(); await store.refresh(link: link) }
        .onChange(of: store.completedSessions) { _, _ in
            guard let text = store.transcript?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return }
            onTranscript(text); dismiss()
        }
        .onChange(of: scenePhase) { _, phase in if phase == .background { store.cancel() } }
        .onDisappear { store.cancel() }
    }
    private var heading: String {
        switch store.phase {
        case .idle: return "把想法说给 Quenda"
        case .starting: return "正在准备麦克风…"
        case .recording: return "正在听你说"
        case .finishing: return "Mac 正在完成识别…"
        }
    }
}
#endif
