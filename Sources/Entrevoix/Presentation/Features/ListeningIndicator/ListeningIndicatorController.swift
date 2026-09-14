import AppKit
import EntrevoixCore
import Observation
import SwiftUI

enum ListeningIndicatorPhase: Equatable {
    case listening
    case processing

    var color: NSColor {
        switch self {
        case .listening: .systemRed
        case .processing: .systemBlue
        }
    }
}

struct ListeningIndicatorRenderedFrame {
    let label: String
    let phase: ListeningIndicatorPhase
    let color: NSColor
    let usesPhaseAnimation: Bool
    let usesAudioLevelAnimation: Bool
}

@MainActor
protocol ListeningIndicatorPresenting: AnyObject {
    func show(label: String, phase: ListeningIndicatorPhase)
    func update(label: String, phase: ListeningIndicatorPhase)
    func hide()
    func configureSelectors(
        promptLibrary: PromptLibraryStore,
        audioInput: AudioInputStore,
        interfaceLocale: @escaping () -> Locale
    )
}

extension ListeningIndicatorPresenting {
    func configureSelectors(
        promptLibrary _: PromptLibraryStore,
        audioInput _: AudioInputStore,
        interfaceLocale _: @escaping () -> Locale
    ) {}
}

@MainActor
final class ListeningIndicatorController: ListeningIndicatorPresenting {
    typealias Sleep = (Duration) async throws -> Void

    private static let minimumPanelSize = NSSize(width: 128, height: 40)
    private static let maximumPanelWidth: CGFloat = 320
    private static let panelHorizontalPadding: CGFloat = 24
    private static let iconWidth: CGFloat = 24
    private static let iconSpacing: CGFloat = 8
    private static let anchorSpacing: CGFloat = 8

    private let positionProvider: ListeningIndicatorPositionProvider
    private let audioLevelProvider: any AudioLevelProviding
    private let logger: any LogWriting
    private let positionPollingSleep: Sleep
    private let positionTracker: ListeningIndicatorPositionTracker
    private let audioMonitor: ListeningIndicatorAudioMonitor
    private var panel: NSPanel?
    private var hostingView: ListeningIndicatorHostingView?
    private var positionTrackingTask: Task<Void, Never>?
    private var positionTrackingSessionID: UUID?
    private var audioLevelTask: Task<Void, Never>?
    private var audioLevelSessionID: UUID?
    private var audioLevelSmoother = ListeningIndicatorAudioLevelSmoother()
    private var audioLevel: CGFloat = 0
    private var label = ""
    private var phase: ListeningIndicatorPhase = .listening
    private var panelSize = NSSize(width: 128, height: 40)
    private var loggedAnchorSource: ListeningIndicatorAnchor.Source?
    private var lastAnchor: ListeningIndicatorAnchor?
    private var pendingInitialAnchor: ListeningIndicatorAnchor?
    private var unresolvedInitialSampleCount = 0
    private var pendingDisplayUpdate: (label: String, phase: ListeningIndicatorPhase)?
    private var promptLibrary: PromptLibraryStore?
    private var audioInput: AudioInputStore?
    private var interfaceLocale: () -> Locale = { .current }
    private let selectorSurface = ListeningIndicatorSelectorSurface()
    private var isSelectorMenuTracking = false
    private let accessibilityReduceMotion: Bool?
    private(set) var isPanelVisible = false
    private(set) var visibleFrames: [ListeningIndicatorRenderedFrame] = []

    init(
        positionProvider: ListeningIndicatorPositionProvider = ListeningIndicatorPositionProvider(),
        audioLevelProvider: any AudioLevelProviding,
        logger: any LogWriting,
        positionPollingSleep: @escaping Sleep = { try await Task.sleep(for: $0) },
        accessibilityReduceMotion: Bool? = nil
    ) {
        self.positionProvider = positionProvider
        self.audioLevelProvider = audioLevelProvider
        self.logger = logger
        self.positionPollingSleep = positionPollingSleep
        self.accessibilityReduceMotion = accessibilityReduceMotion
        self.positionTracker = ListeningIndicatorPositionTracker(provider: positionProvider, logger: logger)
        self.audioMonitor = ListeningIndicatorAudioMonitor(provider: audioLevelProvider)
        selectorSurface.onMenuTrackingChanged = { [weak self] isTracking in
            self?.isSelectorMenuTracking = isTracking
        }
    }

