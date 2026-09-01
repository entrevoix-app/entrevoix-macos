import AppKit
import Foundation
import XCTest
@testable import Entrevoix

final class ListeningIndicatorTests: XCTestCase {
    func testIndicatorPhaseUsesRequiredSystemColors() {
        XCTAssertTrue(ListeningIndicatorPhase.listening.color.isEqual(NSColor.systemRed))
        XCTAssertTrue(ListeningIndicatorPhase.processing.color.isEqual(NSColor.systemBlue))
    }

    func testMicrophoneDisablesInheritedAudioLevelAnimationWhileCircleKeepsScaling() throws {
        let source = try String(contentsOf: listeningIndicatorControllerURL, encoding: .utf8)
        let circleStart = try XCTUnwrap(source.range(of: "Circle()"))
        let microphoneStart = try XCTUnwrap(
            source.range(of: "Image(systemName: \"mic.fill\")", range: circleStart.upperBound ..< source.endIndex)
        )
        let textStart = try XCTUnwrap(
            source.range(of: "Text(label)", range: microphoneStart.upperBound ..< source.endIndex)
        )

        let circleModifiers = source[circleStart.lowerBound ..< microphoneStart.lowerBound]
        XCTAssertTrue(circleModifiers.contains(".scaleEffect(circleScale)"))
        XCTAssertFalse(circleModifiers.contains(".animation(nil, value: audioLevel)"))

        let microphoneModifiers = source[microphoneStart.lowerBound ..< textStart.lowerBound]
        XCTAssertTrue(microphoneModifiers.contains(".animation(nil, value: audioLevel)"))
    }

    @MainActor
    func testDirectCaretShowFirstVisibleFrameIsRedListening() {
        let controller = makeIndicator(anchor: directCaretAnchor())

        controller.show(label: "Listening…", phase: .listening)

        assertFrame(
            controller.visibleFrames.only,
            label: "Listening…",
            phase: .listening,
            color: .systemRed
        )
    }

    @MainActor
    func testHiddenProcessingUpdateWaitsUntilRedListeningFrameIsVisible() async {
        let sleeper = ControlledIndicatorSleep()
        let anchor = ListeningIndicatorAnchor(
            point: NSPoint(x: 100, y: 100),
            source: .focusedTextElement
        )
        let controller = makeIndicator(anchor: anchor, sleeper: sleeper)

        controller.show(label: "Listening…", phase: .listening)
        await waitUntilPollingIsSuspended(sleeper)
        XCTAssertFalse(controller.isPanelVisible)

        controller.update(label: "Transcribing…", phase: .processing)
        sleeper.resume()
        await waitUntilPanelIsVisible(controller)

        XCTAssertEqual(controller.visibleFrames.count, 2)
        assertFrame(
            controller.visibleFrames[0],
            label: "Listening…",
            phase: .listening,
            color: .systemRed
        )
        assertFrame(
            controller.visibleFrames[1],
            label: "Transcribing…",
            phase: .processing,
            color: .systemBlue
        )
    }

    @MainActor
    func testVisibleListeningUpdateRendersBlueTranscribingFrame() {
        let controller = makeIndicator(anchor: directCaretAnchor())
        controller.show(label: "Listening…", phase: .listening)

        controller.update(label: "Transcribing…", phase: .processing)

        assertFrame(
            controller.visibleFrames.last,
            label: "Transcribing…",
            phase: .processing,
            color: .systemBlue
        )
    }

    @MainActor
    func testVisibleProcessingUpdateRendersBlueImprovingTextFrame() {
        let controller = makeIndicator(anchor: directCaretAnchor())
        controller.show(label: "Listening…", phase: .listening)
        controller.update(label: "Transcribing…", phase: .processing)

        controller.update(label: "Improving text…", phase: .processing)

        assertFrame(
            controller.visibleFrames.last,
            label: "Improving text…",
            phase: .processing,
            color: .systemBlue
        )
    }

    @MainActor
    func testReusedPanelFirstVisibleFrameResetsToRedListening() {
        let controller = makeIndicator(anchor: directCaretAnchor())
        controller.show(label: "Listening…", phase: .listening)
        controller.update(label: "Transcribing…", phase: .processing)
        controller.hide()

        controller.show(label: "Listening…", phase: .listening)

        assertFrame(
            controller.visibleFrames.only,
            label: "Listening…",
            phase: .listening,
            color: .systemRed
        )
    }

    @MainActor
    func testReduceMotionTransitionUsesDiscreteFramesWithoutAnimations() {
        let controller = makeIndicator(
            anchor: directCaretAnchor(),
            accessibilityReduceMotion: true
        )
        controller.show(label: "Listening…", phase: .listening)

        controller.update(label: "Transcribing…", phase: .processing)

        XCTAssertEqual(controller.visibleFrames.count, 2)
        assertFrame(
            controller.visibleFrames[0],
            label: "Listening…",
            phase: .listening,
            color: .systemRed
        )
        assertFrame(
            controller.visibleFrames[1],
            label: "Transcribing…",
            phase: .processing,
            color: .systemBlue
        )
        XCTAssertFalse(controller.visibleFrames[0].usesPhaseAnimation)
        XCTAssertFalse(controller.visibleFrames[0].usesAudioLevelAnimation)
        XCTAssertFalse(controller.visibleFrames[1].usesPhaseAnimation)
        XCTAssertFalse(controller.visibleFrames[1].usesAudioLevelAnimation)
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

    @MainActor
    private func waitUntilPanelIsVisible(
        _ controller: ListeningIndicatorController,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0 ..< 100 {
            if controller.isPanelVisible { return }
            await Task.yield()
        }
        XCTFail("Timed out waiting for the indicator panel to become visible.", file: file, line: line)
    }

    @MainActor
    private func makeIndicator(
        anchor: ListeningIndicatorAnchor,
        sleeper: ControlledIndicatorSleep? = nil,
        accessibilityReduceMotion: Bool = false
    ) -> ListeningIndicatorController {
        ListeningIndicatorController(
            positionProvider: ListeningIndicatorPositionProvider(anchor: { anchor }),
            audioLevelProvider: IndicatorAudioLevelSpy(),
            logger: AppLogStore(),
            positionPollingSleep: { duration in
                if let sleeper {
                    try await sleeper.sleep(for: duration)
                }
            },
            accessibilityReduceMotion: accessibilityReduceMotion
        )
    }

    private func directCaretAnchor() -> ListeningIndicatorAnchor {
        ListeningIndicatorAnchor(point: NSPoint(x: 100, y: 100), source: .directCaret)
    }

    private var listeningIndicatorControllerURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Sources/Entrevoix/Presentation/Features/ListeningIndicator/ListeningIndicatorController.swift")
    }

    private func assertFrame(
        _ frame: ListeningIndicatorRenderedFrame?,
        label: String,
        phase: ListeningIndicatorPhase,
        color: NSColor,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let frame else {
            XCTFail("Expected a rendered indicator frame.", file: file, line: line)
            return
        }
        XCTAssertEqual(frame.label, label, file: file, line: line)
        XCTAssertEqual(frame.phase, phase, file: file, line: line)
        XCTAssertTrue(frame.color.isEqual(color), file: file, line: line)
    }
}

private extension Array {
    var only: Element? {
        count == 1 ? self[0] : nil
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
