import AppKit
import XCTest
@testable import Entrevoix

final class ListeningIndicatorTests: XCTestCase {
    func testIndicatorPhaseUsesRequiredSystemColors() {
        XCTAssertTrue(ListeningIndicatorPhase.listening.color.isEqual(NSColor.systemRed))
        XCTAssertTrue(ListeningIndicatorPhase.processing.color.isEqual(NSColor.systemBlue))
    }

    @MainActor
    func testCancelledPositionPollingCannotRevealHiddenIndicator() async {
        let sleeper = ControlledIndicatorSleep()
        let controller = ListeningIndicatorController(
            positionProvider: ListeningIndicatorPositionProvider(anchor: {
                ListeningIndicatorAnchor(
                    point: .zero,
                    source: .accessibilityPermissionMissing
                )
            }),
            audioLevelProvider: IndicatorAudioLevelSpy(),
            logger: AppLogStore(),
            positionPollingSleep: { duration in try await sleeper.sleep(for: duration) }
        )

        controller.show(label: "Listening…", phase: .listening)
        await waitUntilPollingIsSuspended(sleeper)
        XCTAssertTrue(controller.isPanelVisible)

        controller.hide()
        XCTAssertFalse(controller.isPanelVisible)

        sleeper.resume()
        await Task.yield()

        XCTAssertFalse(controller.isPanelVisible)
    }

    func testNormalizesAndClipsDecibelRange() {
        XCTAssertEqual(
            ListeningIndicatorAudioLevelSmoother.normalizedLevel(from: -100),
            0,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            ListeningIndicatorAudioLevelSmoother.normalizedLevel(from: -64),
            0,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            ListeningIndicatorAudioLevelSmoother.normalizedLevel(from: -35),
            0.5,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            ListeningIndicatorAudioLevelSmoother.normalizedLevel(from: -6),
            1,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            ListeningIndicatorAudioLevelSmoother.normalizedLevel(from: 0),
            1,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            ListeningIndicatorAudioLevelSmoother.normalizedLevel(from: .nan),
            0,
            accuracy: 0.0001
        )
    }

    func testUsesFasterAttackAndSlowerRelease() {
        var smoother = ListeningIndicatorAudioLevelSmoother()

        XCTAssertEqual(smoother.update(decibels: -6), 0.65, accuracy: 0.0001)
        XCTAssertEqual(smoother.update(decibels: -6), 0.8775, accuracy: 0.0001)

        smoother.reset()
        _ = smoother.update(decibels: -6)
        XCTAssertEqual(smoother.update(decibels: -64), 0.4875, accuracy: 0.0001)
    }

    func testResetReturnsToSilentLevel() {
        var smoother = ListeningIndicatorAudioLevelSmoother()
        _ = smoother.update(decibels: -6)

        smoother.reset()

        XCTAssertEqual(smoother.level, 0, accuracy: 0.0001)
    }

    @MainActor
    private func waitUntilPollingIsSuspended(
        _ sleeper: ControlledIndicatorSleep,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0 ..< 100 {
            if sleeper.isSuspended { return }
            await Task.yield()
        }
        XCTFail("Timed out waiting for the position polling task.", file: file, line: line)
    }
}

@MainActor
private final class IndicatorAudioLevelSpy: AudioLevelProviding {
    func updateMeters() {}
    var averagePower: Float { -160 }
}

@MainActor
private final class ControlledIndicatorSleep {
    private var continuation: CheckedContinuation<Void, Never>?

    var isSuspended: Bool { continuation != nil }

    func sleep(for duration: Duration) async throws {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}
