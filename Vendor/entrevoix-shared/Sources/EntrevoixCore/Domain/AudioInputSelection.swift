import Foundation

/// A stable Core Audio input-device reference kept in preferences.
public struct AudioInputDeviceReference: Codable, Equatable, Hashable, Identifiable, Sendable {
    /// Core Audio's device UID, which survives device-ID changes across launches.
    public let uid: String
    /// The last name macOS reported for the device. It lets the UI identify a
    /// disconnected selection without treating the display name as an identifier.
    public let name: String

    public var id: String { uid }

    public init(uid: String, name: String) {
        self.uid = uid
        self.name = name
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.uid == rhs.uid
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(uid)
    }
}

/// The audio input behavior used for the next recording.
public enum AudioInputSelection: Codable, Equatable, Hashable, Sendable {
    /// Follow the macOS default input device.
    case systemDefault
    /// Always try this particular input device before considering the default.
    case device(AudioInputDeviceReference)
}

/// The current Core Audio input-device view used by the presentation layer.
public struct AudioInputDeviceSnapshot: Equatable, Sendable {
    public let devices: [AudioInputDeviceReference]
    public let defaultDeviceUID: String?

    public init(devices: [AudioInputDeviceReference], defaultDeviceUID: String?) {
        self.devices = devices
        self.defaultDeviceUID = defaultDeviceUID
    }
}

/// The effective input behavior after an audio recorder starts.
public enum AudioInputStartResult: Equatable, Sendable {
    case requestedInput
    case fellBackToSystemDefault
}
