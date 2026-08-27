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

@MainActor
final class HotkeyService: HotkeyHandling {
    var onKeyDown: (() -> Void)?
    var onKeyUp: (() -> Void)?
    var onEscape: (() -> Void)?
    private var isInstalled = false
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
        guard !isInstalled else { return }
        isInstalled = true

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
