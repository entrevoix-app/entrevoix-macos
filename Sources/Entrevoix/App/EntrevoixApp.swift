import AppKit
import Combine
import SwiftUI
import EntrevoixCore

@main
struct EntrevoixApp: App {
    @NSApplicationDelegateAdaptor(EntrevoixAppDelegate.self) private var appDelegate
    @State private var launchState: CompositionRoot.LaunchState
    @State private var dockPresenceController: DockPresenceController
    @State private var didOpenOnboarding = false
    @State private var didOpenRecoveryNotice = false
    @State private var didShowIncompatibleAlert = false
    @Environment(\.openWindow) private var openWindow

    init() {
        if LocalizationDiagnostic.runIfRequested() {
            exit(0)
        }
        if KeyboardShortcutsDiagnostic.runIfRequested() {
            exit(0)
        }
        let initialLaunchState = CompositionRoot.makeLaunchState()
        _launchState = State(initialValue: initialLaunchState)
        _dockPresenceController = State(initialValue: DockPresenceController())
        if case .ready(let environment, _) = initialLaunchState {
            Task { @MainActor in
                environment.appStore.requestUnresolvedPermissionsAtLaunch()
            }
        }
    }

    var body: some Scene {
        MenuBarExtra {
            if case .ready(let environment, let recoveredPreferences) = launchState {
                let model = environment.appStore
                MenuContent(
                    model: model,
                    openUserFacingWindow: openUserFacingWindow
                )
                    .environment(\.locale, model.interfaceLocale)
                    .environment(model)
                    .environment(model.preferencesModel)
                    .environment(model.providerStore)
                    .environment(model.dictationSession)
                    .environment(model.permissionsModel)
                    .environment(model.promptLibrary)
                    .task {
                        guard model.requiresOnboarding, !recoveredPreferences, !didOpenOnboarding else { return }
                        didOpenOnboarding = true
                        openUserFacingWindow(id: "onboarding")
                    }
                    .task {
                        guard recoveredPreferences, !didOpenRecoveryNotice else { return }
                        didOpenRecoveryNotice = true
                        openUserFacingWindow(id: "startup-recovery")
                    }
                    .onReceive(NotificationCenter.default.publisher(for: .cleanupLibraryCloudChange)) { _ in
                        model.refreshCleanupLibrary()
                    }
                    .onReceive(NotificationCenter.default.publisher(for: .dictationDictionaryCloudChange)) { _ in
                        model.refreshDictationDictionary()
                    }
            } else {
                Text(EntrevoixLocalization.text("startup.incompatible.title", defaultValue: "Entrevoix Update Required", locale: Locale(identifier: "en")))
                .task {
                    guard case .incompatible(let schemaVersion, let updater) = launchState, !didShowIncompatibleAlert else { return }
                    didShowIncompatibleAlert = true
                    presentIncompatibleAlert(schemaVersion: schemaVersion, updater: updater)
                }
                Button(EntrevoixLocalization.text("action.quit", defaultValue: "Quit", locale: Locale(identifier: "en"))) {
                    NSApplication.shared.terminate(nil)
                }
            }
        } label: {
            Image(nsImage: menuBarImage(for: readyModel?.state))
                .accessibilityLabel("Entrevoix")
        }
        .menuBarExtraStyle(.menu)

        Window(
            EntrevoixLocalization.text("window.settings", defaultValue: "Entrevoix Settings", locale: interfaceLocale),
            id: "settings"
        ) {
            if let model = readyModel {
                SettingsView(model: model)
                    .environment(\.locale, model.interfaceLocale)
                    .environment(model)
                    .environment(model.preferencesModel)
                    .environment(model.providerStore)
                    .environment(model.dictationSession)
                    .environment(model.permissionsModel)
                    .environment(model.promptLibrary)
                    .background(DockPresenceWindowFocus(sceneID: "settings", controller: dockPresenceController))
            }
        }
        .defaultLaunchBehavior(.suppressed)
        .windowToolbarStyle(.unified)

        Window(
            EntrevoixLocalization.text("window.logs", defaultValue: "Entrevoix Logs", locale: interfaceLocale),
            id: "logs"
        ) {
            if let model = readyModel {
                LogsView(logStore: model.logStore)
                    .environment(\.locale, model.interfaceLocale)
                    .background(DockPresenceWindowFocus(sceneID: "logs", controller: dockPresenceController))
            }
        }
        .defaultLaunchBehavior(.suppressed)

        Window(
            EntrevoixLocalization.text("window.onboarding", defaultValue: "Welcome to Entrevoix", locale: interfaceLocale),
            id: "onboarding"
        ) {
            if let model = readyModel {
                OnboardingView(model: model)
                    .environment(\.locale, model.interfaceLocale)
                    .environment(model)
                    .environment(model.preferencesModel)
                    .environment(model.providerStore)
                    .environment(model.dictationSession)
                    .environment(model.permissionsModel)
                    .environment(model.promptLibrary)
                    .background(DockPresenceWindowFocus(sceneID: "onboarding", controller: dockPresenceController))
            }
        }
        .defaultLaunchBehavior(.suppressed)

        Window(
            EntrevoixLocalization.text("startup.recovered.title", defaultValue: "Settings Recovered", locale: interfaceLocale),
            id: "startup-recovery"
        ) {
            StartupNoticeView(kind: .recovered, locale: interfaceLocale)
                .background(DockPresenceWindowFocus(sceneID: "startup-recovery", controller: dockPresenceController))
        }
        .defaultLaunchBehavior(.suppressed)
    }

