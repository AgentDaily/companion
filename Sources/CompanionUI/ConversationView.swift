import SwiftUI
import CompanionCore
import UniformTypeIdentifiers
#if os(iOS)
import PhotosUI
import ImageIO
import UIKit
#endif

public struct ConversationView: View {
    @ObservedObject var store: QuendaStore
    let sessionID: String
    let voiceLink: CompanionLink?
    @State private var draft = ""
    @State private var sending = false
    @State private var attachments: [OutgoingAttachment] = []
    @State private var importing = false
    @State private var filePicker = false
    @State private var inputError: String?
    @State private var atBottom = true
    @State private var loadingHistory = false
    #if os(iOS)
    @State private var photos: [PhotosPickerItem] = []
    @StateObject private var voice = PhoneVoiceStore(destination: .draft)
    @State private var voiceBase = ""
    @State private var voiceStartTask: Task<Void, Never>?
    @FocusState private var inputFocused: Bool
    @AppStorage("app.whisper-anywhere.noiseReduction") private var noiseReduction = true
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceVoiceMotion
    #endif
    public init(store: QuendaStore, sessionID: String, voiceLink: CompanionLink? = nil) { self.store = store; self.sessionID = sessionID; self.voiceLink = voiceLink }
    public var body: some View {
        VStack(spacing: 0) {
            if let error = store.error {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                    Text(error).font(.callout).textSelection(.enabled)
                    Spacer()
                    Button("重连") { Task { await store.reconnect() } }.disabled(store.connecting || sending)
                }.padding(14).background(Color.orange.opacity(0.08))
            }
            transcript
            composer
        }
        .navigationTitle(store.sessions.first { $0.id == sessionID }?.displayTitle ?? "会话")
        .task(id: sessionID) { await store.open(sessionID) }
        .onDisappear { Task { await store.leave(sessionID) } }
        .fileImporter(isPresented: $filePicker, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            do { try importFiles(result.get()) } catch { inputError = error.localizedDescription }
        }
        #if os(iOS)
        .task(id: voiceLink.map(ObjectIdentifier.init)) { cancelVoice(); await voice.refresh(link: voiceLink) }
        .onChange(of: voice.phase) { old, new in
            if old != .idle && new == .idle && voice.transcript == nil { inputError = voice.message }
        }
        .onChange(of: voice.partialTranscript) { _, text in
            guard voiceActive, !text.isEmpty else { return }
            draft = joinedVoice(text)
        }
        .onChange(of: voice.completedSessions) { _, _ in
            if let text = voice.transcript, !text.isEmpty { draft = joinedVoice(text) }
        }
        .onChange(of: scenePhase) { _, phase in if phase == .background { cancelVoice() } }
        .onDisappear { cancelVoice() }
        .onChange(of: photos) { _, items in
            guard !items.isEmpty else { return }
            importing = true
            Task {
                defer { importing = false; photos = [] }
                do {
                    for item in items {
                        guard let data = try await item.loadTransferable(type: Data.self), let source = CGImageSourceCreateWithData(data as CFData, nil),
                              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 1600] as CFDictionary) else { throw CompanionError.server("无法读取照片，请选择其他图片。") }
                        let resized = UIImage(cgImage: thumbnail)
                        guard let jpeg = resized.jpegData(compressionQuality: 0.8) else { throw CompanionError.server("图片转换失败。") }
                        try append(OutgoingAttachment(name: "照片-\(UUID().uuidString.prefix(6)).jpg", mediaType: "image/jpeg", data: jpeg))
                    }
                } catch { inputError = error.localizedDescription }
            }
        }
        #endif
    }
    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    if store.hasEarlier {
                        Button(loadingHistory ? "正在加载…" : "加载更早消息") {
                            loadingHistory = true
                            let first = store.messages.first?.id
                            Task { await store.loadEarlier(); if let first { proxy.scrollTo(first, anchor: .top) }; loadingHistory = false }
                        }.frame(maxWidth: .infinity).disabled(loadingHistory)
                    }
                    if store.messages.isEmpty && !store.generating {
                        ContentUnavailableView("开始这次对话", systemImage: "bubble.left.and.bubble.right", description: Text("发送想法、选择照片或附上文件，让 Mac 上的 Quenda 帮你处理。"))
                            .padding(.top, 36)
                    }
                    ForEach(store.messages.filter { $0.role != "tool" }) { ChatMessageRow(message: $0, store: store, sessionID: sessionID).id($0.id) }
                    if store.generating || !store.streamedText.isEmpty { streamingCard }
                    ForEach(store.permissions) { permission in permissionCard(permission) }
                    ForEach(store.interactions, id: \.self) { interaction in InteractionCard(store: store, interaction: interaction) }
                    Color.clear.frame(height: 1).id("latest").onAppear { atBottom = true }.onDisappear { atBottom = false }
                }.padding(18).frame(maxWidth: 850).frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .overlay(alignment: .bottomTrailing) {
                if !atBottom {
                    Button { withAnimation { proxy.scrollTo("latest", anchor: .bottom) } } label: { Image(systemName: "arrow.down").padding(12).background(.regularMaterial, in: Circle()) }
                        .buttonStyle(.plain).padding(18).accessibilityLabel("回到最新消息")
                }
            }
            .onChange(of: store.messages.count) { _, _ in if atBottom && !loadingHistory { withAnimation { proxy.scrollTo("latest", anchor: .bottom) } } }
            .onChange(of: store.streamedText) { _, _ in if atBottom { proxy.scrollTo("latest", anchor: .bottom) } }
        }
    }
    private var streamingCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Image(systemName: "sparkles").foregroundStyle(.tint); Text("Quenda").font(.caption.bold()); if store.generating { ProgressView().controlSize(.small) }; Spacer() }
            if !store.streamedText.isEmpty { MessageContentView(content: store.streamedText).textSelection(.enabled) }
            else { Text(store.uploadProgress == nil ? "正在处理…" : "正在传输附件…").font(.callout).foregroundStyle(.secondary) }
            if !store.activityTitles.isEmpty {
                DisclosureGroup("工具活动 · \(store.activityTitles.count)") {
                    ForEach(Array(store.activityTitles.enumerated()), id: \.offset) { _, title in Label(title, systemImage: "gearshape").font(.caption).foregroundStyle(.secondary).padding(.vertical, 3) }
                }.font(.caption)
            }
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
    }
    private func permissionCard(_ permission: PendingPermission) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("需要你的许可", systemImage: "hand.raised.fill").font(.headline).foregroundStyle(.orange)
            Text(permission.summary.isEmpty ? "Agent 请求执行工具操作。" : permission.summary)
            DisclosureGroup("查看操作详情") {
                Text(String(decoding: (try? JSONEncoder().encode(permission.request)) ?? Data(), as: UTF8.self)).font(.caption.monospaced()).textSelection(.enabled)
            }.font(.caption)
            HStack {
                Button("拒绝", role: .destructive) { Task { await store.respond(permission: permission, allow: false) } }.buttonStyle(.bordered)
                Spacer()
                Button("允许本次") { Task { await store.respond(permission: permission, allow: true) } }.buttonStyle(.borderedProminent)
            }.disabled(!store.streamConnected)
        }.padding(18).background(Color.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 18))
    }
    private var composer: some View {
        VStack(alignment: .leading, spacing: 9) {
            if let inputError {
                HStack { Text(inputError).font(.caption).foregroundStyle(.orange); Spacer(); Button { self.inputError = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain) }
            }
            if !attachments.isEmpty { attachmentTray }
            if let progress = store.uploadProgress { ProgressView(value: progress) { Text("传输附件 · \(Int(progress * 100))%").font(.caption) } }
            VStack(alignment: .leading, spacing: 12) {
                #if os(iOS)
                TextField(voiceActive ? "正在听你说…" : "给 Quenda 发消息…", text: $draft, axis: .vertical)
                    .lineLimit(2...8).textFieldStyle(.plain).focused($inputFocused)
                    .foregroundStyle(voiceActive ? Color.secondary : Color.primary).disabled(sending || voiceActive)
                if voiceActive {
                    HStack(spacing: 7) {
                        Circle().fill(Color.accentColor).frame(width: 6, height: 6)
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            let seconds = max(0, Int(context.date.timeIntervalSince(voice.recordingStartedAt ?? context.date)))
                            Text(voice.phase == .finishing ? "正在完成识别…" : String(format: voice.supportsLiveTranscript ? "正在识别 · %02d:%02d" : "录音中 · %02d:%02d · 结束后识别", seconds / 60, seconds % 60)).font(.caption.monospacedDigit())
                        }
                        Button { cancelVoice() } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).accessibilityLabel("取消录音，保留原草稿")
                    }.foregroundStyle(.secondary)
                }
                #else
                TextField("给 Quenda 发消息…", text: $draft, axis: .vertical).lineLimit(2...8).textFieldStyle(.plain).disabled(sending)
                #endif
                HStack(spacing: 15) {
                    #if os(iOS)
                    PhotosPicker(selection: $photos, maxSelectionCount: max(1, AttachmentLimits.maximumCount - attachments.count), matching: .images) {
                        Image(systemName: "photo.on.rectangle").font(.title3)
                    }.disabled(sending || importing || attachments.count >= AttachmentLimits.maximumCount).accessibilityLabel("选择照片")
                    #endif
                    Button { filePicker = true } label: { Image(systemName: "paperclip").font(.title3) }.buttonStyle(.plain).disabled(sending || importing || attachments.count >= AttachmentLimits.maximumCount).accessibilityLabel("添加文件")
                    if importing { ProgressView().controlSize(.small) }
                    Spacer()
                    Text(store.streamConnected ? "连接 Mac" : "连接中…").font(.caption2).foregroundStyle(.secondary)
                    #if os(iOS)
                    Button { toggleVoice() } label: {
                        Group {
                            if voice.phase == .starting || voice.phase == .finishing { ProgressView().controlSize(.small) }
                            else if voice.phase == .recording {
                                TimelineView(.animation(minimumInterval: 0.08, paused: reduceVoiceMotion)) { context in
                                    let amplitude = min(Double(voice.level) * 18, 1)
                                    let time = context.date.timeIntervalSinceReferenceDate
                                    HStack(spacing: 3) {
                                        ForEach(0..<5) { index in
                                            let movement = reduceVoiceMotion ? 0.6 : abs(sin(time * 7 + Double(index) * 1.1))
                                            Capsule().frame(width: 3, height: 5 + (5 + amplitude * 14) * movement)
                                        }
                                    }.frame(width: 24, height: 24)
                                }
                            } else { Image(systemName: "mic").font(.title3) }
                        }.frame(width: 40, height: 40)
                            .foregroundStyle(voiceActive ? Color.white : Color.secondary)
                            .background(voiceActive ? Color.accentColor : Color.secondary.opacity(0.08), in: Circle())
                            .overlay {
                                if voice.phase == .recording {
                                    Circle().stroke(Color.accentColor.opacity(0.2), lineWidth: 3)
                                        .scaleEffect(1.12 + CGFloat(min(voice.level * 3, 0.16)))
                                        .animation(reduceVoiceMotion ? nil : .easeOut(duration: 0.1), value: voice.level)
                                }
                            }
                    }.buttonStyle(.plain).disabled(voiceLink == nil || sending || importing || voice.phase == .starting || voice.phase == .finishing)
                        .accessibilityLabel(voice.phase == .recording ? "结束录音并填入草稿" : "开始语音输入")
                    #endif
                    if store.generating && !sending {
                        Button { Task { await store.stop() } } label: { Image(systemName: "stop.fill").frame(width: 34, height: 34).background(Color.orange.opacity(0.12), in: Circle()) }.buttonStyle(.plain).disabled(!store.streamConnected).accessibilityLabel("停止回答")
                    } else {
                        Button { send() } label: {
                            Group { if sending { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.up").font(.headline) } }
                                .frame(width: 36, height: 36).foregroundStyle(.white).background(Color.accentColor, in: Circle())
                        }.buttonStyle(.plain).disabled((draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty) || !store.streamConnected || sending || importing || store.generating || voiceActive)
                            .keyboardShortcut(.return, modifiers: .command).accessibilityLabel("发送消息")
                    }
                }.foregroundStyle(.secondary)
            }.padding(15).background(.background, in: RoundedRectangle(cornerRadius: 20))
                .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Color.secondary.opacity(0.18)))
            #if os(iOS)
            Text("照片会压缩 · 最多 6 个附件 / 共 8 MB").font(.caption2).foregroundStyle(.secondary)
            #else
            Text("最多 6 个附件 / 共 8 MB · ⌘ Return 发送").font(.caption2).foregroundStyle(.secondary)
            #endif
        }.padding(.horizontal, 16).padding(.vertical, 12).frame(maxWidth: 850).frame(maxWidth: .infinity).background(.bar)
    }
    private var attachmentTray: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { attachment in
                    HStack(spacing: 8) {
                        #if os(iOS)
                        if attachment.mediaType.hasPrefix("image/"), let image = UIImage(data: attachment.data) {
                            Image(uiImage: image).resizable().scaledToFill().frame(width: 38, height: 38).clipShape(RoundedRectangle(cornerRadius: 7))
                        } else { Image(systemName: "doc").foregroundStyle(.tint) }
                        #else
                        Image(systemName: attachment.mediaType.hasPrefix("image/") ? "photo" : "doc").foregroundStyle(.tint)
                        #endif
                        VStack(alignment: .leading, spacing: 2) {
                            Text(attachment.name).font(.caption).lineLimit(1).frame(maxWidth: 130, alignment: .leading)
                            Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.data.count), countStyle: .file)).font(.caption2).foregroundStyle(.secondary)
                        }
                        Button { attachments.removeAll { $0.id == attachment.id } } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain).disabled(sending).accessibilityLabel("移除 \(attachment.name)")
                    }.padding(9).background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
    }
    private func append(_ attachment: OutgoingAttachment) throws {
        try AttachmentLimits.validate(attachments + [attachment]); attachments.append(attachment); inputError = nil
    }
    private func importFiles(_ urls: [URL]) throws {
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey])
            guard (values.fileSize ?? AttachmentLimits.maximumBytes + 1) <= AttachmentLimits.maximumBytes else { throw CompanionError.server("文件超过 8 MB，请选择较小的文件。") }
            try append(OutgoingAttachment(name: url.lastPathComponent, mediaType: values.contentType?.preferredMIMEType ?? "application/octet-stream", data: Data(contentsOf: url, options: .mappedIfSafe)))
        }
    }
    private var voiceActive: Bool {
        #if os(iOS)
        return voice.phase != .idle
        #else
        return false
        #endif
    }
    #if os(iOS)
    private func joinedVoice(_ text: String) -> String { voiceBase.isEmpty || voiceBase.hasSuffix("\n") ? voiceBase + text : voiceBase + "\n" + text }
    private func cancelVoice() {
        if voiceActive { draft = voiceBase }
        voiceStartTask?.cancel(); voiceStartTask = nil; voice.cancel()
    }
    private func toggleVoice() {
        if voice.phase == .recording { voice.finish(); return }
        guard !voiceActive else { return }
        inputFocused = false; voiceBase = draft; inputError = nil
        voiceStartTask?.cancel()
        voiceStartTask = Task {
            await voice.refresh(link: voiceLink)
            guard !Task.isCancelled else { return }
            guard voice.ready else { inputError = voice.message; return }
            voice.start(noiseReduction: noiseReduction)
        }
    }
    #endif
    private func send() {
        guard !voiceActive else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !attachments.isEmpty else { return }
        let files = attachments
        sending = true; inputError = nil
        Task {
            do { try await store.send(text, attachments: files); draft = ""; attachments = [] }
            catch { inputError = "内容已保留。恢复连接后请先检查历史，避免重复发送。" }
            sending = false
        }
    }
}

