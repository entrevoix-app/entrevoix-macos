import Foundation

/// A technical boundary for enumerating the locally available audio inputs.
@MainActor
public protocol AudioInputDeviceDiscovering: AnyObject {
    var onInputDevicesChanged: (() -> Void)? { get set }
    func snapshot() -> AudioInputDeviceSnapshot
}
