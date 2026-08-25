import AppKit
import EntrevoixCore
import SwiftUI

@MainActor
protocol ListeningIndicatorPresenting: AnyObject {
    func show(label: String)
    func update(label: String)
    func hide()
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
    private var hostingView: NSHostingView<ListeningIndicatorView>?
    private var positionTrackingTask: Task<Void, Never>?
    private var positionTrackingSessionID: UUID?
    private var audioLevelTask: Task<Void, Never>?
    private var audioLevelSessionID: UUID?
    private var audioLevelSmoother = ListeningIndicatorAudioLevelSmoother()
    private var audioLevel: CGFloat = 0
    private var label = ""
    private var panelSize = NSSize(width: 128, height: 40)
    private var loggedAnchorSource: ListeningIndicatorAnchor.Source?
    private var lastAnchor: ListeningIndicatorAnchor?
    private var pendingInitialAnchor: ListeningIndicatorAnchor?
    private var unresolvedInitialSampleCount = 0
    private(set) var isPanelVisible = false

    init(
        positionProvider: ListeningIndicatorPositionProvider = ListeningIndicatorPositionProvider(),
        audioLevelProvider: any AudioLevelProviding,
        logger: any LogWriting,
        positionPollingSleep: @escaping Sleep = { try await Task.sleep(for: $0) }
    ) {
        self.positionProvider = positionProvider
        self.audioLevelProvider = audioLevelProvider
        self.logger = logger
        self.positionPollingSleep = positionPollingSleep
        self.positionTracker = ListeningIndicatorPositionTracker(provider: positionProvider, logger: logger)
        self.audioMonitor = ListeningIndicatorAudioMonitor(provider: audioLevelProvider)
    }

    func show(label: String) {
        positionTrackingTask?.cancel()
        let positionTrackingSessionID = UUID()
        self.positionTrackingSessionID = positionTrackingSessionID
        audioLevelTask?.cancel()
        audioLevelTask = nil
        audioMonitor.stop()
        positionTracker.stop()

        panelSize = Self.panelSize(for: label)
        let panel = makePanelIfNeeded()
        panel.setContentSize(panelSize)
        audioLevelSessionID = UUID()
        self.label = label
        audioLevelSmoother.reset()
        audioLevel = 0
        hostingView?.rootView = ListeningIndicatorView(
            label: label,
            audioLevel: audioLevel,
            panelWidth: panelSize.width
        )
        loggedAnchorSource = nil
        lastAnchor = nil
        pendingInitialAnchor = nil
        unresolvedInitialSampleCount = 0
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
        isPanelVisible = false
        panel?.orderOut(nil)
    }

    func update(label: String) {
        self.label = label
        panelSize = Self.panelSize(for: label)
        panel?.setContentSize(panelSize)
        audioLevelTask?.cancel()
        audioLevelTask = nil
        audioLevelSessionID = nil
        audioLevelSmoother.reset()
        audioLevel = 0
        hostingView?.rootView = ListeningIndicatorView(
            label: label,
            audioLevel: 0,
            panelWidth: panelSize.width
        )
        if isPanelVisible {
            updatePosition()
        }
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
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .transient,
            .ignoresCycle
        ]

        let hostingView = NSHostingView(rootView: ListeningIndicatorView(
            label: label,
            audioLevel: 0,
            panelWidth: panelSize.width
        ))
        hostingView.frame = NSRect(origin: .zero, size: panelSize)
        hostingView.autoresizingMask = [.width, .height]
        panel.contentView = hostingView

        self.panel = panel
        self.hostingView = hostingView
        return panel
    }

    private func updatePosition() {
        guard let panel else { return }
        var anchor = positionProvider.anchor()
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
        hostingView?.rootView = ListeningIndicatorView(
            label: label,
            audioLevel: audioLevel,
            panelWidth: panelSize.width
        )
    }

    private static func panelSize(for label: String) -> NSSize {
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        let textWidth = ceil((label as NSString).size(withAttributes: [.font: font]).width)
        let intrinsicWidth = textWidth + iconWidth + iconSpacing + panelHorizontalPadding
        return NSSize(
            width: min(max(minimumPanelSize.width, intrinsicWidth), maximumPanelWidth),
            height: minimumPanelSize.height
        )
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

struct ListeningIndicatorView: View {
    let label: String
    let audioLevel: CGFloat
    let panelWidth: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(Color(nsColor: .systemRed).opacity(circleOpacity))
                    .frame(width: 24, height: 24)
                    .scaleEffect(circleScale)

                Image(systemName: "mic.fill")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Color(nsColor: .systemRed))
            }

            Text(label)
                .font(.callout.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .frame(width: panelWidth, height: 40)
        .background(.regularMaterial, in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .animation(
            reduceMotion ? nil : .easeOut(duration: 0.08),
            value: audioLevel
        )
    }

    private var circleScale: CGFloat {
        reduceMotion ? 0.82 : 0.82 + (audioLevel * 0.40)
    }

    private var circleOpacity: Double {
        0.18 + (Double(audioLevel) * 0.36)
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
