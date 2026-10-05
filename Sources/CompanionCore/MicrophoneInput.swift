import Foundation

public struct MicrophoneInput: Identifiable, Equatable, Sendable {
    public enum Kind: Int, Sendable { case usb, wired, bluetooth, builtIn, other }
    public let id: String
    public let name: String
    public let kind: Kind
    public init(id: String, name: String, kind: Kind) { self.id = id; self.name = name; self.kind = kind }
}

public enum MicrophoneInputSelection {
    /// A remembered explicit selection wins when connected. Otherwise prefer
    /// an external input; do not mistake an output-only Bluetooth device for a mic.
    public static func preferred(in inputs: [MicrophoneInput], id: String) -> MicrophoneInput? {
        if !id.isEmpty, let selected = inputs.first(where: { $0.id == id }) { return selected }
        return inputs.sorted { $0.kind.rawValue == $1.kind.rawValue ? $0.id < $1.id : $0.kind.rawValue < $1.kind.rawValue }.first
    }
}
