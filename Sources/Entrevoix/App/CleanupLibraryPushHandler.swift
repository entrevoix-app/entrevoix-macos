import AppKit
import CloudKit
import Foundation

extension Notification.Name {
    static let cleanupLibraryCloudChange = Notification.Name("cleanupLibraryCloudChange")
    static let dictationDictionaryCloudChange = Notification.Name("dictationDictionaryCloudChange")
}

enum CloudSyncChange: Equatable {
    case cleanupLibrary
    case dictationDictionary
}

enum CloudSyncPushRouter {
    static func change(forSubscriptionID subscriptionID: String?) -> CloudSyncChange? {
        switch subscriptionID {
        case CleanupLibraryCloudSync.subscriptionID: .cleanupLibrary
        case DictationDictionaryCloudSync.subscriptionID: .dictationDictionary
        default: nil
        }
    }
}

final class EntrevoixAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_: Notification) {
        NSApplication.shared.registerForRemoteNotifications()
    }

    func application(_: NSApplication, didReceiveRemoteNotification userInfo: [String: Any]) {
        guard let notification = CKNotification(fromRemoteNotificationDictionary: userInfo) as? CKQueryNotification else { return }
        switch CloudSyncPushRouter.change(forSubscriptionID: notification.subscriptionID) {
        case .cleanupLibrary:
            NotificationCenter.default.post(name: .cleanupLibraryCloudChange, object: CloudSyncChange.cleanupLibrary)
        case .dictationDictionary:
            NotificationCenter.default.post(name: .dictationDictionaryCloudChange, object: CloudSyncChange.dictationDictionary)
        case nil:
            break
        }
    }
}