    func show(label: String, phase: ListeningIndicatorPhase) {
        positionTrackingTask?.cancel()
        let positionTrackingSessionID = UUID()
        self.positionTrackingSessionID = positionTrackingSessionID
        audioLevelTask?.cancel()
        audioLevelTask = nil
        audioMonitor.stop()
        positionTracker.stop()

        panelSize = Self.panelSize(for: label, selectorLabels: selectorLabels)
        let panel = makePanelIfNeeded()
        panel.setContentSize(panelSize)
        audioLevelSessionID = UUID()
        self.label = label
        self.phase = phase
        pendingDisplayUpdate = nil
        visibleFrames = []
        audioLevelSmoother.reset()
        audioLevel = 0
        renderView()
        loggedAnchorSource = nil
        lastAnchor = nil
        pendingInitialAnchor = nil
        unresolvedInitialSampleCount = 0
        isSelectorMenuTracking = false
        isPanelVisible = false
        panel.orderOut(nil)
        updatePosition()

        let sleep = positionPollingSleep
        positionTrackingTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await sleep(.milliseconds(150))
                } catch {
                    return
                }
                guard !Task.isCancelled,
                      let self,
                      self.positionTrackingSessionID == positionTrackingSessionID
                else { return }
                self.updatePosition()
            }
        }
    }

    func hide() {
        positionTrackingTask?.cancel()
        positionTrackingTask = nil
        positionTrackingSessionID = nil
        audioLevelTask?.cancel()
        audioLevelTask = nil
        audioLevelSessionID = nil
        audioLevelSmoother.reset()
        audioLevel = 0
        lastAnchor = nil
        pendingInitialAnchor = nil
        unresolvedInitialSampleCount = 0
        isSelectorMenuTracking = false
        isPanelVisible = false
        panel?.orderOut(nil)
    }

    func update(label: String, phase: ListeningIndicatorPhase) {
        guard isPanelVisible else {
            pendingDisplayUpdate = (label, phase)
            return
        }

        self.label = label
        self.phase = phase
        panelSize = Self.panelSize(for: label, selectorLabels: selectorLabels)
        panel?.setContentSize(panelSize)
        audioLevelTask?.cancel()
        audioLevelTask = nil
        audioLevelSessionID = nil
        audioLevelSmoother.reset()
        audioLevel = 0
        renderView()
        recordVisibleFrame()
        updatePosition()
    }

    func configureSelectors(
        promptLibrary: PromptLibraryStore,
        audioInput: AudioInputStore,
        interfaceLocale: @escaping () -> Locale
    ) {
        self.promptLibrary = promptLibrary
        self.audioInput = audioInput
        self.interfaceLocale = interfaceLocale
        observeSelectorStores()
        refreshSelectors()
    }

    private func makePanelIfNeeded() -> NSPanel {
        if let panel {
            return panel
        }

        let panel = ListeningIndicatorPanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        // Hosting view passes through every point except selector controls.
        panel.ignoresMouseEvents = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .transient,
            .ignoresCycle
        ]

        let hostingView = ListeningIndicatorHostingView(rootView: indicatorView())
        hostingView.frame = NSRect(origin: .zero, size: panelSize)
        hostingView.autoresizingMask = [.width, .height]
        panel.contentView = hostingView

        self.panel = panel
        self.hostingView = hostingView
        return panel
    }

    private func updatePosition() {
        guard let panel, !isSelectorMenuTracking else { return }
        var anchor = positionProvider.anchor()
        guard anchor.source.isFallback || (anchor.point != .zero && !panel.frame.contains(anchor.point)) else { return }
        if anchor.source.isFallback, isPanelVisible, let lastAnchor {
            anchor = lastAnchor
        } else if !anchor.source.isFallback {
            lastAnchor = anchor
        }
        if loggedAnchorSource != anchor.source {
            logger.log("Listening indicator anchor: \(anchor.source.logDescription)")
            if let diagnostic = anchor.diagnostic {
                logger.log("Listening indicator AX diagnostic: \(diagnostic)")
            }
            loggedAnchorSource = anchor.source
        }
        guard isPanelVisible || initialAnchorIsReady(anchor) else { return }
        let visibleFrame = screen(containing: anchor.point)?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? NSRect(origin: .zero, size: panelSize)

        let origin: NSPoint
        switch anchor.placement {
        case .aboveAnchor:
            let proposedX = anchor.point.x - (panelSize.width / 2)
            let aboveY = anchor.point.y + Self.anchorSpacing
            let belowY = anchor.point.y - Self.anchorSpacing - panelSize.height
            let proposedY = aboveY + panelSize.height <= visibleFrame.maxY ? aboveY : belowY
            let maximumX = max(visibleFrame.minX, visibleFrame.maxX - panelSize.width)
            let maximumY = max(visibleFrame.minY, visibleFrame.maxY - panelSize.height)
            origin = NSPoint(
                x: min(max(proposedX, visibleFrame.minX), maximumX),
                y: min(max(proposedY, visibleFrame.minY), maximumY)
            )
        case .centered:
            origin = NSPoint(
                x: visibleFrame.midX - (panelSize.width / 2),
                y: visibleFrame.midY - (panelSize.height / 2)
            )
        }

        panel.setFrameOrigin(origin)
        if !isPanelVisible {
            isPanelVisible = true
            panel.orderFrontRegardless()
            panel.displayIfNeeded()
            recordVisibleFrame()
            if let pendingDisplayUpdate {
                self.pendingDisplayUpdate = nil
                update(label: pendingDisplayUpdate.label, phase: pendingDisplayUpdate.phase)
            }
            if let audioLevelSessionID {
                startAudioLevelMonitoring(sessionID: audioLevelSessionID)
            }
        }
    }

    private func startAudioLevelMonitoring(sessionID: UUID) {
        guard audioLevelTask == nil else { return }

        audioLevelTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self,
                      self.isPanelVisible,
                      self.audioLevelSessionID == sessionID
                else { return }
                self.sampleAudioLevel()
                do {
                    try await Task.sleep(for: .milliseconds(50))
                } catch {
                    return
                }
            }
        }
    }

    private func sampleAudioLevel() {
        audioLevelProvider.updateMeters()
        audioLevel = audioLevelSmoother.update(decibels: audioLevelProvider.averagePower)
        renderView()
    }

    private var selectorLabels: [String]? {
        guard let promptLibrary, let audioInput else { return nil }
        let promptLabel = promptLibrary.activePrompt?.name
            ?? promptLibrary.activeWorkflow?.name
            ?? EntrevoixLocalization.text("menu.prompt", defaultValue: "Prompt", locale: interfaceLocale())
        let audioInputLabel: String
        switch audioInput.selection {
        case .systemDefault:
            audioInputLabel = EntrevoixLocalization.text(
                "audio_input.system_default",
                defaultValue: "System Default",
                locale: interfaceLocale()
            )
        case .device(let device): audioInputLabel = device.name
        }
        return [promptLabel, audioInputLabel]
    }

    private func observeSelectorStores() {
        withObservationTracking {
            _ = selectorLabels
            _ = promptLibrary?.prompts
            _ = promptLibrary?.workflows
            _ = audioInput?.devices
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.observeSelectorStores()
                self.refreshSelectors()
            }
        }
    }

    private func refreshSelectors() {
        panelSize = Self.panelSize(for: label, selectorLabels: selectorLabels)
        panel?.setContentSize(panelSize)
        renderView()
        if isPanelVisible { updatePosition() }
    }

    private static func panelSize(for label: String, selectorLabels: [String]?) -> NSSize {
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        let textWidth = ceil((label as NSString).size(withAttributes: [.font: font]).width)
        let intrinsicWidth = textWidth + iconWidth + iconSpacing + panelHorizontalPadding
        let statusWidth = min(max(minimumPanelSize.width, intrinsicWidth), maximumPanelWidth)
        let layout = ListeningIndicatorLayout(panelWidth: statusWidth, selectorLabels: selectorLabels ?? [])
        return NSSize(
            width: layout.selectorCapsuleFrame.width,
            height: selectorLabels == nil ? minimumPanelSize.height : 72
        )
    }

    private func indicatorView() -> ListeningIndicatorView {
        ListeningIndicatorView(
            label: label,
            audioLevel: audioLevel,
            panelWidth: panelSize.width,
            phase: phase,
            promptLibrary: promptLibrary,
            audioInput: audioInput,
            interfaceLocale: interfaceLocale(),
            selectorSurface: selectorSurface,
            accessibilityReduceMotion: accessibilityReduceMotion
        )
    }

    private func renderView() {
        selectorSurface.clearRenderedControls()
        hostingView?.rootView = indicatorView()
    }

    private func recordVisibleFrame() {
        visibleFrames.append(ListeningIndicatorRenderedFrame(
            label: label,
            phase: phase,
            color: phase.color,
            usesPhaseAnimation: false,
            usesAudioLevelAnimation: accessibilityReduceMotion != true
        ))
    }

    private func initialAnchorIsReady(_ anchor: ListeningIndicatorAnchor) -> Bool {
        switch anchor.source {
        case .directCaret, .textMarkerCaret, .adjacentCharacter, .accessibilityPermissionMissing:
            return true
        case .focusedTextElement:
            defer { pendingInitialAnchor = anchor }
            guard let pendingInitialAnchor,
                  pendingInitialAnchor.source == anchor.source
            else {
                return false
            }
            return hypot(
                pendingInitialAnchor.point.x - anchor.point.x,
                pendingInitialAnchor.point.y - anchor.point.y
            ) <= 4
        case .focusedInputUnavailable:
            // Give a lazily-built web accessibility tree a few polling cycles
            // before falling back to the pointer in an unsupported control.
            unresolvedInitialSampleCount += 1
            return unresolvedInitialSampleCount >= 3
        }
    }

    private func screen(containing point: NSPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(point) }
    }
}

