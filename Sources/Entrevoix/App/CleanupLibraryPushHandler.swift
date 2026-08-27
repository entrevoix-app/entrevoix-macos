import AppKit
import CloudKit
import Foundation

extension Notification.Name {
    static let cleanupLibraryCloudChange = Notification.Name("cleanupLibraryCloudChange")
    static let dictationDictionaryCloudChange = Notification.Name("dictationDictionaryCloudChange")
}

final class EntrevoixAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_: Notification) {
        NSApplication.shared.registerForRemoteNotifications()
    }

    func application(_: NSApplication, didReceiveRemoteNotification userInfo: [String: Any]) {
        guard let notification = CKNotification(fromRemoteNotificationDictionary: userInfo) as? CKQueryNotification else { return }
        switch notification.subscriptionID {
        case CleanupLibraryCloudSync.subscriptionID:
            NotificationCenter.default.post(name: .cleanupLibraryCloudChange, object: nil)
        case DictationDictionaryCloudSync.subscriptionID:
            NotificationCenter.default.post(name: .dictationDictionaryCloudChange, object: nil)
        default:
            return
        }
    }
}
