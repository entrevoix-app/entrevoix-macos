import AppKit
import CloudKit
import Foundation

extension Notification.Name {
    static let cleanupLibraryCloudChange = Notification.Name("cleanupLibraryCloudChange")
}

final class EntrevoixAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_: Notification) {
        NSApplication.shared.registerForRemoteNotifications()
    }

    func application(_: NSApplication, didReceiveRemoteNotification userInfo: [String: Any]) {
        guard let notification = CKNotification(fromRemoteNotificationDictionary: userInfo) as? CKQueryNotification,
              notification.subscriptionID == CleanupLibraryCloudSync.subscriptionID else { return }
        NotificationCenter.default.post(name: .cleanupLibraryCloudChange, object: nil)
    }
}
