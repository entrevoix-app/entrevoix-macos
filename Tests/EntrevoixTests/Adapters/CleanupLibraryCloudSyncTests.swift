import XCTest
@testable import Entrevoix
@testable import EntrevoixCore

final class CleanupLibraryCloudSyncTests: XCTestCase {
    @MainActor
    func testAppliesTheRemoteLibraryWhenOneExists() async {
        let remoteLibrary = CleanupLibrary(
            prompts: [CleanupPrompt(name: "Remote", systemImageName: "quote.bubble", instructions: "Use remote text.")],
            workflows: []
        )
        let store = CleanupLibraryCloudStoreSpy(remoteLibrary: remoteLibrary)
        let sync = CleanupLibraryCloudSync(store: store)
        let expectation = expectation(description: "remote library")
        sync.onRemoteLibrary = { library in
            XCTAssertEqual(library, remoteLibrary)
            expectation.fulfill()
        }

        sync.start(with: CleanupLibrary(prompts: [], workflows: []), publishingLocalLibraryWhenCloudIsEmpty: true)

        await fulfillment(of: [expectation], timeout: 1)
        XCTAssertTrue(store.savedLibraries.isEmpty)
    }

    @MainActor
    func testSeedsAnEmptyCloudLibraryOnlyWhenRequested() async {
        let localLibrary = CleanupLibrary(
            prompts: [CleanupPrompt(name: "Local", systemImageName: "quote.bubble", instructions: "Keep local text.")],
            workflows: []
        )
        let store = CleanupLibraryCloudStoreSpy(remoteLibrary: nil)
        let sync = CleanupLibraryCloudSync(store: store)

        sync.start(with: localLibrary, publishingLocalLibraryWhenCloudIsEmpty: true)

        await waitUntil { store.savedLibraries == [localLibrary] }
    }

    @MainActor
    func testPublishesLibraryUpdates() async {
        var preferences = AppPreferences()
        preferences.cleanupPrompts = [
            CleanupPrompt(name: "Published", systemImageName: "quote.bubble", instructions: "Publish this text.")
        ]
        let store = CleanupLibraryCloudStoreSpy(remoteLibrary: nil)
        let sync = CleanupLibraryCloudSync(store: store)

        sync.publish(preferences)

        await waitUntil {
            store.savedLibraries == [CleanupLibrary(prompts: preferences.cleanupPrompts, workflows: preferences.cleanupWorkflows)]
        }
    }

    @MainActor
    private func waitUntil(
        timeout: TimeInterval = 1,
        condition: @escaping @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            await Task.yield()
        }
        XCTAssertTrue(condition())
    }
}

@MainActor
final class CleanupLibraryCloudStoreSpy: CleanupLibraryCloudStoring {
    let remoteLibrary: CleanupLibrary?
    private(set) var savedLibraries: [CleanupLibrary] = []

    init(remoteLibrary: CleanupLibrary?) {
        self.remoteLibrary = remoteLibrary
    }

    func fetchLibrary() async throws -> CleanupLibrary? {
        remoteLibrary
    }

    func saveLibrary(_ library: CleanupLibrary) async throws {
        savedLibraries.append(library)
    }
}
