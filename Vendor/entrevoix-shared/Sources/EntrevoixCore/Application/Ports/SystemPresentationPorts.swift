import Foundation

public enum PermissionStatus: Equatable, Sendable {
    case granted
    case denied
    case notDetermined
}

public enum MicrophonePermissionResetError: Error, Equatable, Sendable {
    case couldNotLaunch
    case commandFailed
}

@MainActor
public protocol MicrophonePermissionResetting: AnyObject {
    func resetMicrophonePermission() async throws(MicrophonePermissionResetError)
}

@MainActor
public protocol PermissionProviding: MicrophonePermissionRequesting, MicrophonePermissionResetting {
    var microphonePermission: PermissionStatus { get }
    var accessibilityPermission: PermissionStatus { get }
    func requestAccessibilityPermission()
}

@MainActor
public protocol HotkeyHandling: AnyObject {
    var onKeyDown: (() -> Void)? { get set }
    var onKeyUp: (() -> Void)? { get set }
    var onEscape: (() -> Void)? { get set }
}

@MainActor
public protocol LaunchAtLoginControlling: AnyObject {
    var isEnabled: Bool { get }
    func setEnabled(_ enabled: Bool) throws
}

public enum FeedbackEvent: Equatable, Sendable {
    case recordingStarted
    case recordingStopped
    case recordingCancelled
    case connectionTestSucceeded
    case error
}

@MainActor
public protocol FeedbackPlaying: AnyObject {
    func play(_ event: FeedbackEvent)
}
