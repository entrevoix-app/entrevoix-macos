import KeyboardShortcuts

@preconcurrency import EntrevoixCore

@MainActor
extension KeyboardShortcuts.Name {
    static let dictation = Self("dictation")
    static let dictationSecondary = Self("dictationSecondary")
    static let cancel = Self("cancel", default: .init(.escape))
}

enum DictationShortcutSource: Hashable {
    case primary
    case secondary
}

struct DictationShortcutPressState {
    private var pressedSources = Set<DictationShortcutSource>()

    mutating func handleKeyDown(for source: DictationShortcutSource) -> Bool {
        guard pressedSources.insert(source).inserted else { return false }
        return pressedSources.count == 1
    }

    mutating func handleKeyUp(for source: DictationShortcutSource) -> Bool {
        guard pressedSources.remove(source) != nil else { return false }
        return pressedSources.isEmpty
    }
}

struct EscapeHotkeyRegistrationState {
    private(set) var callbackIsAvailable = false
    private(set) var isInstalled = false
    private(set) var isEnabled = false

    mutating func setCallbackAvailable(_ isAvailable: Bool) -> Bool? {
        guard callbackIsAvailable != isAvailable else { return nil }
        callbackIsAvailable = isAvailable
        guard isInstalled else { return nil }
        isEnabled = isAvailable
        return isAvailable
    }

    mutating func install() -> Bool? {
        guard !isInstalled else { return nil }
        isInstalled = true
        isEnabled = callbackIsAvailable
        return isEnabled
    }
}

@MainActor
final class HotkeyService: HotkeyHandling {
    var onKeyDown: (() -> Void)?
    var onKeyUp: (() -> Void)?
    var onEscape: (() -> Void)? {
        didSet {
            updateEscapeRegistration(
                escapeRegistration.setCallbackAvailable(onEscape != nil)
            )
        }
    }
    private var escapeRegistration = EscapeHotkeyRegistrationState()
    private var dictationShortcutPressState = DictationShortcutPressState()

    init() {
        // RegisterEventHotKey can fail silently when called while SwiftUI is still
        // constructing the application, before the Carbon event dispatcher exists.
        // Defer installation until the main run loop has started.
        Task { @MainActor [weak self] in
            await Task.yield()
            self?.install()
        }
    }

    private func install() {
        guard !escapeRegistration.isInstalled else { return }

        // KeyboardShortcuts invokes these handlers synchronously from Carbon's
        // main event dispatcher. Keep them synchronous: scheduling a main-actor
        // Task here can crash while Swift checks the current executor.
        KeyboardShortcuts.onKeyDown(for: .dictation) { [weak self] in
            self?.handleDictationKeyDown(.primary)
        }

        KeyboardShortcuts.onKeyUp(for: .dictation) { [weak self] in
            self?.handleDictationKeyUp(.primary)
        }

        KeyboardShortcuts.onKeyDown(for: .dictationSecondary) { [weak self] in
            self?.handleDictationKeyDown(.secondary)
        }

        KeyboardShortcuts.onKeyUp(for: .dictationSecondary) { [weak self] in
            self?.handleDictationKeyUp(.secondary)
        }
        KeyboardShortcuts.onKeyDown(for: .cancel) { [weak self] in
            self?.onEscape?()
        }
        updateEscapeRegistration(escapeRegistration.install())
    }

    private func updateEscapeRegistration(_ isEnabled: Bool?) {
        guard let isEnabled else { return }
        if isEnabled {
            KeyboardShortcuts.enable(.cancel)
        } else {
            KeyboardShortcuts.disable(.cancel)
        }
    }

    private func handleDictationKeyDown(_ source: DictationShortcutSource) {
        guard dictationShortcutPressState.handleKeyDown(for: source) else { return }
        onKeyDown?()
    }

    private func handleDictationKeyUp(_ source: DictationShortcutSource) {
        guard dictationShortcutPressState.handleKeyUp(for: source) else { return }
        onKeyUp?()
    }
}