@MainActor
struct ListeningIndicatorPositionProvider {
    private let resolver: FocusedTextElementResolver?
    private let anchorOverride: (@MainActor () -> ListeningIndicatorAnchor)?
    private let screenCenter: @MainActor () -> NSPoint

    init(
        resolver: FocusedTextElementResolver = .shared,
        screenCenter: @escaping @MainActor () -> NSPoint = {
            let frame = NSScreen.main?.visibleFrame
                ?? NSScreen.screens.first?.visibleFrame
                ?? .zero
            return NSPoint(x: frame.midX, y: frame.midY)
        }
    ) {
        self.resolver = resolver
        anchorOverride = nil
        self.screenCenter = screenCenter
    }

    init(anchor: @escaping @MainActor () -> ListeningIndicatorAnchor) {
        resolver = nil
        anchorOverride = anchor
        screenCenter = { .zero }
    }

    func anchor() -> ListeningIndicatorAnchor {
        if let anchorOverride { return anchorOverride() }
        guard let resolver else {
            preconditionFailure("ListeningIndicatorPositionProvider requires an anchor source.")
        }
        guard resolver.client.isTrusted() else {
            return ListeningIndicatorAnchor(
                point: screenCenter(),
                source: .accessibilityPermissionMissing,
                placement: .centered
            )
        }

        let elements = resolver.focusedElementCandidates()
        for element in elements {
            if let point = resolver.directCaretPoint(in: element) {
                return ListeningIndicatorAnchor(point: point, source: .directCaret)
            }
            if let point = resolver.textMarkerCaretPoint(in: element) {
                return ListeningIndicatorAnchor(point: point, source: .textMarkerCaret)
            }
            if let point = resolver.adjacentCharacterCaretPoint(in: element) {
                return ListeningIndicatorAnchor(point: point, source: .adjacentCharacter)
            }
        }

        for element in elements where resolver.isTextInput(element) {
            if let frame = resolver.elementFrame(in: element) {
                let leadingInset = min(16, frame.width / 2)
                return ListeningIndicatorAnchor(
                    point: NSPoint(x: frame.minX + leadingInset, y: frame.maxY),
                    source: .focusedTextElement
                )
            }
        }

        return ListeningIndicatorAnchor(
            point: NSEvent.mouseLocation,
            source: .focusedInputUnavailable,
            diagnostic: resolver.diagnosticSummary(for: elements)
        )
    }
}


