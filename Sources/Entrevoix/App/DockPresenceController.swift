import AppKit
import SwiftUI

/// Keeps the menu-bar app visible in the Dock while one of the user-facing
/// windows that needs normal app activation is open.
@MainActor
final class DockPresenceController {
    typealias ActivationPolicySetter = @MainActor (NSApplication.ActivationPolicy) -> Bool
    typealias ActivationRequester = @MainActor () -> Void
    typealias WindowFocusRequester = @MainActor (ObjectIdentifier) -> Void

    private let setActivationPolicy: ActivationPolicySetter
    private let requestActivation: ActivationRequester
    private let requestWindowFocus: WindowFocusRequester
    private var registeredWindows: Set<ObjectIdentifier> = []
    private var sceneWindowIDs: [String: ObjectIdentifier] = [:]
    private var usesRegularActivationPolicy = false

    private(set) var isDockVisible = false

    init(
        setActivationPolicy: @escaping ActivationPolicySetter = { policy in
            NSApp.setActivationPolicy(policy)
        },
        requestActivation: @escaping ActivationRequester = {
            NSApp.activate()
        },
        requestWindowFocus: @escaping WindowFocusRequester = { identifier in
            guard let window = NSApp.windows.first(where: { ObjectIdentifier($0) == identifier }) else {
                return
            }
            NSApp.unhide(nil)
            window.orderFrontRegardless()
            window.makeMain()
            window.makeKey()
        }
    ) {
        self.setActivationPolicy = setActivationPolicy
        self.requestActivation = requestActivation
        self.requestWindowFocus = requestWindowFocus
    }

    /// Makes the app switchable before the caller opens a user-facing window.
    ///
    /// An agent app is otherwise added to the Dock and application switcher only
    /// after its window has been created, which does not update its MRU position.
    func prepareForUserFacingWindow() {
        setUsesRegularActivationPolicy(true)
        requestActivation()
    }

    func register(window: NSWindow, sceneID: String) {
        register(windowID: ObjectIdentifier(window), sceneID: sceneID)
    }

    func register(windowID: ObjectIdentifier, sceneID: String? = nil) {
        if let sceneID {
            sceneWindowIDs[sceneID] = windowID
        }
        guard registeredWindows.insert(windowID).inserted else { return }
        updateDockVisibility()
    }

    func unregister(window: NSWindow) {
        unregister(windowID: ObjectIdentifier(window))
    }

    func unregister(windowID: ObjectIdentifier) {
        guard registeredWindows.remove(windowID) != nil else { return }
        sceneWindowIDs = sceneWindowIDs.filter { $0.value != windowID }
        updateDockVisibility()
    }

    /// Brings an already-created SwiftUI scene window back to the key position.
    func focusUserFacingWindow(id: String) {
        guard let windowID = sceneWindowIDs[id] else { return }
        requestActivation()
        requestWindowFocus(windowID)
    }

    private func updateDockVisibility() {
        let shouldShowDockIcon = !registeredWindows.isEmpty
        guard shouldShowDockIcon != isDockVisible else { return }

        isDockVisible = shouldShowDockIcon
        setUsesRegularActivationPolicy(shouldShowDockIcon)
    }

    private func setUsesRegularActivationPolicy(_ shouldUseRegularPolicy: Bool) {
        guard shouldUseRegularPolicy != usesRegularActivationPolicy else { return }

        usesRegularActivationPolicy = shouldUseRegularPolicy
        _ = setActivationPolicy(shouldUseRegularPolicy ? .regular : .accessory)
    }
}

/// Activates and tracks a SwiftUI scene window without taking ownership of
/// the window's lifecycle. The coordinator releases its registration when the
/// window closes or when SwiftUI tears down the represented view.
struct DockPresenceWindowFocus: NSViewRepresentable {
    let sceneID: String
    let controller: DockPresenceController

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ view: NSView, context: Context) {
        let coordinator = context.coordinator
        Task { @MainActor in
            coordinator.attach(to: view, sceneID: sceneID, controller: controller)
        }
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    final class Coordinator {
        private weak var window: NSWindow?
        private var closeObserver: NSObjectProtocol?
        private weak var controller: DockPresenceController?

        func attach(to view: NSView, sceneID: String, controller: DockPresenceController) {
            guard let window = view.window else { return }
            if self.window === window, self.controller === controller { return }

            detach()
            self.window = window
            self.controller = controller
            controller.register(window: window, sceneID: sceneID)

            closeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: window,
                queue: .main
            ) { [weak self, weak controller] _ in
                Task { @MainActor in
                    self?.handleClose(controller: controller)
                }
            }

            controller.focusUserFacingWindow(id: sceneID)
        }

        func detach() {
            if let window, let controller {
                controller.unregister(window: window)
            }
            if let closeObserver {
                NotificationCenter.default.removeObserver(closeObserver)
            }
            closeObserver = nil
            window = nil
            controller = nil
        }

        private func handleClose(controller: DockPresenceController?) {
            if let window, let controller {
                controller.unregister(window: window)
            }
            if let closeObserver {
                NotificationCenter.default.removeObserver(closeObserver)
            }
            closeObserver = nil
            window = nil
            self.controller = nil
        }
    }
}
