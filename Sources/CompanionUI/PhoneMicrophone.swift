#if os(iOS)
import AVFoundation
import UIKit
import Foundation
import CompanionCore

/// AVAudioSession/engine lifecycle stays on the main actor. Tap callbacks only
/// touch a bounded, locked buffer, so stop/restart cannot race engine mutation.
@MainActor final class PhoneMicrophone {
    private let audioSessionOwner = UUID()
    private var engine = AVAudioEngine()
    private let frames = MicrophoneAudioStream()
    private var observers: [NSObjectProtocol] = []
    private var recovery: RecordingRecovery?
    private var tapInstalled = false
    private var noiseReduction = false
    private var continuous = false
    private var routeUpdate: Task<Void, Never>?
    private var activeInputUID: String?
    var onInputChange: (([MicrophoneInput], String?) -> Void)?
    var preferredInputID: String { UserDefaults.standard.string(forKey: "microphone.preferredInputID") ?? "" }
    func selectInput(_ id: String) {
        UserDefaults.standard.set(id, forKey: "microphone.preferredInputID")
        if recovery?.status == .recording { rebuildForInputChange() }
        publishInputs()
    }
    func publishInputs() {
        let session = AVAudioSession.sharedInstance()
        onInputChange?((session.availableInputs ?? []).map(Self.describe), session.currentRoute.inputs.first?.portName)
    }
    private static func describe(_ port: AVAudioSessionPortDescription) -> MicrophoneInput {
        let kind: MicrophoneInput.Kind
        switch port.portType {
        case .builtInMic: kind = .builtIn
        case .bluetoothHFP, .bluetoothLE: kind = .bluetooth
        case .usbAudio: kind = .usb
        case .headsetMic, .lineIn: kind = .wired
        default: kind = .other
        }
        return MicrophoneInput(id: port.uid, name: port.portName, kind: kind)
    }
    private func rebuildForInputChange() {
        guard recovery?.status == .recording else { return }
        if continuous {
            recovery?.interruptionBegan(); recovery?.interruptionEnded(shouldResume: true)
        } else {
            // Short dictation must not continue a Mac cursor transaction across a gap.
            frames.fail(CompanionError.server("麦克风已切换，请重新开始本次语音输入。")); stop(flush: false)
        }
    }
    var onPCM: (@Sendable (Data, Date) -> Void)? { get { frames.pcmHandler } set { frames.pcmHandler = newValue } }
    var onLevel: (@Sendable (Float) -> Void)? { get { frames.levelHandler } set { frames.levelHandler = newValue } }

