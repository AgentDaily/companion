import Foundation

/// Serializes the user's recording intent with system audio interruptions.
/// Hardware operations are injected so the notification-to-restart path is testable.
@MainActor public final class RecordingRecovery {
    public enum Status: Equatable { case recording, interrupted, waiting, stopped }
    public private(set) var requested = false
    public private(set) var status: Status = .stopped
    private let activate: () throws -> Void
    private let suspend: () -> Void
    private let changed: (Status) -> Void
    private var retry: Task<Void, Never>?
    private var generation = 0
    private var attempts = 0
    public init(activate: @escaping () throws -> Void, suspend: @escaping () -> Void, changed: @escaping (Status) -> Void) {
        self.activate = activate; self.suspend = suspend; self.changed = changed
    }
    deinit { retry?.cancel() }
    public func start() throws {
        guard !requested else { return }
        try activate(); requested = true; update(.recording)
    }
    public func stop() {
        generation += 1; retry?.cancel(); retry = nil
        requested = false; suspend(); update(.stopped)
    }
    public func interruptionBegan() {
        guard requested, status != .interrupted else { return }
        generation += 1; retry?.cancel(); retry = nil; attempts = 0
        suspend(); update(.interrupted)
    }
    public func interruptionEnded(shouldResume: Bool) {
        guard requested, status == .interrupted || status == .waiting else { return }
        if shouldResume { resume() } else {
            generation += 1; retry?.cancel(); retry = nil; update(.waiting)
        }
    }
    /// Some interruptions have no matching end notification. Try again when the
    /// user returns to the app, but never re-open after an explicit manual stop.
    public func foreground() {
        guard requested, status != .recording else { return }
        resume()
    }
    private func resume() {
        retry?.cancel(); retry = nil
        guard requested else { return }
        do { try activate(); attempts = 0; update(.recording) }
        catch {
            suspend(); update(.waiting)
            attempts += 1
            let delay = min(15, 1 << min(attempts - 1, 4))
            let current = generation
            retry = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                guard let self, self.requested, self.generation == current else { return }
                self.resume()
            }
        }
    }
    private func update(_ status: Status) { self.status = status; changed(status) }
}
