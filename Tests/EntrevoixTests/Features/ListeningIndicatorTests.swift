import AppKit
import EntrevoixCore
import Foundation
import XCTest
@testable import Entrevoix

final class ListeningIndicatorTests: XCTestCase {
    func testIndicatorPhaseUsesRequiredSystemColors() {
        XCTAssertTrue(ListeningIndicatorPhase.listening.color.isEqual(NSColor.systemRed))
        XCTAssertTrue(ListeningIndicatorPhase.processing.color.isEqual(NSColor.systemBlue))
    }

    func testSingleCardKeepsSelectorAndStatusCapsuleGeometryAtIntrinsicWidth() {
        let layout = ListeningIndicatorLayout(
            panelWidth: 128,
            selectorLabels: ["Rewrite this transcript in a concise professional style", "Studio USB Microphone"]
        )

        XCTAssertGreaterThan(layout.selectorCapsuleFrame.width, 128)
        XCTAssertEqual(layout.selectorCapsuleFrame.height, 28)
        XCTAssertEqual(layout.statusCapsuleFrame.height, 40)
        XCTAssertEqual(layout.statusCapsuleFrame.minY - layout.selectorCapsuleFrame.maxY, 4)
    }

    @MainActor
    func testSelectorLabelsUnderCombinedIntrinsicCapFitEachPopupTitleArea() throws {
        let (layout, promptControl, audioInputControl) = try hostedSelectorPopups(
            promptName: "Edit mode",
            microphoneName: "USB mic"
        )

        XCTAssertGreaterThan(layout.selectorCapsuleFrame.width, 128)
        XCTAssertLessThan(layout.selectorCapsuleFrame.width, ListeningIndicatorLayout.maximumWidth)
        XCTAssertTrue(layout.selectorLabels.allSatisfy { !$0.isTruncated })
        XCTAssertLessThanOrEqual(
            measuredLabelWidth("Edit mode"),
            try usableTitleWidth(of: promptControl)
        )
        XCTAssertLessThanOrEqual(
            measuredLabelWidth("USB mic"),
            try usableTitleWidth(of: audioInputControl)
        )
    }

    @MainActor
    func testSelectorLabelsOverCombinedIntrinsicCapTruncateWithinEachPopupTitleArea() throws {
        let promptName = String(repeating: "Long prompt label ", count: 30)
        let microphoneName = String(repeating: "Long microphone label ", count: 30)
        let (layout, promptControl, audioInputControl) = try hostedSelectorPopups(
            promptName: promptName,
            microphoneName: microphoneName
        )

        XCTAssertEqual(layout.selectorCapsuleFrame.width, ListeningIndicatorLayout.maximumWidth)
        XCTAssertTrue(layout.selectorLabels.allSatisfy(\.isTruncated))
        XCTAssertGreaterThan(
            measuredLabelWidth(promptName),
            try usableTitleWidth(of: promptControl)
        )
        XCTAssertGreaterThan(
            measuredLabelWidth(microphoneName),
            try usableTitleWidth(of: audioInputControl)
        )
    }

    func testCappedAsymmetricSelectorLabelsGiveRemainingWidthToLongLabel() {
        let promptName = "Mic"
        let microphoneName = String(repeating: "Long microphone label ", count: 30)
        let layout = ListeningIndicatorLayout(
            panelWidth: 128,
            selectorLabels: [promptName, microphoneName]
        )

        XCTAssertEqual(layout.selectorCapsuleFrame.width, ListeningIndicatorLayout.maximumWidth)
        XCTAssertEqual(layout.promptControlFrame.width, measuredLabelWidth(promptName) + 45)
        XCTAssertFalse(layout.selectorLabels[0].isTruncated)
        XCTAssertGreaterThan(layout.selectorLabels[1].availableWidth, layout.selectorLabels[0].availableWidth)
        XCTAssertTrue(layout.selectorLabels[1].isTruncated)
    }