struct ListeningIndicatorAnchor {
    enum Placement: Equatable {
        case aboveAnchor
        case centered
    }

    enum Source: Equatable {
        case directCaret
        case textMarkerCaret
        case adjacentCharacter
        case focusedTextElement
        case accessibilityPermissionMissing
        case focusedInputUnavailable

        var isFallback: Bool {
            switch self {
            case .accessibilityPermissionMissing, .focusedInputUnavailable: true
            default: false
            }
        }

        var logDescription: String {
            switch self {
            case .directCaret: "text caret"
            case .textMarkerCaret: "browser text caret"
            case .adjacentCharacter: "adjacent character"
            case .focusedTextElement: "focused text field"
            case .accessibilityPermissionMissing: "Accessibility permission missing"
            case .focusedInputUnavailable: "focused input unavailable"
            }
        }
    }

    let point: NSPoint
    let source: Source
    let diagnostic: String?
    let placement: Placement

    init(
        point: NSPoint,
        source: Source,
        diagnostic: String? = nil,
        placement: Placement = .aboveAnchor
    ) {
        self.point = point
        self.source = source
        self.diagnostic = diagnostic
        self.placement = placement
    }
}

final class ListeningIndicatorPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class ListeningIndicatorSelectorPanel: NSPanel {
    let popup = ListeningIndicatorPopupButton(frame: .zero, pullsDown: true)

    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = .floating
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        ignoresMouseEvents = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        popup.bezelStyle = .texturedRounded
        popup.imagePosition = .imageLeading
        popup.font = .systemFont(ofSize: NSFont.systemFontSize + 0.1)
        popup.autoresizingMask = [.width, .height]
        contentView = popup
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class ListeningIndicatorHostingView: NSHostingView<ListeningIndicatorView> {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let swiftUIPoint = NSPoint(x: point.x, y: bounds.height - point.y)
        guard rootView.selectorSurface.consumesClick(at: swiftUIPoint) else { return nil }
        return super.hitTest(point) ?? self
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let swiftUIPoint = NSPoint(x: point.x, y: bounds.height - point.y)
        guard rootView.selectorSurface.consumesClick(at: swiftUIPoint),
              let popup = popup(at: point, in: self)
        else {
            super.mouseDown(with: event)
            return
        }
        popup.performClick(self)
    }