private struct InteractionCard: View {
    @ObservedObject var store: QuendaStore
    let interaction: JSONValue
    @State private var values: [String: String] = [:]
    @State private var selections: [String: Set<String>] = [:]
    @State private var submitting = false
    private var questions: [JSONValue] { interaction["questions"].array.isEmpty ? [interaction] : interaction["questions"].array }
    private func questionID(_ q: JSONValue) -> String { q["id"].text.isEmpty ? interaction["id"].text : q["id"].text }
    private var canSubmit: Bool {
        questions.allSatisfy { q in
            let id = questionID(q)
            let selected = selections[id] ?? []
            let hasText = !(values[id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if selected.contains("__other__") && !hasText { return false }
            return q["required"] == .bool(false) || !selected.isEmpty || hasText
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(interaction["title"].text.isEmpty ? "需要你的回复" : interaction["title"].text, systemImage: "questionmark.bubble").font(.headline)
            ForEach(Array(questions.enumerated()), id: \.offset) { _, q in
                let id = questionID(q)
                if questions.count > 1, !q["title"].text.isEmpty { Text(q["title"].text).font(.subheadline.bold()) }
                if !q["message"].text.isEmpty { Text(q["message"].text) }
                ForEach(q["options"].array, id: \.self) { option in
                    let optionID = option["id"].text
                    Button {
                        var chosen = selections[id] ?? []
                        if chosen.contains(optionID) { chosen.remove(optionID) }
                        else if q["multiple"].flag { chosen.insert(optionID) }
                        else { chosen = [optionID] }
                        selections[id] = chosen
                    } label: {
                        Label(option["label"].text, systemImage: (selections[id] ?? []).contains(optionID) ? "checkmark.circle.fill" : "circle")
                    }.buttonStyle(.bordered)
                }
                TextField("输入回复", text: Binding(get: { values[id] ?? "" }, set: { values[id] = $0 }), axis: .vertical).textFieldStyle(.roundedBorder)
            }
            Button("提交回复") {
                submitting = true
                Task {
                    let answers = questions.map { q -> JSONValue in
                        let id = questionID(q)
                        return .object(["question_id": .string(id), "selected_option_ids": .array((selections[id] ?? []).sorted().map(JSONValue.string)), "value": .string(values[id] ?? "")])
                    }
                    await store.answer(interaction: interaction, answers: answers); submitting = false
                }
            }.buttonStyle(.borderedProminent).disabled(!canSubmit || submitting || !store.streamConnected)
        }.padding().background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
    }
}

public struct NewSessionView: View {
    @ObservedObject var store: QuendaStore
    let onCreated: (String) -> Void
    let defaultAgent: String
    @Environment(\.dismiss) private var dismiss
    @State private var agent = ""
    @State private var workspace = ""
    @State private var projectSheet = false
    @State private var choices: [ModelChoice] = []
    @State private var modelID = ""
    @State private var modelError: String?
    @State private var creating = false
    @State private var error: String?
    public init(store: QuendaStore, defaultAgent: String = "quenda-code", onCreated: @escaping (String) -> Void) { self.store = store; self.defaultAgent = defaultAgent; self.onCreated = onCreated }
    public var body: some View {
        NavigationStack {
            Form {
                Picker("Agent", selection: $agent) { ForEach(store.agents) { Text($0.name).tag($0.id) } }
                Section("项目") {
                    Picker("项目", selection: $workspace) { Text("无项目").tag(""); ForEach(store.workspaces) { Text($0.name).tag($0.id) } }
                    Button { projectSheet = true } label: { Label("新建项目", systemImage: "folder.badge.plus") }.disabled(creating)
                }
                Section("模型") {
                    Picker("模型", selection: $modelID) { Text("Agent 默认模型").tag(""); ForEach(choices) { Text($0.provider_name + " / " + $0.model_name).tag($0.id) } }
                    if let modelError { Text(modelError).font(.caption).foregroundStyle(.secondary) }
                }
                if let error { Text(error).foregroundStyle(.red) }
                Button("创建会话") {
                    creating = true
                    Task {
                        do { let choice = choices.first { $0.id == modelID }; let id = try await store.create(agent: agent, workspace: workspace, provider: choice?.provider_id, model: choice?.model_id); dismiss(); onCreated(id) }
                        catch { self.error = error.localizedDescription }
                        creating = false
                    }
                }.disabled(agent.isEmpty || creating || !store.connected)
            }.formStyle(.grouped).navigationTitle("新会话").toolbar { Button("取消") { dismiss() } }
            .onAppear { agent = store.agents.first { $0.id == defaultAgent }?.id ?? store.agents.first?.id ?? "" }
            .task(id: agent) {
                guard !agent.isEmpty else { return }
                let requested = agent; choices = []; modelID = ""; modelError = nil
                do { let models = try await store.models(agent: requested); if requested == agent && !Task.isCancelled { choices = models } }
                catch { if requested == agent && !Task.isCancelled { modelError = "无法读取模型目录，可使用 Agent 默认模型。" } }
            }
            .sheet(isPresented: $projectSheet) { NewProjectView(store: store) { workspace = $0.id } }
        }.frame(minWidth: 300, minHeight: 260)
    }
}
