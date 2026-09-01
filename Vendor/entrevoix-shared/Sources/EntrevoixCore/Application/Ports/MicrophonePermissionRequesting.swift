@MainActor
public protocol MicrophonePermissionRequesting: AnyObject {
    func requestMicrophonePermission() async -> Bool
}