    private func popup(at point: NSPoint, in view: NSView) -> ListeningIndicatorPopupButton? {
        for subview in view.subviews.reversed() {
            let subviewPoint = subview.convert(point, from: self)
            if let popup = subview as? ListeningIndicatorPopupButton, subview.bounds.contains(subviewPoint) {
                return popup
            }
            if let popup = popup(at: point, in: subview) { return popup }
        }
        return nil
    }

}

@MainActor
final class ListeningIndicatorSelectorSurface {
    private var promptFrame: NSRect?
    private var audioInputFrame: NSRect?
    private var activeRenderID: UUID?
    var onMenuTrackingChanged: ((Bool) -> Void)?
    private let promptAction: (CleanupTransformationSelection) -> Void
    private let audioInputAction: (AudioInputSelection) -> Void

    init(
        promptAction: @escaping (CleanupTransformationSelection) -> Void = { _ in },
        audioInputAction: @escaping (AudioInputSelection) -> Void = { _ in }
    ) {
        self.promptAction = promptAction
        self.audioInputAction = audioInputAction
    }

    func beginRenderingControls(id: UUID) {
        activeRenderID = id
        promptFrame = nil
        audioInputFrame = nil
    }

    func registerRenderedControls(
        promptFrame: NSRect,
        audioInputFrame: NSRect,
        renderID: UUID? = nil
    ) {
        guard renderID == nil || renderID == activeRenderID else { return }
        self.promptFrame = promptFrame
        self.audioInputFrame = audioInputFrame
    }

    func clearRenderedControls() {
        promptFrame = nil
        audioInputFrame = nil
        activeRenderID = nil
    }

    func clearRenderedControls(renderID: UUID) {
        guard renderID == activeRenderID else { return }
        promptFrame = nil
        audioInputFrame = nil
    }

    func consumesClick(at point: NSPoint) -> Bool {
        promptFrame?.contains(point) == true || audioInputFrame?.contains(point) == true
    }

    func click(
        at point: NSPoint,
        promptSelection: CleanupTransformationSelection? = nil,
        audioInputSelection: AudioInputSelection? = nil
    ) {
        if promptFrame?.contains(point) == true, let promptSelection {
            promptAction(promptSelection)
        } else if audioInputFrame?.contains(point) == true, let audioInputSelection {
            audioInputAction(audioInputSelection)
        }
    }

    func setMenuTracking(_ isTracking: Bool) {
        onMenuTrackingChanged?(isTracking)
    }
}

struct ListeningIndicatorSelectorLabel {
    let renderedWidth: CGFloat
    let availableWidth: CGFloat
    let isTruncated: Bool
}

struct ListeningIndicatorLayout {
    let selectorCapsuleFrame: NSRect
    let statusCapsuleFrame: NSRect
    let promptControlFrame: NSRect
    let audioInputControlFrame: NSRect
    let selectorLabels: [ListeningIndicatorSelectorLabel]

    init(panelWidth: CGFloat, selectorLabels: [String]) {
        let labelFont = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let controlWidths = selectorLabels.enumerated().map { _, label in
            let labelWidth = ceil((label as NSString).size(withAttributes: [.font: labelFont]).width)
            return labelWidth + 55
        }
        let requiredWidth = 64 + controlWidths.reduce(0, +)
        let resolvedWidth = min(max(panelWidth, requiredWidth), 320)
        let availableControlWidth = max(0, resolvedWidth - 64)
        let requiredControlWidth = controlWidths.reduce(0, +)
        let resolvedControlWidths: [CGFloat]
        if requiredControlWidth <= availableControlWidth {
            let extraWidth = (availableControlWidth - requiredControlWidth) / CGFloat(max(controlWidths.count, 1))
            resolvedControlWidths = controlWidths.map { $0 + extraWidth }
        } else {
            let minimumControlWidth = min(55, availableControlWidth / CGFloat(controlWidths.count))
            var widths = controlWidths.map { min($0, minimumControlWidth) }
            var remainingWidth = availableControlWidth - widths.reduce(0, +)

            while remainingWidth > 0 {
                let unmetIndices = widths.indices.filter { widths[$0] < controlWidths[$0] }
                guard !unmetIndices.isEmpty else { break }

                let share = remainingWidth / CGFloat(unmetIndices.count)
                for index in unmetIndices {
                    let addedWidth = min(share, controlWidths[index] - widths[index])
                    widths[index] += addedWidth
                    remainingWidth -= addedWidth
                }
            }
            resolvedControlWidths = widths
        }
        selectorCapsuleFrame = NSRect(x: 0, y: 0, width: resolvedWidth, height: 28)
        statusCapsuleFrame = NSRect(x: 0, y: 32, width: resolvedWidth, height: 40)
        let promptControlWidth = resolvedControlWidths[safe: 0] ?? 0
        let audioInputControlWidth = resolvedControlWidths[safe: 1] ?? 0
        promptControlFrame = NSRect(x: 12, y: 4, width: promptControlWidth, height: 20)
        audioInputControlFrame = NSRect(
            x: resolvedWidth - 12 - audioInputControlWidth,
            y: 4,
            width: audioInputControlWidth,
            height: 20
        )
        self.selectorLabels = selectorLabels.enumerated().map { index, label in
            let measuredWidth = ceil((label as NSString).size(withAttributes: [.font: labelFont]).width)
            let chromeWidth = index == 0 && measuredWidth < 320 ? 44.5 : (index == 0 ? 41 : 36.5)
            let availableWidth = max(0, (resolvedControlWidths[safe: index] ?? 0) - chromeWidth)
            return ListeningIndicatorSelectorLabel(
                renderedWidth: min(measuredWidth, availableWidth),
                availableWidth: availableWidth,
                isTruncated: measuredWidth > availableWidth
            )
        }
    }
}

