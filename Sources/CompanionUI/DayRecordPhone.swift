#if os(iOS)
import Foundation
import AVFoundation
import Combine
import CompanionCore

@MainActor public final class DayRecordPhoneStore: ObservableObject {
    public let store = DayRecordStore()
    @Published public private(set) var running = false
    @Published public private(set) var retaining = false
    @Published public private(set) var starting = false
    @Published public private(set) var interrupted = false
    @Published public private(set) var speechDetected = false
    @Published public private(set) var completedUploads = 0
    @Published public private(set) var audioInputs: [MicrophoneInput] = []
    @Published public private(set) var preferredInputID = ""
    @Published public private(set) var activeInputName: String?
    public func selectAudioInput(_ id: String) {
        preferredInputID = id; microphone.selectInput(id)
    }
    private var recordingRequested = false
    @Published public private(set) var partial = ""
    @Published public private(set) var captureStatus = "准备好时，开始记录今天"
    @Published public private(set) var clips: [URL] = []
    @Published public private(set) var retentionEnd: Date?
    private let microphone = PhoneMicrophone()
    private let sink = RetainedAudio()
    private var link: CompanionLink?
    private var work: Task<Void, Never>?
    private var retentionTimer: Task<Void, Never>?
    private var player: AVAudioPlayer?
    @Published public private(set) var pendingSeconds: Double = 0
    @Published public private(set) var uploading = false
    @Published public private(set) var lastUploadedAt: Date?
    private var uploadTask: Task<Void, Never>?
    private var outbox: DayRecordOutbox?
    private var retryTask: Task<Void, Never>?
    @Published public private(set) var queuedCount = 0
    @Published public private(set) var queuedBytes: Int64 = 0
    private var capturing = false
    public var clipsDirectory: URL { store.library.directory.appendingPathComponent("Clips", isDirectory: true) }
    public init() {
        do { outbox = try DayRecordOutbox(directory: store.library.directory.appendingPathComponent("PendingAudio")); updateQueueStatus() }
        catch { store.error = "待转写缓存无法打开：" + error.localizedDescription }
        loadClips(); preferredInputID = microphone.preferredInputID
        microphone.onInputChange = { [weak self] inputs, name in
            self?.audioInputs = inputs; self?.activeInputName = name
        }
        microphone.publishInputs()
    }
    public func attach(link: CompanionLink?) {
        if self.link !== link { retryTask?.cancel(); retryTask = nil }
        self.link = link; store.attach(link: link)
        if link == nil, running { captureStatus = "Mac 已断开 · 语音暂存，重连后补传" }
        if link != nil { uploadPending() }
    }
    public func start(retain: Bool = false) {
        guard !running, !starting else { if retain { beginRetention() }; return }
        guard outbox != nil else { store.error = "待转写缓存不可用，请重新打开 App。"; return }
        starting = true; speechDetected = false; completedUploads = 0; recordingRequested = true; interrupted = false; player?.stop(); player = nil
        work = Task {
            var segmenter = DayRecordSegmenter()
            do {
                // The built-in SoundAnalysis model can lose GPU access on screen lock.
                var detector = SpeechActivityDetector(backend: .silero); try await detector.prepare()
                microphone.onPCM = { [self, sink] data, date in
                    do { try sink.append(data, capturedAt: date) }
                    catch { Task { @MainActor in self.store.error = error.localizedDescription; self.endRetention() } }
                }
                let stream = try await microphone.start(noiseReduction: false, bufferedChunks: 96, resumeAfterInterruption: true)
                try Task.checkCancellation(); starting = false; running = true; capturing = true
                if retain { beginRetention() }
                captureStatus = "等待说话 · 仅在手机检测"
                for try await event in stream {
                    try Task.checkCancellation()
                    switch event {
                    case .interrupted, .waiting:
                        capturing = false; interrupted = true; speechDetected = false; endRetention()
                        if let tail = segmenter.flush() { try enqueue(tail) }
                        segmenter.reset(); pendingSeconds = 0
                        captureStatus = "音频被其他应用占用 · 等待自动恢复"
                        continue
                    case .resumed:
                        guard recordingRequested else { continue }
                        if interrupted {
                            detector = SpeechActivityDetector(backend: .silero); try await detector.prepare()
                        }
                        interrupted = false; capturing = true
                        captureStatus = "已恢复采集 · 等待说话"
                        continue
                    case .audio: break
                    }
                    guard case .audio(let audio) = event else { continue }
                    let speech = try await detector.speech(in: audio)
                    if speechDetected != speech { speechDetected = speech }
                    let segments = try segmenter.append(audio, speech: speech, end: Date())
                    pendingSeconds = segmenter.seconds
                    for segment in segments { try enqueue(segment) }
                    if !uploading {
                        let message = link == nil ? "离线记录 · 语音暂存，重连后补传" : pendingSeconds > 0 ? "正在采集 · 停顿后发送，最长 60 秒" : "等待说话 · 无语音时不上传"
                        if captureStatus != message { captureStatus = message }
                    }
                }
                if let final = segmenter.flush() { try enqueue(final) }
            } catch {
                if !(error is CancellationError) { store.error = error.localizedDescription; captureStatus = "记录已暂停：" + error.localizedDescription }
                if let tail = segmenter.flush() { do { try enqueue(tail) } catch { store.error = error.localizedDescription } }
            }
            capturing = false; recordingRequested = false; interrupted = false; speechDetected = false
            microphone.stop(flush: false); microphone.onPCM = nil; pendingSeconds = 0; endRetention()
            running = false; starting = false; partial = ""; work = nil
            await store.refresh()
        }
    }
    private func updateQueueStatus() { queuedCount = outbox?.count ?? 0; queuedBytes = outbox?.bytes ?? 0 }
    private func enqueue(_ segment: DayRecordAudioSegment) throws {
        guard let outbox else { throw CompanionError.server("待转写缓存不可用，已暂停采集。") }
        try outbox.append(segment); updateQueueStatus(); uploadPending()
    }
    public func retryUploads() { retryTask?.cancel(); retryTask = nil; uploadPending() }
    private func uploadPending() {
        guard uploadTask == nil, retryTask == nil, link != nil, let outbox, outbox.count > 0 else { return }
        uploadTask = Task {
            defer {
                uploadTask = nil; uploading = false; updateQueueStatus()
                if outbox.count > 0, link != nil {
                    scheduleUploadRetry()
                }
            }
            while let link = self.link, !Task.isCancelled {
                do {
                    uploading = true; if !interrupted { captureStatus = "正在补传并转写 · \(outbox.count) 段待完成" }
                    guard let (segment, reply) = try await outbox.deliverFirst(send: { segment in
                        var request = DayRecordRequest("segment"); request.segment = segment
                        return try await DayRecordStore.send(request, link: link)
                    }, save: { entries in
                        for entry in entries { try self.store.library.merge([entry], day: DayRecordLibrary.day(entry.date)) }
                    }) else { break }
                    updateQueueStatus()
                    partial = reply.transcript ?? ""; completedUploads += 1; lastUploadedAt = Date(); store.reload()
                    // Do not trigger a present-day recording action from yesterday's deferred speech.
                    if capturing, segment.date.timeIntervalSinceNow > -120,
                       DayRecordPolicy.keyword(in: partial, settings: store.settings) != nil { beginRetention() }
                    if capturing { captureStatus = "上一段已识别 · 继续采集" }
                } catch {
                    store.error = "待转写音频已保留，连接可用时会重试：" + error.localizedDescription
                    if capturing { captureStatus = "语音已暂存 · 等待补传" }
                    break
                }
            }
        }
    }
    private func scheduleUploadRetry() {
        retryTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            self?.retryTask = nil; self?.uploadPending()
        }
    }
    public func pause() {
        guard running || starting else { return }
        capturing = false; recordingRequested = false; speechDetected = false
        microphone.stop(flush: true); endRetention(); captureStatus = "正在保存剩余片段…"
        if starting { work?.cancel() }
    }
    public func beginRetention() {
        guard capturing, !retaining else { return }
        do {
            _ = try sink.start(directory: clipsDirectory, seconds: store.settings.retentionMinutes * 60)
            retaining = true; retentionEnd = Date().addingTimeInterval(Double(store.settings.retentionMinutes * 60))
            retentionTimer = Task {
                do { try await Task.sleep(for: .seconds(store.settings.retentionMinutes * 60)); endRetention() } catch {}
            }
        } catch { store.error = error.localizedDescription }
    }
    public func endRetention() {
        retentionTimer?.cancel(); retentionTimer = nil
        do { try sink.stop() } catch { store.error = error.localizedDescription }
        retaining = false; retentionEnd = nil; loadClips()
    }
    public func play(_ url: URL) {
        guard !running, clips.contains(url) else { return }
        do { player = try AVAudioPlayer(contentsOf: url); player?.play() } catch { store.error = error.localizedDescription }
    }
    public func delete(_ url: URL) {
        guard !retaining, clips.contains(url) else { return }
        do { player?.stop(); try FileManager.default.removeItem(at: url); loadClips() } catch { store.error = error.localizedDescription }
    }
    private func loadClips() {
        clips = ((try? FileManager.default.contentsOfDirectory(at: clipsDirectory, includingPropertiesForKeys: [.creationDateKey])) ?? []).filter { $0.pathExtension == "wav" }.sorted { creation($0) > creation($1) }
    }
    public func creation(_ url: URL) -> Date { (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast }
}
#endif
