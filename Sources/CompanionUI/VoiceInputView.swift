#if os(iOS)
import SwiftUI
import CompanionCore

@MainActor final class PhoneVoiceStore: ObservableObject {
    enum Phase: Equatable { case idle, starting, recording, finishing }
    @Published var phase: Phase = .idle
    @Published var message = "先在电脑选中输入位置，再用手机开始录音。"
    @Published var ready = false
    @Published var level: Float = 0
    @Published var recordingStartedAt: Date?
    @Published var completedSessions = 0
    @Published var transcript: String?
    @Published var supportsLiveTranscript = false
    @Published var partialTranscript = ""
    private let destination: VoiceDestination
    private let microphone = PhoneMicrophone()
    private var work: Task<Void, Never>?
    private var session: String?
    private var link: CompanionLink?
    private var finishRequested = false
    init(destination: VoiceDestination = .cursor) { self.destination = destination; microphone.onLevel = { [weak self] value in Task { @MainActor in self?.level = value } } }
    private func request(_ command: VoiceCommand, link: CompanionLink) async throws -> VoiceStatus {
        var routed = command
        if destination == .draft { routed.destination = .draft }
        let packet = try await link.request(routed.packet(), timeout: command.action == "finish" ? .seconds(120) : .seconds(15))
        guard packet.error == nil, packet.status == 200, let body = packet.body else { throw CompanionError.server(packet.error ?? "Whisper Anywhere 未响应。") }
        return try JSONDecoder().decode(VoiceStatus.self, from: body)
    }
    func refresh(link: CompanionLink?) async {
        guard phase == .idle else { return }
        self.link = link; ready = false
        guard let link else { message = "请连接 Mac。"; return }
        do {
            let status = try await request(VoiceCommand("status"), link: link)
            guard destination != .draft || status.supportsDraft == true else { throw CompanionError.server("请更新 Mac 上的 Whisper Anywhere，以支持返回识别文字。") }
            supportsLiveTranscript = status.supportsLiveTranscript == true
            ready = status.ready && !status.busy; message = status.message
        }
        catch { message = error.localizedDescription }
    }
    func start(noiseReduction: Bool) {
        guard phase == .idle, ready, let link else { return }
        let id = UUID().uuidString; session = id; phase = .starting; finishRequested = false
        transcript = nil; partialTranscript = ""; message = "正在连接手机麦克风…"
        work = Task { [weak self] in
            guard let self else { return }
            do {
                // Permission/capture setup precedes target capture; no audio is
                // sent until the Mac owns the utterance.
                let stream = try await microphone.start(noiseReduction: noiseReduction)
                try Task.checkCancellation()
                _ = try await request(VoiceCommand("start", session: id), link: link)
                try Task.checkCancellation(); guard session == id else { throw CancellationError() }
                recordingStartedAt = Date(); phase = .recording; message = "正在录音 · 对着手机说话"
                var sequence = 0
                for try await event in stream {
                    try Task.checkCancellation()
                    guard case .audio(let audio) = event else { continue }
                    let update = try await request(VoiceCommand("audio", session: id, sequence: sequence, audio: audio), link: link)
                    guard session == id else { throw CancellationError() }
                    if destination == .draft, let text = update.transcript { partialTranscript = text }
                    sequence += 1
                }
                try Task.checkCancellation()
                guard finishRequested, session == id else { throw CancellationError() }
                let result = try await request(VoiceCommand("finish", session: id, sequence: sequence), link: link)
                guard session == id else { return }
                transcript = destination == .draft ? result.transcript : nil
                session = nil; phase = .idle; level = 0
                message = destination == .draft ? (transcript?.isEmpty == false ? "识别完成，文字已准备好。" : "没有识别到文字，请再试一次。") : "识别完成，请查看 Mac 输入位置。"; completedSessions += 1; work = nil
            } catch {
                guard session == id else { return }
                microphone.stop(flush: false)
                // Never finalize after failure, including lost finish replies.
                _ = try? await request(VoiceCommand("cancel", session: id), link: link)
                guard session == id else { return }
                session = nil; phase = .idle; level = 0; message = error.localizedDescription; work = nil
            }
        }
    }
    func finish() {
        guard phase == .recording else { return }
        finishRequested = true; phase = .finishing; message = "正在完成识别…"; microphone.stop(flush: true)
    }
    func cancel() {
        let id = session; let current = link
        session = nil; work?.cancel(); work = nil; microphone.stop(flush: false)
        phase = .idle; ready = false; level = 0; partialTranscript = ""; message = "本轮已取消。"
        if id != nil, let current { Task {
            _ = try? await current.request(RelayPacket(kind: "application_close", applicationID: CompanionApplication.whisper.id))
            if session == nil { await refresh(link: current) }
        } }
    }
}