struct ListeningIndicatorView: View {
    let label: String
    let audioLevel: CGFloat
    let panelWidth: CGFloat
    let phase: ListeningIndicatorPhase
    let promptLibrary: PromptLibraryStore?
    let audioInput: AudioInputStore?
    let interfaceLocale: Locale
    let selectorSurface: ListeningIndicatorSelectorSurface
    let selectorRenderID: UUID?
    let accessibilityReduceMotion: Bool?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        label: String,
        audioLevel: CGFloat,
        panelWidth: CGFloat,
        phase: ListeningIndicatorPhase,
        promptLibrary: PromptLibraryStore? = nil,
        audioInput: AudioInputStore? = nil,
        interfaceLocale: Locale = .current,
        selectorSurface: ListeningIndicatorSelectorSurface = ListeningIndicatorSelectorSurface(),
        accessibilityReduceMotion: Bool? = nil
    ) {
        self.label = label
        self.audioLevel = audioLevel
        self.panelWidth = panelWidth
        self.phase = phase
        self.promptLibrary = promptLibrary
        self.audioInput = audioInput
        self.interfaceLocale = interfaceLocale
        self.selectorSurface = selectorSurface
        self.accessibilityReduceMotion = accessibilityReduceMotion
        if promptLibrary == nil || audioInput == nil {
            selectorRenderID = nil
            selectorSurface.clearRenderedControls()
        } else {
            let selectorRenderID = UUID()
            self.selectorRenderID = selectorRenderID
            selectorSurface.beginRenderingControls(id: selectorRenderID)
        }
    }

    var body: some View {
        let selectorLabels = selectorLabels
        let layout = ListeningIndicatorLayout(panelWidth: panelWidth, selectorLabels: selectorLabels)

        VStack(spacing: layout.statusCapsuleFrame.minY - layout.selectorCapsuleFrame.maxY) {
            if let promptLibrary, let audioInput, let selectorRenderID {
                ListeningIndicatorSelectorRow(
                    promptLibrary: promptLibrary,
                    audioInput: audioInput,
                    interfaceLocale: interfaceLocale,
                    panelWidth: layout.selectorCapsuleFrame.width,
                    selectorLabels: selectorLabels,
                    selectorSurface: selectorSurface,
                    selectorRenderID: selectorRenderID
                )
                .id(selectorRenderID)
            }

            HStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(Color(nsColor: phase.color).opacity(circleOpacity))
                        .frame(width: 24, height: 24)
                        .scaleEffect(circleScale)

                    Image(systemName: "mic.fill")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(Color(nsColor: phase.color))
                        .animation(nil, value: audioLevel)
                }

                Text(label)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity)
            .frame(height: layout.statusCapsuleFrame.height)
            .background(.regularMaterial, in: Capsule())
        }
        .frame(
            width: layout.selectorCapsuleFrame.width,
            height: promptLibrary != nil && audioInput != nil
                ? layout.statusCapsuleFrame.maxY
                : layout.statusCapsuleFrame.height
        )
        .coordinateSpace(name: "ListeningIndicator")
        .animation(
            shouldReduceMotion ? nil : .easeOut(duration: 0.08),
            value: audioLevel
        )
    }

    private var circleScale: CGFloat {
        shouldReduceMotion ? 0.82 : 0.82 + (audioLevel * 0.40)
    }

    private var circleOpacity: Double {
        0.18 + (Double(audioLevel) * 0.36)
    }

    private var shouldReduceMotion: Bool {
        accessibilityReduceMotion ?? reduceMotion
    }

    private var selectorLabels: [String] {
        guard let promptLibrary, let audioInput else { return [] }
        let promptLabel = promptLibrary.activePrompt?.name
            ?? promptLibrary.activeWorkflow?.name
            ?? EntrevoixLocalization.text("menu.prompt", defaultValue: "Prompt", locale: interfaceLocale)
        let audioInputLabel: String
        switch audioInput.selection {
        case .systemDefault:
            audioInputLabel = EntrevoixLocalization.text(
                "audio_input.system_default",
                defaultValue: "System Default",
                locale: interfaceLocale
            )
        case .device(let device): audioInputLabel = device.name
        }
        return [promptLabel, audioInputLabel]
    }

}

