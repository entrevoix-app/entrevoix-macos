import AppKit
import EntrevoixCore

@MainActor
final class TextDelivery: TextDelivering {
    typealias Sleep = (Duration) async throws -> Void

    private struct PendingPasteboardRestore {
        let id: UUID
        let snapshot: PasteboardSnapshot
        let temporaryChangeCount: Int
        let task: Task<Void, Never>
    }

    /// Gives the receiving app time to read the temporary pasteboard value.
    private static let pasteboardRestoreDelay: Duration = .milliseconds(150)

    private let resolver: FocusedTextElementResolver
    private let pasteEventPoster: any PasteEventPosting
    private let pasteboard: any PasteboardManaging
    private let sleep: Sleep
    private var pendingPasteboardRestore: PendingPasteboardRestore?

    init(
        resolver: FocusedTextElementResolver = .shared,
        pasteEventPoster: any PasteEventPosting = SystemPasteEventPoster(),
        pasteboard: any PasteboardManaging = SystemPasteboard(),
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) }
    ) {
        self.resolver = resolver
        self.pasteEventPoster = pasteEventPoster
        self.pasteboard = pasteboard
        self.sleep = sleep
    }

    func copy(_ text: String) {
        pasteboard.copy(prepareForDelivery(text))
    }

    func copyAndPaste(_ text: String) {
        copy(text)
        _ = pasteEventPoster.postPaste()
    }

    func deliver(_ text: String, mode: OutputMode) -> TextDeliveryResult {
        guard mode == .paste else {
            copy(text)
            return .copied
        }

        guard resolver.client.isTrusted() else {
            copy(text)
            return .fallbackCopied(reason: "Accessibility permission missing")
        }

        let focusedTextElement = resolver.resolve()
        if let focusedTextElement, focusedTextElement.isSecure {
            copy(text)
            return .secureFieldCopied
        }

        if let focusedTextElement,
           focusedTextElement.isEditable,
           !focusedTextElement.isWebEditor,
           resolver.client.replaceSelectedText(prepareForDelivery(text), in: focusedTextElement.element) {
            return .inserted
        }

        restorePendingPasteboardIfNeeded()
        let previousPasteboardContents = pasteboard.snapshot()
        pasteboard.copy(prepareForDelivery(text))
        let temporaryChangeCount = pasteboard.changeCount
        guard pasteEventPoster.postPaste() else {
            return .fallbackCopied(reason: "paste event could not be posted")
        }
        schedulePasteboardRestore(
            previousPasteboardContents,
            temporaryChangeCount: temporaryChangeCount
        )
        return .inserted
    }

    private func schedulePasteboardRestore(
        _ snapshot: PasteboardSnapshot,
        temporaryChangeCount: Int
    ) {
        let id = UUID()
        let task = Task { @MainActor [weak self] in
            do {
                try await self?.sleep(Self.pasteboardRestoreDelay)
            } catch {
                return
            }
            self?.restorePasteboardIfUnchanged(id: id)
        }
        pendingPasteboardRestore = PendingPasteboardRestore(
            id: id,
            snapshot: snapshot,
            temporaryChangeCount: temporaryChangeCount,
            task: task
        )
    }

    private func restorePendingPasteboardIfNeeded() {
        guard let pendingPasteboardRestore else { return }
        pendingPasteboardRestore.task.cancel()
        self.pendingPasteboardRestore = nil
        guard pasteboard.changeCount == pendingPasteboardRestore.temporaryChangeCount else { return }
        pasteboard.restore(pendingPasteboardRestore.snapshot)
    }

    private func restorePasteboardIfUnchanged(id: UUID) {
        guard let pendingPasteboardRestore, pendingPasteboardRestore.id == id else { return }
        self.pendingPasteboardRestore = nil
        guard pasteboard.changeCount == pendingPasteboardRestore.temporaryChangeCount else { return }
        pasteboard.restore(pendingPasteboardRestore.snapshot)
    }

    private func prepareForDelivery(_ text: String) -> String {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return "" }
        return "\(trimmedText) "
    }
}
