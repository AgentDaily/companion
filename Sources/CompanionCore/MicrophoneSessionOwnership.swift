import Foundation

/// Shared app audio-session boundary; hardware calls are injected for lifecycle tests.
@MainActor public final class MicrophoneSessionOwnership {
    public static let shared = MicrophoneSessionOwnership()
    private var currentOwner: UUID?
    public init() {}
    public func activate(owner: UUID, operation: () throws -> Void) throws {
        guard currentOwner == nil || currentOwner == owner else {
            throw CompanionError.server("麦克风正在被另一个功能使用，请先暂停当前录音。")
        }
        try operation()
        currentOwner = owner
    }
    public func release(owner: UUID, operation: () -> Void) {
        guard currentOwner == owner else { return }
        operation()
        currentOwner = nil
    }
}