private struct ListeningIndicatorSelectorRow: View {
    @Bindable var promptLibrary: PromptLibraryStore
    @Bindable var audioInput: AudioInputStore
    let interfaceLocale: Locale
    let panelWidth: CGFloat
    let selectorLabels: [String]
    let selectorSurface: ListeningIndicatorSelectorSurface
    let selectorRenderID: UUID

    var body: some View {
        let layout = ListeningIndicatorLayout(
            panelWidth: panelWidth,
            selectorLabels: selectorLabels
        )

        HStack(spacing: layout.audioInputControlFrame.minX - layout.promptControlFrame.maxX) {
            ListeningIndicatorSelectorPopup(
                title: promptLabel,
                symbolName: "wand.and.stars",
                items: promptItems,
                kind: .prompt,
                menuTrackingChanged: selectorSurface.setMenuTracking
            )
            .frame(
                width: layout.promptControlFrame.width,
                height: layout.promptControlFrame.height,
                alignment: .leading
            )
            .background(SelectorControlGeometry(kind: .prompt))

            ListeningIndicatorSelectorPopup(
                title: audioInputLabel,
                symbolName: "mic",
                items: audioInputItems,
                kind: .audioInput,
                menuTrackingChanged: selectorSurface.setMenuTracking
            )
            .frame(
                width: layout.audioInputControlFrame.width,
                height: layout.audioInputControlFrame.height,
                alignment: .trailing
            )
            .background(SelectorControlGeometry(kind: .audioInput))
        }
        .padding(.horizontal, layout.promptControlFrame.minX)
        .frame(width: layout.selectorCapsuleFrame.width, height: layout.selectorCapsuleFrame.height)
        .background(.regularMaterial, in: Capsule())
        .onPreferenceChange(SelectorControlFramesKey.self) { frames in
            if let promptFrame = frames[.prompt], let audioInputFrame = frames[.audioInput] {
                selectorSurface.registerRenderedControls(
                    promptFrame: promptFrame,
                    audioInputFrame: audioInputFrame,
                    renderID: selectorRenderID
                )
            } else {
                selectorSurface.clearRenderedControls(renderID: selectorRenderID)
            }
        }
    }

    private var promptLabel: String {
        promptLibrary.activePrompt?.name ?? promptLibrary.activeWorkflow?.name
            ?? EntrevoixLocalization.text("menu.prompt", defaultValue: "Prompt", locale: interfaceLocale)
    }

    private var audioInputLabel: String {
        switch audioInput.selection {
        case .systemDefault:
            EntrevoixLocalization.text("audio_input.system_default", defaultValue: "System Default", locale: interfaceLocale)
        case .device(let device): device.name
        }
    }

    private var promptItems: [ListeningIndicatorPopupItem] {
        promptLibrary.prompts.map { prompt in
            ListeningIndicatorPopupItem(title: prompt.name) {
                promptLibrary.setActiveSelection(.prompt(prompt.id))
            }
        } + promptLibrary.workflows.compactMap { workflow in
            guard workflow.isValid else { return nil }
            return ListeningIndicatorPopupItem(title: workflow.name) {
                promptLibrary.setActiveSelection(.workflow(workflow.id))
            }
        }
    }

    private var audioInputItems: [ListeningIndicatorPopupItem] {
        [ListeningIndicatorPopupItem(
            title: EntrevoixLocalization.text("audio_input.system_default", defaultValue: "System Default", locale: interfaceLocale)
        ) {
            audioInput.setSelection(.systemDefault)
        }] + audioInput.devices.map { device in
            ListeningIndicatorPopupItem(title: device.name) {
                audioInput.setSelection(.device(device))
            }
        }
    }
}

struct ListeningIndicatorPopupItem {
    let title: String
    let action: () -> Void
}