    func start(noiseReduction: Bool, bufferedChunks: Int = 24, resumeAfterInterruption: Bool = false) async throws -> AsyncThrowingStream<MicrophoneEvent, Error> {
        let permitted = await withCheckedContinuation { wait in AVAudioApplication.requestRecordPermission { wait.resume(returning: $0) } }
        guard permitted else { throw CompanionError.server("请在 iPhone 设置中允许 Companion 使用麦克风。") }
        try Task.checkCancellation()
        self.noiseReduction = noiseReduction; continuous = resumeAfterInterruption
        let stream = frames.open(capacity: bufferedChunks)
        let recovery = RecordingRecovery(activate: { [weak self] in try self?.activateHardware() }, suspend: { [weak self] in self?.suspendHardware() }, changed: { [weak self] status in
            guard let self else { return }
            switch status {
            case .recording: self.frames.resume()
            case .interrupted: self.frames.event(.interrupted)
            case .waiting: self.frames.event(.waiting)
            case .stopped: self.frames.finish()
            }
        })
        self.recovery = recovery
        observeSession()
        do { try recovery.start(); return stream }
        catch { stop(flush: false); throw error }
    }
    private func observeSession() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 0
            let reason = AVAudioSession.RouteChangeReason(rawValue: raw)
            MainActor.assumeIsolated {
                guard let self else { return }
                self.publishInputs()
                // Ignore changes caused by setCategory/setPreferredInput itself.
                let session = AVAudioSession.sharedInstance()
                let desired = MicrophoneInputSelection.preferred(in: (session.availableInputs ?? []).map(Self.describe), id: self.preferredInputID)
                let mismatch = desired != nil && desired?.id != session.currentRoute.inputs.first?.uid
                guard reason == .newDeviceAvailable || reason == .oldDeviceUnavailable || (reason == .routeConfigurationChange && mismatch) else { return }
                self.routeUpdate?.cancel()
                self.routeUpdate = Task { @MainActor [weak self] in
                    do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
                    guard let self else { return }
                    let session = AVAudioSession.sharedInstance()
                    let desired = MicrophoneInputSelection.preferred(in: (session.availableInputs ?? []).map(Self.describe), id: self.preferredInputID)
                    let actual = session.currentRoute.inputs.first?.uid
                    if !self.engine.isRunning || actual != self.activeInputUID || desired?.id != actual { self.rebuildForInputChange() }
                    self.publishInputs()
                }
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            let options = AVAudioSession.InterruptionOptions(rawValue: note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
            MainActor.assumeIsolated {
                guard let self else { return }
                if !self.continuous {
                    self.frames.fail(CompanionError.server("录音被系统中断，本轮已取消。")); self.stop(flush: false); return
                }
                switch type {
                case .began: self.recovery?.interruptionBegan()
                case .ended: self.recovery?.interruptionEnded(shouldResume: options.contains(.shouldResume))
                @unknown default: break
                }
            }
        })
        observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if self?.continuous == true { self?.recovery?.foreground() } }
        })
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { [weak self] note in
            guard let changedEngine = note.object as? AVAudioEngine else { return }
            // Delay until the current lifecycle transition finishes. Ignore old
            // engines and our own stop, which can also emit configuration changes.
            Task { @MainActor in
                guard let self, self.continuous, changedEngine === self.engine,
                      self.recovery?.status == .recording, !self.engine.isRunning else { return }
                self.recovery?.interruptionBegan()
                self.recovery?.interruptionEnded(shouldResume: true)
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.continuous else { return }
                self.recovery?.interruptionBegan(); self.recovery?.interruptionEnded(shouldResume: true)
            }
        })
    }
    private func activateHardware() throws {
        let session = AVAudioSession.sharedInstance()
        var options: AVAudioSession.CategoryOptions = [.defaultToSpeaker, .allowBluetoothHFP]
        if continuous { options.insert(.mixWithOthers) }
        try MicrophoneSessionOwnership.shared.activate(owner: audioSessionOwner) {
            try session.setCategory(.playAndRecord, mode: noiseReduction ? .voiceChat : .measurement, options: options)
            try session.setActive(true)
        }
        let available = session.availableInputs ?? []
        let preferred = MicrophoneInputSelection.preferred(in: available.map(Self.describe), id: preferredInputID)
        try session.setPreferredInput(available.first { $0.uid == preferred?.id })
        // Recreate the tap and converter using the current format after an interruption.
        engine = AVAudioEngine()
        do {
            try engine.inputNode.setVoiceProcessingEnabled(noiseReduction)
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false), let converter = AVAudioConverter(from: format, to: output) else { throw CompanionError.server("手机麦克风格式不可用。") }
            let frames = self.frames
            input.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, when in
                let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * 16000 / format.sampleRate) + 64)
                guard let converted = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else { return }
                var supplied = false; var error: NSError?
                converter.convert(to: converted, error: &error) { _, status in
                    if supplied { status.pointee = .noDataNow; return nil }
                    supplied = true; status.pointee = .haveData; return buffer
                }
                if let error { frames.fail(error); return }
                guard let floats = converted.floatChannelData?.pointee else { return }
                let chunk = Array(UnsafeBufferPointer(start: floats, count: Int(converted.frameLength)))
                let end = Date().addingTimeInterval(AVAudioTime.seconds(forHostTime: when.hostTime) - ProcessInfo.processInfo.systemUptime + Double(buffer.frameLength) / format.sampleRate)
                frames.append(chunk, end: end)
            }
            tapInstalled = true
            engine.prepare(); try engine.start()
            activeInputUID = session.currentRoute.inputs.first?.uid; publishInputs()
        } catch { suspendHardware(); throw error }
    }
    private func suspendHardware() {
        engine.stop()
        if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
        frames.suspend()
    }
    func stop(flush: Bool) {
        routeUpdate?.cancel(); routeUpdate = nil
        if !flush { frames.discardPending() }
        recovery?.stop(); recovery = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }; observers.removeAll()
        MicrophoneSessionOwnership.shared.release(owner: audioSessionOwner) {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
}

#endif
