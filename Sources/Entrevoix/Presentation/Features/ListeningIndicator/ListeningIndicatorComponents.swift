import AppKit
import EntrevoixCore
import SwiftUI

/// Owns only the AppKit panel and its hosted SwiftUI content.
@MainActor
final class ListeningIndicatorPanelPresenter {
    private(set) var panel: NSPanel?
    private var hostingView: NSHostingView<ListeningIndicatorView>?
    private let panelFactory: (NSRect) -> NSPanel

    init(panelFactory: @escaping (NSRect) -> NSPanel = { rect in
        ListeningIndicatorPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    }) {
        self.panelFactory = panelFactory
    }

    func makeIfNeeded(size: NSSize, label: String, phase: ListeningIndicatorPhase) -> NSPanel {
        if let panel { return panel }
        let panel = panelFactory(NSRect(origin: .zero, size: size))
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        let hostingView = NSHostingView(rootView: ListeningIndicatorView(label: label, audioLevel: 0, panelWidth: size.width, phase: phase))
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.autoresizingMask = [.width, .height]
        panel.contentView = hostingView
        self.panel = panel
        self.hostingView = hostingView
        return panel
    }

    func render(label: String, level: CGFloat, width: CGFloat, phase: ListeningIndicatorPhase) {
        hostingView?.rootView = ListeningIndicatorView(label: label, audioLevel: level, panelWidth: width, phase: phase)
    }

    func hide() { panel?.orderOut(nil) }
}

/// Polls caret anchors and exposes stabilized, screen-clamped origins.
@MainActor
final class ListeningIndicatorPositionTracker {
    typealias Sleep = (Duration) async throws -> Void

    private let provider: ListeningIndicatorPositionProvider
    private let screens: () -> [NSScreen]
    private let sleep: Sleep
    private let logger: any LogWriting
    private var task: Task<Void, Never>?
    private(set) var lastGoodAnchor: ListeningIndicatorAnchor?

    init(
        provider: ListeningIndicatorPositionProvider,
        screens: @escaping () -> [NSScreen] = { NSScreen.screens },
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) },
        logger: any LogWriting
    ) {
        self.provider = provider
        self.screens = screens
        self.sleep = sleep
        self.logger = logger
    }

    func stop() { task?.cancel(); task = nil }

    func start(interval: Duration = .milliseconds(150), update: @escaping (NSPoint) -> Void) {
        stop()
        task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.sample(update: update)
                do { try await self?.sleep(interval) } catch { return }
            }
        }
    }

    func sample(update: (NSPoint) -> Void) {
        var anchor = provider.anchor()
        if anchor.source.isFallback, let lastGoodAnchor { anchor = lastGoodAnchor }
        else if !anchor.source.isFallback { lastGoodAnchor = anchor }
        logger.log("Listening indicator anchor: \(anchor.source.logDescription)")
        update(anchor.point)
    }

    func clampedOrigin(for point: NSPoint, panelSize: NSSize) -> NSPoint {
        let frame = screens().first { $0.frame.contains(point) }?.visibleFrame
            ?? screens().first?.visibleFrame
            ?? NSRect(origin: .zero, size: panelSize)
        return NSPoint(
            x: min(max(point.x - panelSize.width / 2, frame.minX), max(frame.minX, frame.maxX - panelSize.width)),
            y: min(max(point.y + 8, frame.minY), max(frame.minY, frame.maxY - panelSize.height))
        )
    }
}

/// Samples microphone meters independently from panel positioning.
@MainActor
final class ListeningIndicatorAudioMonitor {
    typealias Sleep = (Duration) async throws -> Void
    private let provider: any AudioLevelProviding
    private let sleep: Sleep
    private var task: Task<Void, Never>?
    private var smoother = ListeningIndicatorAudioLevelSmoother()

    init(provider: any AudioLevelProviding, sleep: @escaping Sleep = { try await Task.sleep(for: $0) }) {
        self.provider = provider
        self.sleep = sleep
    }

    func start(sample: @escaping (CGFloat) -> Void) {
        stop(); smoother.reset()
        task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                provider.updateMeters()
                sample(self.smoother.update(decibels: provider.averagePower))
                do { try await self.sleep(.milliseconds(50)) } catch { return }
            }
        }
    }

    func stop() { task?.cancel(); task = nil; smoother.reset() }
}