struct ListeningIndicatorSelectorPopup: NSViewRepresentable {
    let title: String
    let symbolName: String
    let items: [ListeningIndicatorPopupItem]
    let kind: SelectorControlKind
    let menuTrackingChanged: (Bool) -> Void

    init(
        title: String,
        symbolName: String,
        items: [ListeningIndicatorPopupItem],
        kind: SelectorControlKind,
        menuTrackingChanged: @escaping (Bool) -> Void = { _ in }
    ) {
        self.title = title
        self.symbolName = symbolName
        self.items = items
        self.kind = kind
        self.menuTrackingChanged = menuTrackingChanged
    }

    func makeNSView(context: Context) -> ListeningIndicatorPopupButton {
        let button = ListeningIndicatorPopupButton(frame: .zero, pullsDown: true)
        button.bezelStyle = .texturedRounded
        button.imagePosition = .imageLeading
        button.font = .systemFont(ofSize: NSFont.systemFontSize + 0.1)
        button.kind = kind
        button.onMenuTrackingChanged = menuTrackingChanged
        button.autoresizingMask = []
        return button
    }

    func updateNSView(_ button: ListeningIndicatorPopupButton, context _: Context) {
        button.kind = kind
        button.onMenuTrackingChanged = menuTrackingChanged
        button.configure(title: title, symbolName: symbolName, items: items)
    }
}

final class ListeningIndicatorPopupButton: NSPopUpButton {
    private var actions: [() -> Void] = []
    var kind: SelectorControlKind = .prompt
    var onMenuTrackingChanged: (Bool) -> Void = { _ in }

    override init(frame buttonFrame: NSRect, pullsDown flag: Bool) {
        super.init(frame: buttonFrame, pullsDown: flag)
        isBordered = false
        wantsLayer = true
        layer?.masksToBounds = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(menuDidBeginTracking(_:)),
            name: NSMenu.didBeginTrackingNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(menuDidEndTracking(_:)),
            name: NSMenu.didEndTrackingNotification,
            object: nil
        )
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    @objc private func menuDidBeginTracking(_ notification: Notification) {
        guard isOwnMenu(notification) else { return }
        onMenuTrackingChanged(true)
    }

    @objc private func menuDidEndTracking(_ notification: Notification) {
        onMenuTrackingChanged(false)
    }

    private func isOwnMenu(_ notification: Notification) -> Bool {
        (notification.object as? NSMenu)?.items.contains { $0.target === self } == true
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func configure(title: String, symbolName: String, items: [ListeningIndicatorPopupItem]) {
        removeAllItems()
        addItem(withTitle: title)
        itemArray[0].image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        actions = items.map(\.action)
        for (index, item) in items.enumerated() {
            let menuItem = NSMenuItem(title: item.title, action: #selector(didSelectPopupItem(_:)), keyEquivalent: "")
            menuItem.target = self
            menuItem.tag = index
            menu?.addItem(menuItem)
        }
    }

    @objc private func didSelectPopupItem(_ sender: NSMenuItem) {
        actions[safe: sender.tag]?()
    }

    func activateItem(at index: Int) {
        actions[safe: index]?()
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

enum SelectorControlKind: Hashable { case prompt, audioInput }

private struct SelectorControlFramesKey: PreferenceKey {
    static let defaultValue: [SelectorControlKind: NSRect] = [:]
    static func reduce(value: inout [SelectorControlKind: NSRect], nextValue: () -> [SelectorControlKind: NSRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct SelectorControlGeometry: View {
    let kind: SelectorControlKind

    var body: some View {
        GeometryReader { proxy in
            Color.clear.preference(
                key: SelectorControlFramesKey.self,
                value: [kind: proxy.frame(in: .named("ListeningIndicator"))]
            )
        }
    }
}

struct ListeningIndicatorAudioLevelSmoother {
    static let minimumDecibels: Float = -64
    static let maximumDecibels: Float = -6
    static let attackCoefficient: CGFloat = 0.65
    static let releaseCoefficient: CGFloat = 0.25

    private(set) var level: CGFloat = 0

    mutating func update(decibels: Float) -> CGFloat {
        let target = Self.normalizedLevel(from: decibels)
        let coefficient = target > level
            ? Self.attackCoefficient
            : Self.releaseCoefficient
        level += (target - level) * coefficient
        return level
    }

    mutating func reset() {
        level = 0
    }

    static func normalizedLevel(from decibels: Float) -> CGFloat {
        guard decibels.isFinite else { return 0 }
        let clamped = min(max(decibels, minimumDecibels), maximumDecibels)
        return CGFloat((clamped - minimumDecibels) / (maximumDecibels - minimumDecibels))
    }
}
