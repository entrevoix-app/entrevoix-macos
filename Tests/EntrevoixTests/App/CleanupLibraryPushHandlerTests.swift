import XCTest
@testable import Entrevoix

final class CleanupLibraryPushHandlerTests: XCTestCase {
    func testRoutesCleanupLibraryPushWithTypedChange() {
        XCTAssertEqual(
            CloudSyncPushRouter.change(forSubscriptionID: CleanupLibraryCloudSync.subscriptionID),
            CloudSyncChange.cleanupLibrary
        )
    }
}