public struct VoiceInputView: View {
    @ObservedObject private var connection: DeviceConnectionStore
    @StateObject private var store = PhoneVoiceStore()
    @AppStorage("app.whisper-anywhere.noiseReduction") private var noiseReduction = true
    @State private var settings = false
    @Environment(\.scenePhase) private var scenePhase
    public init(connection: DeviceConnectionStore) { self.connection = connection }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let teal = Color(red: 0.13, green: 0.67, blue: 0.67)
    private var recording: Bool { store.phase == .recording }
    private var idle: Bool { store.phase == .idle }
    private var heading: String {
        switch store.phase {
        case .idle: return store.ready ? "轻点，开始说话" : "准备手机麦克风"
        case .starting: return "正在连接…"
        case .recording: return "正在听你说"
        case .finishing: return "正在识别…"
        }
    }
    private var controlLabel: String {
        switch store.phase {
        case .idle: return "开始录音"
        case .starting: return "正在连接麦克风"
        case .recording: return "停止录音并输入"
        case .finishing: return "正在完成识别"
        }
    }
    public var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 0) {
                    Label(connection.state.title, systemImage: connection.connected ? "circle.fill" : "network")
                        .font(.caption).foregroundStyle(connection.connected ? teal : .secondary)
                        .padding(.top, 12)
                    Spacer(minLength: 40)
                    VStack(spacing: 14) {
                        Text("手机麦克风").font(.caption).foregroundStyle(.secondary)
                        Text(heading).font(.title2.weight(.semibold)).multilineTextAlignment(.center)
                            .accessibilityAddTraits(.updatesFrequently)
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(instruction(at: context.date))
                                .font(.subheadline).foregroundStyle(.secondary)
                                .multilineTextAlignment(.center).lineSpacing(5).monospacedDigit()
                        }.frame(minHeight: 52)
                    }
                    microphoneButton.padding(.top, 38).padding(.bottom, 30)
                    VoiceLevelBars(level: store.level, active: recording, reduceMotion: reduceMotion, tint: teal)
                        .frame(height: 30).accessibilityHidden(true)
                    Button("取消本轮", role: .destructive) { store.cancel() }
                        .font(.subheadline).foregroundStyle(.secondary).padding(.top, 20)
                        .opacity(idle ? 0 : 1).disabled(idle).accessibilityHidden(idle)
                    VStack(spacing: 12) {
                        if idle {
                            Text(store.message).font(.caption).foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                            if !store.ready {
                                Button { Task { await store.refresh(link: connection.link) } } label: {
                                    Label("检查 Mac 状态", systemImage: "arrow.clockwise")
                                }.font(.caption).tint(teal)
                            }
                        }
                    }.padding(.top, 18).frame(minHeight: 62)
                    Spacer(minLength: 40)
                    Text("声音在 Mac 本地识别\n手机不显示转写内容")
                        .font(.caption2).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).lineSpacing(4).padding(.bottom, 24)
                }.padding(.horizontal, 30).frame(maxWidth: .infinity)
                    .frame(minHeight: geometry.size.height)
            }.background(Color(uiColor: .systemGroupedBackground))
        }
        .navigationTitle("Whisper Anywhere").navigationBarTitleDisplayMode(.inline)
        .toolbar { Button { settings = true } label: { Image(systemName: "gearshape") }.accessibilityLabel("语音输入设置") }
        .sensoryFeedback(.success, trigger: store.completedSessions)
        .sheet(isPresented: $settings) {
            NavigationStack {
                Form {
                    Toggle("语音降噪", isOn: $noiseReduction).disabled(store.phase != .idle)
                    Text("使用 iPhone 内置麦克风和系统语音处理。可关闭降噪比较识别效果。识别语言和模型在 Mac 的 Whisper Anywhere 中设置。")
                }.navigationTitle("语音输入设置").toolbar { Button("完成") { settings = false } }
            }
        }
        .task(id: "\(connection.revision)-\(connection.applicationRevisions[CompanionApplication.whisper.id, default: 0])") {
            store.cancel()
            guard connection.applications.contains(where: { $0.id == CompanionApplication.whisper.id && $0.enabled }) else { await store.refresh(link: nil); return }
            await store.refresh(link: connection.link)
        }
        .onDisappear { store.cancel() }
        .onChange(of: scenePhase) { _, phase in if phase != .active { store.cancel() } }
    }
    private func instruction(at date: Date) -> String {
        switch store.phase {
        case .idle: return "先在 Mac 选好输入位置\n然后轻点下方麦克风"
        case .starting: return "正在准备手机麦克风\n请稍候"
        case .recording:
            let elapsed = max(0, Int(date.timeIntervalSince(store.recordingStartedAt ?? date)))
            return String(format: "录音 %02d:%02d\n轻点停止图标，结束并输入", elapsed / 60, elapsed % 60)
        case .finishing: return "正在 Mac 上完成本轮识别\n稍等片刻"
        }
    }
    private var microphoneButton: some View {
        Button {
            if recording { store.finish() }
            else if idle { store.start(noiseReduction: noiseReduction) }
        } label: {
            ZStack {
                if recording {
                    Circle().stroke(teal.opacity(0.08), lineWidth: 14).frame(width: 188, height: 188)
                    Circle().stroke(teal.opacity(0.16), lineWidth: 1).frame(width: 174, height: 174)
                        .scaleEffect(reduceMotion ? 1 : 1 + CGFloat(min(store.level * 2, 0.09)))
                }
                Circle().fill(LinearGradient(colors: [teal, Color(red: 0.09, green: 0.55, blue: 0.65)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 146, height: 146)
                    .shadow(color: teal.opacity(0.2), radius: 16, y: 9)
                switch store.phase {
                case .idle: Image(systemName: "mic").font(.system(size: 49, weight: .regular))
                case .recording: RoundedRectangle(cornerRadius: 8).frame(width: 33, height: 33)
                case .starting, .finishing: ProgressView().tint(.white).scaleEffect(1.5)
                }
            }.foregroundStyle(.white).frame(width: 200, height: 200)
                .opacity(idle && !store.ready ? 0.45 : 1)
                .contentShape(Circle())
        }.buttonStyle(VoiceMicrophoneButtonStyle(reduceMotion: reduceMotion))
            .disabled(store.phase == .starting || store.phase == .finishing || (idle && !store.ready))
            .accessibilityLabel(controlLabel)
            .accessibilityHint(recording ? "结束本轮录音，向 Mac 光标处输入识别文字" : "使用 iPhone 麦克风录音")
            .sensoryFeedback(.impact(weight: .light), trigger: store.phase)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: store.level)
    }
}

private struct VoiceMicrophoneButtonStyle: ButtonStyle {
    let reduceMotion: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: configuration.isPressed)
    }
}

private struct VoiceLevelBars: View {
    let level: Float
    let active: Bool
    let reduceMotion: Bool
    let tint: Color
    var body: some View {
        TimelineView(.animation(minimumInterval: 0.1, paused: !active || reduceMotion)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 5) {
                ForEach(0..<21) { index in
                    let amplitude = active ? min(Double(level) * 12, 1) : 0
                    let variation = reduceMotion ? 0.7 : 0.4 + 0.6 * abs(sin(time * 4 + Double(index) * 0.8))
                    Capsule().fill(active ? tint : Color.secondary.opacity(0.22))
                        .frame(width: 4, height: 4 + 25 * amplitude * variation)
                }
            }
        }
    }
}
#endif