    private var readyModel: AppStore? {
        guard case .ready(let environment, _) = launchState else { return nil }
        return environment.appStore
    }

    private var interfaceLocale: Locale {
        readyModel?.interfaceLocale ?? Locale(identifier: "en")
    }

    private func openUserFacingWindow(id: String) {
        dockPresenceController.prepareForUserFacingWindow()
        openWindow(id: id)
        Task { @MainActor in
            await Task.yield()
            dockPresenceController.focusUserFacingWindow(id: id)
        }
    }

    private func statusIconName(for state: DictationState?) -> String? {
        guard let state else { return "exclamationmark.triangle.fill" }
        switch state {
        case .recording:
            return "record.circle.fill"
        case .transcribing:
            return "arrow.triangle.2.circlepath"
        case .error:
            return "exclamationmark.triangle.fill"
        default:
            return nil
        }
    }

    private func menuBarImage(for state: DictationState?) -> NSImage {
        let size: CGFloat = 18
        guard let statusIconName = statusIconName(for: state) else {
            return EntrevoixMenuBarMark.image(size: size)
        }
        let configuration = NSImage.SymbolConfiguration(pointSize: size, weight: .semibold)
        guard let image = NSImage(
            systemSymbolName: statusIconName,
            accessibilityDescription: "Entrevoix"
        )?.withSymbolConfiguration(configuration) else {
            return NSImage(size: .init(width: size, height: size))
        }

        image.size = .init(width: size, height: size)
        image.isTemplate = true
        return image
    }

    private func presentIncompatibleAlert(schemaVersion: Int, updater: any ApplicationUpdating) {
        let locale = Locale(identifier: "en")
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = EntrevoixLocalization.text(
            "startup.incompatible.title",
            defaultValue: "Entrevoix Update Required",
            locale: locale
        )
        let format = EntrevoixLocalization.text(
            "startup.incompatible.message",
            defaultValue: "These settings were written by a newer version of Entrevoix (schema %lld). Update Entrevoix before using this installation so the newer settings are not overwritten.",
            locale: locale
        )
        alert.informativeText = String(format: format, locale: locale, arguments: [schemaVersion])
        alert.addButton(withTitle: EntrevoixLocalization.text(
            "menu.check_for_updates",
            defaultValue: "Check for Updates…",
            locale: locale
        ))
        alert.addButton(withTitle: EntrevoixLocalization.text("action.quit", defaultValue: "Quit", locale: locale))
        NSApp.activate()
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            updater.checkForUpdates()
        } else {
            NSApplication.shared.terminate(nil)
        }
    }
}

private enum EntrevoixMenuBarMark {
    private static let waveformBounds = CGRect(x: 196, y: 184, width: 632, height: 656)
    private static let waveformBars: [CGRect] = [
        .init(x: 196, y: 397, width: 88, height: 230),
        .init(x: 332, y: 292, width: 88, height: 440),
        .init(x: 468, y: 184, width: 88, height: 656),
        .init(x: 604, y: 292, width: 88, height: 440),
        .init(x: 740, y: 397, width: 88, height: 230)
    ]

    static func image(size: CGFloat) -> NSImage {
        let image = NSImage(size: .init(width: size, height: size))
        image.lockFocus()
        NSColor.black.setFill()

        let renderedHeight = min(size * 0.9, 16)
        let scale = renderedHeight / waveformBounds.height
        let horizontalInset = (size - waveformBounds.width * scale) / 2
        let verticalInset = (size - renderedHeight) / 2
        let offset = CGSize(
            width: horizontalInset - waveformBounds.minX * scale,
            height: verticalInset - waveformBounds.minY * scale
        )
        for bar in waveformBars {
            NSBezierPath(
                roundedRect: bar.applying(.init(scaleX: scale, y: scale)).offsetBy(dx: offset.width, dy: offset.height),
                xRadius: 44 * scale,
                yRadius: 44 * scale
            ).fill()
        }

        image.unlockFocus()
        image.isTemplate = true
        return image
    }
}

private enum StartupNoticeKind {
    case recovered
}

private struct StartupNoticeView: View {
    let kind: StartupNoticeKind
    let locale: Locale

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(title, systemImage: iconName)
                .font(.title2.bold())
            Text(message)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(EntrevoixLocalization.text("action.quit", defaultValue: "Quit", locale: locale)) {
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 520, height: 220)
    }

    private var iconName: String {
        switch kind {
        case .recovered: "exclamationmark.triangle"
        }
    }

    private var title: String {
        switch kind {
        case .recovered:
            EntrevoixLocalization.text("startup.recovered.title", defaultValue: "Settings Recovered", locale: locale)
        }
    }

    private var message: String {
        switch kind {
        case .recovered:
            return EntrevoixLocalization.text(
                "startup.recovered.message",
                defaultValue: "Entrevoix could not read its settings. It created fresh settings and kept a private recovery copy. Please review your providers and API keys.",
                locale: locale
            )
        }
    }
}
