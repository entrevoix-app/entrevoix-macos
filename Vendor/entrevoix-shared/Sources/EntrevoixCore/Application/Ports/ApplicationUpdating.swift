import Foundation

@MainActor
public protocol ApplicationUpdating: AnyObject {
    func start(channel: UpdateChannel)
    func setChannel(_ channel: UpdateChannel)
    func checkForUpdates()
}
