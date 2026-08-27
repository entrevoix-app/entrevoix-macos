import XCTest
@testable import Entrevoix

final class DictationDictionaryCloudSyncTests: XCTestCase {
    @MainActor
    func testAppliesTheRemoteTermsWhenTheyExist() async {
        let remoteTerms = ["Symfony", "CapRover"]
        let store = DictationDictionaryCloudStoreSpy(remoteTerms: remoteTerms)
        let sync = DictationDictionaryCloudSync(store: store)
        let expectation = expectation(description: "remote dictionary")
        sync.onRemoteTerms = { terms in
            XCTAssertEqual(terms, remoteTerms)
            expectation.fulfill()
        }

        sync.start(with: ["Local"], seedLocalTerms: true)

        await fulfillment(of: [expectation], timeout: 1)
        XCTAssertTrue(store.savedTerms.isEmpty)
    }

    @MainActor
    func testSeedsOnlyANonemptyLocalDictionary() async {
        let store = DictationDictionaryCloudStoreSpy(remoteTerms: nil)
        let sync = DictationDictionaryCloudSync(store: store)

        sync.start(with: ["  Symfony  ", "Symfony", "CapRover"], seedLocalTerms: true)

        await waitUntil { store.savedTerms == [["Symfony", "CapRover"]] }
    }

    @MainActor
    func testPublishesTermUpdatesAndTombstonesAgainstTheLastRemoteTerms() async {
        let store = DictationDictionaryCloudStoreSpy(remoteTerms: ["Symfony", "CapRover"])
        let sync = DictationDictionaryCloudSync(store: store)
        sync.start(with: [], seedLocalTerms: false)
        await waitUntil { store.didBootstrap }

        sync.publish(["Symfony Framework", "CapRover"])

        await waitUntil { store.savedTerms == [["Symfony Framework", "CapRover"]] }
        XCTAssertEqual(store.replacedTerms, [["Symfony", "CapRover"]])
    }

    @MainActor
    func testRefreshAppliesRemoteTermsWithoutRepublishingThem() async {
        let store = DictationDictionaryCloudStoreSpy(remoteTerms: ["Remote"])
        let sync = DictationDictionaryCloudSync(store: store)
        let expectation = expectation(description: "refreshed dictionary")
        sync.onRemoteTerms = { terms in
            guard terms == ["Remote"] else { return }
            expectation.fulfill()
        }

        sync.refresh()

        await fulfillment(of: [expectation], timeout: 1)
        XCTAssertTrue(store.savedTerms.isEmpty)
    }

    @MainActor
    private func waitUntil(timeout: TimeInterval = 1, condition: @escaping @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { await Task.yield() }
        XCTAssertTrue(condition())
    }
}

@MainActor
final class DictationDictionaryCloudStoreSpy: DictationDictionaryCloudStoring {
    let remoteTerms: [String]?
    private(set) var savedTerms: [[String]] = []
    private(set) var replacedTerms: [[String]?] = []
    private(set) var didBootstrap = false

    init(remoteTerms: [String]?) { self.remoteTerms = remoteTerms }

    func bootstrap(localTerms: [String], seedLocalTerms: Bool) async throws -> [String] {
        didBootstrap = true
        if remoteTerms == nil, seedLocalTerms { savedTerms.append(localTerms) }
        return remoteTerms ?? localTerms
    }

    func fetchTerms() async throws -> [String]? { remoteTerms }

    func saveTerms(_ terms: [String], replacing previousTerms: [String]?) async throws {
        savedTerms.append(terms)
        replacedTerms.append(previousTerms)
    }

    func ensureSubscription(id _: String) async throws {}
}