    @MainActor
    func testMediumLabelsExpandToFitEachPopupTitleArea() throws {
        let promptName = String(repeating: "Medium prompt ", count: 2)
        let microphoneName = "Medium microphone "
        let (layout, promptControl, audioInputControl) = try hostedSelectorPopups(
            promptName: promptName,
            microphoneName: microphoneName
        )

        let promptTitleWidth = try usableTitleWidth(of: promptControl)
        let audioInputTitleWidth = try usableTitleWidth(of: audioInputControl)

        XCTAssertLessThan(layout.selectorCapsuleFrame.width, ListeningIndicatorLayout.maximumWidth)
        XCTAssertLessThanOrEqual(measuredLabelWidth(promptName), promptTitleWidth)
        XCTAssertLessThanOrEqual(measuredLabelWidth(microphoneName), audioInputTitleWidth)
        XCTAssertTrue(layout.selectorLabels.allSatisfy { !$0.isTruncated })
    }

    @MainActor
    func testHostedSelectorControlsReceiveAppKitHitTestsAndBackgroundPassesThrough() {
        let (promptLibrary, audioInput) = makeSelectorStores()
        let surface = ListeningIndicatorSelectorSurface()
        let panelWidth: CGFloat = 128
        let layout = ListeningIndicatorLayout(
            panelWidth: panelWidth,
            selectorLabels: ["Rewrite this transcript in a concise professional style", "Studio USB Microphone"]
        )
        let hostingView = ListeningIndicatorHostingView(rootView: ListeningIndicatorView(
            label: "Listening…",
            audioLevel: 0,
            panelWidth: panelWidth,
            phase: .listening,
            promptLibrary: promptLibrary,
            audioInput: audioInput,
            selectorSurface: surface
        ))
        hostingView.frame = NSRect(x: 0, y: 0, width: panelWidth, height: 72)
        let window = NSWindow(
            contentRect: hostingView.bounds,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.layoutIfNeeded()
        hostingView.layoutSubtreeIfNeeded()

        let promptAppKitPoint = NSPoint(
            x: layout.promptControlFrame.midX,
            y: hostingView.bounds.height - layout.promptControlFrame.midY
        )
        let audioInputAppKitPoint = NSPoint(
            x: layout.audioInputControlFrame.midX,
            y: hostingView.bounds.height - layout.audioInputControlFrame.midY
        )
        let backgroundAppKitPoint = NSPoint(
            x: layout.statusCapsuleFrame.midX,
            y: hostingView.bounds.height - layout.statusCapsuleFrame.midY
        )

        XCTAssertNotNil(hostingView.hitTest(promptAppKitPoint))
        XCTAssertNotNil(hostingView.hitTest(audioInputAppKitPoint))
        XCTAssertNil(hostingView.hitTest(backgroundAppKitPoint))
        XCTAssertGreaterThan(layout.selectorCapsuleFrame.width, panelWidth)
    }

    @MainActor
    func testSelectorHitRegionsClearWhenSelectorContentIsRemoved() {
        let (promptLibrary, audioInput) = makeSelectorStores()
        let surface = ListeningIndicatorSelectorSurface()
        let layout = ListeningIndicatorLayout(panelWidth: 200, selectorLabels: ["Prompt", "Microphone"])
        let hostingView = ListeningIndicatorHostingView(rootView: ListeningIndicatorView(
            label: "Listening…",
            audioLevel: 0,
            panelWidth: 200,
            phase: .listening,
            promptLibrary: promptLibrary,
            audioInput: audioInput,
            selectorSurface: surface
        ))
        hostingView.frame = NSRect(x: 0, y: 0, width: 200, height: 72)
        let window = NSWindow(contentRect: hostingView.bounds, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = hostingView
        window.layoutIfNeeded()
        hostingView.layoutSubtreeIfNeeded()

        let oldPromptAppKitPoint = NSPoint(
            x: layout.promptControlFrame.midX,
            y: hostingView.bounds.height - layout.promptControlFrame.midY
        )
        XCTAssertNotNil(hostingView.hitTest(oldPromptAppKitPoint))

        hostingView.rootView = ListeningIndicatorView(
            label: "Listening…",
            audioLevel: 0,
            panelWidth: 200,
            phase: .listening,
            selectorSurface: surface
        )
        hostingView.layoutSubtreeIfNeeded()

        XCTAssertNil(hostingView.hitTest(oldPromptAppKitPoint))
    }

    @MainActor
    func testReplacingSelectorContentClearsItsPreviousHitRegions() {
        let (oldPromptLibrary, oldAudioInput) = makeSelectorStores(promptName: "Edit", microphoneName: "Mic")
        let (newPromptLibrary, newAudioInput) = makeSelectorStores(
            promptName: "Rewrite this transcript in a concise professional style",
            microphoneName: "Studio USB Microphone"
        )
        let surface = ListeningIndicatorSelectorSurface()
        let oldLayout = ListeningIndicatorLayout(panelWidth: 200, selectorLabels: ["Edit", "Mic"])
        let newLayout = ListeningIndicatorLayout(
            panelWidth: 128,
            selectorLabels: ["Rewrite this transcript in a concise professional style", "Studio USB Microphone"]
        )
        let hostingView = ListeningIndicatorHostingView(rootView: ListeningIndicatorView(
            label: "Listening…",
            audioLevel: 0,
            panelWidth: oldLayout.selectorCapsuleFrame.width,
            phase: .listening,
            promptLibrary: oldPromptLibrary,
            audioInput: oldAudioInput,
            selectorSurface: surface
        ))
        hostingView.frame = NSRect(x: 0, y: 0, width: oldLayout.selectorCapsuleFrame.width, height: 72)
        let window = NSWindow(contentRect: hostingView.bounds, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = hostingView
        window.layoutIfNeeded()
        hostingView.layoutSubtreeIfNeeded()

        let oldAudioInputAppKitPoint = NSPoint(
            x: oldLayout.audioInputControlFrame.midX,
            y: hostingView.bounds.height - oldLayout.audioInputControlFrame.midY
        )
        XCTAssertNotNil(hostingView.hitTest(oldAudioInputAppKitPoint))

        hostingView.rootView = ListeningIndicatorView(
            label: "Listening…",
            audioLevel: 0,
            panelWidth: newLayout.selectorCapsuleFrame.width,
            phase: .listening,
            promptLibrary: newPromptLibrary,
            audioInput: newAudioInput,
            selectorSurface: surface
        )
        hostingView.frame.size.width = newLayout.selectorCapsuleFrame.width
        hostingView.layoutSubtreeIfNeeded()

        let newAudioInputAppKitPoint = NSPoint(
            x: newLayout.audioInputControlFrame.midX,
            y: hostingView.bounds.height - newLayout.audioInputControlFrame.midY
        )
        let oldAudioInputPoint = NSPoint(
            x: oldLayout.audioInputControlFrame.midX,
            y: oldLayout.audioInputControlFrame.midY
        )
        let newAudioInputPoint = NSPoint(
            x: newLayout.audioInputControlFrame.midX,
            y: newLayout.audioInputControlFrame.midY
        )
        XCTAssertFalse(newLayout.audioInputControlFrame.contains(oldAudioInputPoint))
        XCTAssertFalse(oldLayout.audioInputControlFrame.contains(newAudioInputPoint))
        XCTAssertNotNil(hostingView.hitTest(newAudioInputAppKitPoint))
    }

    @MainActor
    func testSelectorInteractionKeepsIndicatorPanelNonKeyAndNonMain() {
        let panel = ListeningIndicatorPanel(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 72),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        let surface = ListeningIndicatorSelectorSurface(promptAction: { _ in }, audioInputAction: { _ in })
        let layout = ListeningIndicatorLayout(panelWidth: 200, selectorLabels: ["Prompt", "Microphone"])
        surface.registerRenderedControls(
            promptFrame: layout.promptControlFrame,
            audioInputFrame: layout.audioInputControlFrame
        )

        XCTAssertFalse(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)
    }

    @MainActor
    func testSelectorOverlayPanelsRouteOverlappingWindowClicksWhileVisualPanelPassesThrough() throws {
        let visibleFrame = try XCTUnwrap(NSScreen.main?.visibleFrame)
        let visualPanel = ListeningIndicatorPanel(
            contentRect: .init(x: visibleFrame.midX - 100, y: visibleFrame.midY - 36, width: 200, height: 72),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        visualPanel.ignoresMouseEvents = true
        let selectorPanels = [ListeningIndicatorSelectorPanel(), ListeningIndicatorSelectorPanel()]
        selectorPanels[0].setFrame(.init(x: visualPanel.frame.minX + 12, y: visualPanel.frame.maxY - 24, width: 60, height: 20), display: false)
        selectorPanels[1].setFrame(.init(x: visualPanel.frame.maxX - 72, y: visualPanel.frame.maxY - 24, width: 60, height: 20), display: false)
        visualPanel.orderFrontRegardless()
        selectorPanels.forEach { $0.orderFrontRegardless() }

        XCTAssertTrue(visualPanel.ignoresMouseEvents)

        for selectorPanel in selectorPanels {
            XCTAssertFalse(selectorPanel.ignoresMouseEvents)
            XCTAssertFalse(selectorPanel.canBecomeKey)
            XCTAssertFalse(selectorPanel.canBecomeMain)
            XCTAssertNotNil(selectorPanel.contentView?.hitTest(.init(x: selectorPanel.frame.width / 2, y: selectorPanel.frame.height / 2)))
        }
        XCTAssertFalse(selectorPanels[0].frame.intersects(selectorPanels[1].frame))
        visualPanel.orderOut(nil)
        selectorPanels.forEach { $0.orderOut(nil) }
    }

    @MainActor
    func testHostedPopupControlsActivateConcreteItemsAndMutateLiveStores() throws {
        let firstPrompt = CleanupPrompt(name: "Draft", systemImageName: "wand.and.stars", instructions: "Draft text")
        let selectedPrompt = CleanupPrompt(name: "Polish", systemImageName: "wand.and.stars", instructions: "Polish text")
        let microphone = AudioInputDeviceReference(uid: "studio-usb", name: "Studio USB Microphone")
        let preferences = PreferencesStore(
            preferencesStore: PreferencesStoreSpy(),
            keychain: SecretStoreSpy(),
            initialPreferences: AppPreferences(
                audioInputSelection: .systemDefault,
                cleanupPrompts: [firstPrompt, selectedPrompt],
                activeCleanupSelection: .prompt(firstPrompt.id)
            )
        )
        let promptLibrary = PromptLibraryStore(
            preferencesModel: preferences,
            exportReader: EmptyPromptLibraryExportReader()
        )
        let audioInput = AudioInputStore(
            preferencesStore: preferences,
            deviceCatalog: AudioInputDeviceCatalogSpy(snapshot: .init(
                devices: [microphone],
                defaultDeviceUID: microphone.uid
            ))
        )
        let hostingView = ListeningIndicatorHostingView(rootView: ListeningIndicatorView(
            label: "Listening…",
            audioLevel: 0,
            panelWidth: 200,
            phase: .listening,
            promptLibrary: promptLibrary,
            audioInput: audioInput
        ))
        hostingView.frame = NSRect(x: 0, y: 0, width: 200, height: 72)
        let window = NSWindow(contentRect: hostingView.bounds, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = hostingView
        window.layoutIfNeeded()
        hostingView.layoutSubtreeIfNeeded()
        window.displayIfNeeded()

        let promptControl = try XCTUnwrap(hostedPopup(kind: .prompt, in: hostingView))
        let audioInputControl = try XCTUnwrap(hostedPopup(kind: .audioInput, in: hostingView))
        XCTAssertTrue(promptControl.window === window)
        XCTAssertTrue(audioInputControl.window === window)
        XCTAssertEqual(try XCTUnwrap(promptControl.menu?.item(at: 2)).title, selectedPrompt.name)
        XCTAssertEqual(try XCTUnwrap(audioInputControl.menu?.item(at: 2)).title, microphone.name)

        try XCTUnwrap(promptControl.menu).performActionForItem(at: 2)
        try XCTUnwrap(audioInputControl.menu).performActionForItem(at: 2)

        XCTAssertEqual(promptLibrary.activeSelection, CleanupTransformationSelection.prompt(selectedPrompt.id))
        XCTAssertEqual(audioInput.selection, AudioInputSelection.device(microphone))
    }

    @MainActor
    func testPromptWorkflowAndMicrophoneSelectionsPreserveValidationAndPersistence() {
        let prompt = CleanupPrompt(name: "Polish", systemImageName: "wand.and.stars", instructions: "Polish text")
        let workflow = CleanupWorkflow(name: "Editorial", promptIDs: [prompt.id])
        let microphone = AudioInputDeviceReference(uid: "built-in", name: "Built-in Microphone")
        let persistence = PreferencesStoreSpy()
        let preferences = PreferencesStore(
            preferencesStore: persistence,
            keychain: SecretStoreSpy(),
            initialPreferences: AppPreferences(
                cleanupPrompts: [prompt],
                cleanupWorkflows: [workflow],
                activeCleanupSelection: .prompt(prompt.id)
            )
        )
        let promptLibrary = PromptLibraryStore(
            preferencesModel: preferences,
            exportReader: EmptyPromptLibraryExportReader()
        )
        let audioInput = AudioInputStore(
            preferencesStore: preferences,
            deviceCatalog: AudioInputDeviceCatalogSpy(snapshot: .init(
                devices: [microphone],
                defaultDeviceUID: microphone.uid
            ))
        )
        promptLibrary.setActiveSelection(.prompt(prompt.id))
        promptLibrary.setActiveSelection(.workflow(workflow.id))
        audioInput.setSelection(.device(microphone))

        XCTAssertEqual(promptLibrary.activeSelection, .workflow(workflow.id))
        XCTAssertEqual(audioInput.selection, .device(microphone))
        XCTAssertEqual(persistence.saved.last?.activeCleanupSelection, .workflow(workflow.id))
        XCTAssertEqual(persistence.saved.last?.audioInputSelection, .device(microphone))
    }

    @MainActor
    func testGhostSelectorPopupsHaveNoChromeAndLeaveTheirCornerPixelsTransparent() throws {
        let (_, promptControl, audioInputControl) = try hostedSelectorPopups(
            promptName: "Prompt",
            microphoneName: "Microphone"
        )

        for popup in [promptControl, audioInputControl] {
            XCTAssertFalse(popup.isBordered)
            XCTAssertEqual(try alphaAtCorner(of: popup), 0, accuracy: 0.01)
        }
    }

    @MainActor
    func testConstrainedGhostSelectorsUseCompactSpacingWithoutChromeOverlap() throws {
        let layout = ListeningIndicatorLayout(
            panelWidth: 128,
            selectorLabels: [
                String(repeating: "Prompt ", count: 40),
                String(repeating: "Microphone ", count: 40)
            ]
        )
        let (_, promptControl, audioInputControl) = try hostedSelectorPopups(
            promptName: String(repeating: "Prompt ", count: 40),
            microphoneName: String(repeating: "Microphone ", count: 40)
        )

        XCTAssertFalse(layout.promptControlFrame.intersects(layout.audioInputControlFrame))
        XCTAssertEqual(
            layout.audioInputControlFrame.minX - layout.promptControlFrame.maxX,
            ListeningIndicatorLayout.selectorSpacing,
            accuracy: 0.01
        )
        XCTAssertFalse(promptControl.isBordered)
        XCTAssertFalse(audioInputControl.isBordered)
    }

    @MainActor
    func testDynamicGhostPopupRefreshUpdatesTitleAndPreservesTransparentDrawing() throws {
        let (_, popup, _) = try hostedSelectorPopups(
            promptName: "Draft",
            microphoneName: "Built-in Microphone"
        )

        popup.configure(
            title: "Polish",
            symbolName: "wand.and.stars",
            items: [ListeningIndicatorPopupItem(title: "Polish") {}]
        )

        XCTAssertEqual(popup.title, "Polish")
        XCTAssertEqual(popup.itemArray.map(\.title), ["Polish", "Polish"])
        XCTAssertFalse(popup.isBordered)
        XCTAssertEqual(try alphaAtCorner(of: popup), 0, accuracy: 0.01)
    }

    func testLongMicrophoneLayoutExpandsSelectorCapsule() {
        let shortLayout = ListeningIndicatorLayout(panelWidth: 128, selectorLabels: ["Edit", "Mic"])
        let longLayout = ListeningIndicatorLayout(
            panelWidth: 128,
            selectorLabels: ["Nettoyage", "Microphone « iPhone de Vincent Bathelier »"]
        )

        XCTAssertGreaterThan(longLayout.selectorCapsuleFrame.width, shortLayout.selectorCapsuleFrame.width)
        XCTAssertGreaterThan(longLayout.selectorCapsuleFrame.width, 320)
        XCTAssertTrue(longLayout.selectorLabels.allSatisfy { !$0.isTruncated })
        XCTAssertFalse(longLayout.promptControlFrame.intersects(longLayout.audioInputControlFrame))
    }

    @MainActor
    func testMenuTrackingFreezesPollingRejectsZeroAnchorThenResumesAtExternalMove() async throws {
        let sleeper = ControlledIndicatorSleep()
        let provider = CountingAnchorProvider(anchors: [
            ListeningIndicatorAnchor(point: NSPoint(x: 500, y: 500), source: .directCaret),
            ListeningIndicatorAnchor(point: .zero, source: .directCaret),
            ListeningIndicatorAnchor(point: NSPoint(x: 700, y: 500), source: .directCaret)
        ])
        let (promptLibrary, audioInput) = makeSelectorStores()
        let controller = ListeningIndicatorController(
            positionProvider: ListeningIndicatorPositionProvider(anchor: { provider.nextAnchor() }),
            audioLevelProvider: IndicatorAudioLevelSpy(),
            logger: AppLogStore(),
            positionPollingSleep: { duration in try await sleeper.sleep(for: duration) }
        )
        controller.configureSelectors(
            promptLibrary: promptLibrary,
            audioInput: audioInput,
            interfaceLocale: { .current }
        )
        controller.show(label: "Listening…", phase: .listening)
        await waitUntilPollingIsSuspended(sleeper)
        let panel = try XCTUnwrap(indicatorPanel())
        let originBeforeTracking = panel.frame.origin
        let menu = try XCTUnwrap(hostedPopup(kind: .prompt, in: panel.contentView!)?.menu)

        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: menu)
        sleeper.resume()
        await Task.yield()

        XCTAssertEqual(provider.callCount, 1)
        XCTAssertEqual(panel.frame.origin, originBeforeTracking)

        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: menu)
        await waitUntilPollingIsSuspended(sleeper)
        sleeper.resume()
        await waitUntilPollingIsSuspended(sleeper)

        XCTAssertEqual(provider.callCount, 2)
        XCTAssertEqual(panel.frame.origin, originBeforeTracking)

        sleeper.resume()
        await waitUntilPollingIsSuspended(sleeper)

        XCTAssertEqual(provider.callCount, 3)
        XCTAssertNotEqual(panel.frame.origin, originBeforeTracking)
        controller.hide()
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

    @MainActor
    private func makeSelectorStores(
        promptName: String = "Rewrite this transcript in a concise professional style",
        microphoneName: String = "Studio USB Microphone"
    ) -> (PromptLibraryStore, AudioInputStore) {
        let prompt = CleanupPrompt(
            name: promptName,
            systemImageName: "wand.and.stars",
            instructions: "Rewrite text"
        )
        let microphone = AudioInputDeviceReference(uid: "studio-usb", name: microphoneName)
        let preferences = PreferencesStore(
            preferencesStore: PreferencesStoreSpy(),
            keychain: SecretStoreSpy(),
            initialPreferences: AppPreferences(
                cleanupPrompts: [prompt],
                activeCleanupSelection: .prompt(prompt.id)
            )
        )
        return (
            PromptLibraryStore(
                preferencesModel: preferences,
                exportReader: EmptyPromptLibraryExportReader()
            ),
            AudioInputStore(
                preferencesStore: preferences,
                deviceCatalog: AudioInputDeviceCatalogSpy(snapshot: .init(
                    devices: [microphone],
                    defaultDeviceUID: microphone.uid
                ))
            )
        )
    }

    @MainActor
    private func hostedSelectorPopups(
        promptName: String,
        microphoneName: String
    ) throws -> (ListeningIndicatorLayout, ListeningIndicatorPopupButton, ListeningIndicatorPopupButton) {
        let (promptLibrary, audioInput) = makeSelectorStores(
            promptName: promptName,
            microphoneName: microphoneName
        )
        let layout = ListeningIndicatorLayout(
            panelWidth: 128,
            selectorLabels: [promptName, microphoneName]
        )
        let hostingView = ListeningIndicatorHostingView(rootView: ListeningIndicatorView(
            label: "Listening…",
            audioLevel: 0,
            panelWidth: layout.selectorCapsuleFrame.width,
            phase: .listening,
            promptLibrary: promptLibrary,
            audioInput: audioInput
        ))
        hostingView.frame = NSRect(
            x: 0,
            y: 0,
            width: layout.selectorCapsuleFrame.width,
            height: layout.statusCapsuleFrame.maxY
        )
        let window = NSWindow(
            contentRect: hostingView.bounds,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.layoutIfNeeded()
        hostingView.layoutSubtreeIfNeeded()
        window.displayIfNeeded()

        let promptControl = try XCTUnwrap(hostedPopup(kind: .prompt, in: hostingView))
        let audioInputControl = try XCTUnwrap(hostedPopup(kind: .audioInput, in: hostingView))
        promptControl.frame.size = layout.promptControlFrame.size
        audioInputControl.frame.size = layout.audioInputControlFrame.size

        return (layout, promptControl, audioInputControl)
    }

    private func measuredLabelWidth(_ label: String) -> CGFloat {
        ceil((label as NSString).size(withAttributes: [
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize)
        ]).width)
    }

    @MainActor
    private func usableTitleWidth(of popup: ListeningIndicatorPopupButton) throws -> CGFloat {
        let cell = try XCTUnwrap(popup.cell)
        return cell.titleRect(forBounds: popup.bounds).width
    }

    @MainActor
    private func alphaAtCorner(of popup: ListeningIndicatorPopupButton) throws -> CGFloat {
        let bitmap = try XCTUnwrap(popup.bitmapImageRepForCachingDisplay(in: popup.bounds))
        popup.cacheDisplay(in: popup.bounds, to: bitmap)
        return try XCTUnwrap(bitmap.colorAt(x: 1, y: 1)).alphaComponent
    }

    @MainActor
    private func indicatorPanel() -> ListeningIndicatorPanel? {
        NSApp.windows.compactMap { $0 as? ListeningIndicatorPanel }.last
    }

    private func directCaretAnchor() -> ListeningIndicatorAnchor {
        ListeningIndicatorAnchor(point: NSPoint(x: 100, y: 100), source: .directCaret)
    }

    @MainActor
    private func hostedPopup(
        kind: SelectorControlKind,
        in view: NSView
    ) -> ListeningIndicatorPopupButton? {
        if let popup = view as? ListeningIndicatorPopupButton, popup.kind == kind {
            return popup
        }
        for subview in view.subviews {
            if let popup = hostedPopup(kind: kind, in: subview) { return popup }
        }
        return nil
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

private extension NSRect {
    var center: NSPoint {
        NSPoint(x: midX, y: midY)
    }
}

private struct EmptyPromptLibraryExportReader: CleanupPromptExportReading {
    func readExport(at url: URL) throws(CleanupPromptImportError) -> CleanupPromptExport {
        .init(prompts: [])
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

@MainActor
private final class CountingAnchorProvider {
    private var anchors: [ListeningIndicatorAnchor]
    private(set) var callCount = 0

    init(anchors: [ListeningIndicatorAnchor]) {
        self.anchors = anchors
    }

    func nextAnchor() -> ListeningIndicatorAnchor {
        callCount += 1
        guard !anchors.isEmpty else {
            return ListeningIndicatorAnchor(point: .zero, source: .directCaret)
        }
        return anchors.removeFirst()
    }
}
