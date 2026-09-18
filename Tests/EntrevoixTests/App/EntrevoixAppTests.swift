import XCTest
@testable import Entrevoix
@testable import EntrevoixCore

final class EntrevoixAppTests: XCTestCase {
    @MainActor
    func testScenesReceiveTheSharedSceneRootInjection() {
        let environment = AppEnvironment(appStore: AppStoreTests(selector: #selector(AppStoreTests.testInitializerAcceptsOnlyRequiredStoresAndActions)).makeContext().model)

        XCTAssertTrue(environment.sceneRoot.appStore === environment.appStore)
    }
}
