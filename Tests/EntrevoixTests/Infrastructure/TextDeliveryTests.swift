import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import Entrevoix

@Suite("Text delivery Accessibility")
@MainActor
struct TextDeliveryTests {
    @Test("inserts directly into a native AX text field")
    func insertsNativeTextField() {
        let client = FakeAccessibilityClient()
        let field = client.addNode(role: "AXTextField")
        client.focused = field
        client.settable = true
        client.replacementSucceeds = true
        let poster = RecordingPasteEventPoster()
        let pasteboard = FakePasteboard(text: "previous clipboard contents")
        let delivery = TextDelivery(
            resolver: FocusedTextElementResolver(client: client),
            pasteEventPoster: poster,
            pasteboard: pasteboard
        )

        let result = delivery.deliver(" \n native   transcript \t ", mode: .paste)

        #expect(result == .inserted)
        #expect(client.replacedTexts == ["native   transcript "])
        #expect(poster.postCount == 0)
        #expect(pasteboard.copiedTexts.isEmpty)
        #expect(pasteboard.text == "previous clipboard contents")
    }

    @Test("falls back to paste for a Chromium contenteditable AX group")
    func pastesChromiumContentEditable() {
        let client = FakeAccessibilityClient()
        let group = client.addNode(role: "AXGroup")
        client.markAttribute("AXIsEditable", on: group)
        client.focused = group
        client.settable = true
        client.replacementSucceeds = true
        let poster = RecordingPasteEventPoster()
        let delivery = TextDelivery(
            resolver: FocusedTextElementResolver(client: client),
            pasteEventPoster: poster
        )

        let result = delivery.deliver("browser transcript", mode: .paste)

        #expect(result == .inserted)
        #expect(poster.postCount == 1)
        #expect(client.replacedTexts.isEmpty)
        #expect(client.enabledElements.contains(client.application))
        #expect(client.enabledElements.contains(client.window))
    }

    @Test("restores the clipboard after automatic paste into a web editor")
    func restoresClipboardAfterWebPaste() async {
        let client = FakeAccessibilityClient()
        let group = client.addNode(role: "AXGroup")
        client.markAttribute("AXIsEditable", on: group)
        client.focused = group
        let pasteboard = FakePasteboard(text: "previous clipboard contents")
        let poster = RecordingPasteEventPoster()
        let delivery = TextDelivery(
            resolver: FocusedTextElementResolver(client: client),
            pasteEventPoster: poster,
            pasteboard: pasteboard,
            sleep: { _ in }
        )

        let result = delivery.deliver("browser transcript", mode: .paste)
        await Task.yield()

        #expect(result == .inserted)
        #expect(poster.postCount == 1)
        #expect(pasteboard.copiedTexts == ["browser transcript "])
        #expect(pasteboard.text == "previous clipboard contents")
    }

    @Test("does not overwrite clipboard changes made after automatic insertion")
    func doesNotRestoreOverNewClipboardContents() async {
        let client = FakeAccessibilityClient()
        let group = client.addNode(role: "AXGroup")
        client.markAttribute("AXIsEditable", on: group)
        client.focused = group
        let pasteboard = FakePasteboard(text: "previous clipboard contents")
        let sleep = ControlledSleep()
        let delivery = TextDelivery(
            resolver: FocusedTextElementResolver(client: client),
            pasteEventPoster: RecordingPasteEventPoster(),
            pasteboard: pasteboard,
            sleep: sleep.sleep
        )

        _ = delivery.deliver("browser transcript", mode: .paste)
        await sleep.waitUntilSleeping()
        pasteboard.copy("new clipboard contents")
        sleep.resume()
        await Task.yield()

        #expect(pasteboard.text == "new clipboard contents")
    }

    @Test("recognizes an Electron generic editable element")
    func pastesElectronGenericElement() {
        let client = FakeAccessibilityClient()
        let genericElement = client.addNode(role: "AXGenericElement")
        client.markAttribute("AXEditable", on: genericElement)
        client.focused = genericElement
        let poster = RecordingPasteEventPoster()
        let delivery = TextDelivery(
            resolver: FocusedTextElementResolver(client: client),
            pasteEventPoster: poster
        )

        let result = delivery.deliver("electron transcript", mode: .paste)

        #expect(result == .inserted)
        #expect(poster.postCount == 1)
    }

    @Test("resolves an editable web ancestor of the focused element")
    func resolvesEditableAncestor() {
        let client = FakeAccessibilityClient()
        let focusedChild = client.addNode(role: "AXStaticText")
        let editableAncestor = client.addNode(role: "AXGroup")
        client.markAttribute("AXEditable", on: editableAncestor)
        client.setEditableAncestor(editableAncestor, for: focusedChild)
        client.focused = focusedChild

        let resolved = FocusedTextElementResolver(client: client).resolve()

        #expect(resolved?.element == editableAncestor)
        #expect(resolved?.isEditable == true)
    }

    @Test("prefers application focus over a stale system-wide focus")
    func prefersApplicationFocus() {
        let client = FakeAccessibilityClient()
        let staleAddressBar = client.addNode(role: "AXTextField")
        let pageEditor = client.addNode(role: "AXGroup")
        client.markAttribute("AXIsEditable", on: pageEditor)
        client.focused = staleAddressBar
        client.applicationFocused = pageEditor
        client.windowFocused = pageEditor

        let resolved = FocusedTextElementResolver(client: client).resolve()

        #expect(resolved?.element == pageEditor)
    }

    @Test("uses paste for a text field nested in a web area")
    func pastesWebAreaTextField() {
        let client = FakeAccessibilityClient()
        let webArea = client.addNode(role: "AXWebArea")
        let pageField = client.addNode(role: "AXTextField", editable: true)
        client.nodes[webArea]?.children = [pageField]
        client.nodes[pageField]?.parent = webArea
        client.focused = webArea
        client.applicationFocused = webArea
        client.windowFocused = webArea
        client.settable = true
        client.replacementSucceeds = true
        let poster = RecordingPasteEventPoster()
        let delivery = TextDelivery(
            resolver: FocusedTextElementResolver(client: client),
            pasteEventPoster: poster
        )

        let result = delivery.deliver("web transcript", mode: .paste)

        #expect(result == .inserted)
        #expect(client.replacedTexts.isEmpty)
        #expect(poster.postCount == 1)
    }

    @Test("recognizes classic and text-marker selection attributes")
    func recognizesSelectionAttributes() {
        let client = FakeAccessibilityClient()
        let markerElement = client.addNode(role: "AXGenericElement")
        client.markAttribute("AXSelectedTextMarkerRange", on: markerElement)
        client.focused = markerElement

        let resolved = FocusedTextElementResolver(client: client).resolve()

        #expect(resolved?.element == markerElement)
    }

    @Test("uses one paste after Accessibility replacement is rejected")
    func pastesOnceAfterAccessibilityFailure() {
        let client = FakeAccessibilityClient()
        let field = client.addNode(role: "AXTextArea", editable: true)
        client.focused = field
        client.settable = true
        client.replacementSucceeds = false
        let poster = RecordingPasteEventPoster()
        let delivery = TextDelivery(
            resolver: FocusedTextElementResolver(client: client),
            pasteEventPoster: poster
        )

        let result = delivery.deliver("fallback transcript", mode: .paste)

        #expect(result == .inserted)
        #expect(client.replacedTexts == ["fallback transcript "])
        #expect(poster.postCount == 1)
    }

    @Test("does not paste into a secure field")
    func copiesSecureField() {
        let client = FakeAccessibilityClient()
        let field = client.addNode(
            role: "AXTextField",
            subrole: "AXSecureTextField",
            editable: true
        )
        client.focused = field
        let poster = RecordingPasteEventPoster()
        let delivery = TextDelivery(
            resolver: FocusedTextElementResolver(client: client),
            pasteEventPoster: poster
        )

        let result = delivery.deliver("secret transcript", mode: .paste)

        #expect(result == .secureFieldCopied)
        #expect(poster.postCount == 0)
        #expect(client.replacedTexts.isEmpty)
    }

    @Test("copies only when Accessibility is unavailable")
    func copiesWithoutAccessibilityPermission() {
        let client = FakeAccessibilityClient()
        client.trusted = false
        let poster = RecordingPasteEventPoster()
        let delivery = TextDelivery(
            resolver: FocusedTextElementResolver(client: client),
            pasteEventPoster: poster
        )

        let result = delivery.deliver("permission transcript", mode: .paste)

        #expect(result == .fallbackCopied(reason: "Accessibility permission missing"))
        #expect(poster.postCount == 0)
    }

    @Test("clipboard mode never posts a paste event")
    func clipboardModeDoesNotPaste() {
        let client = FakeAccessibilityClient()
        let poster = RecordingPasteEventPoster()
        let delivery = TextDelivery(
            resolver: FocusedTextElementResolver(client: client),
            pasteEventPoster: poster
        )

        let result = delivery.deliver(" \n clipboard transcript \t ", mode: .clipboard)

        #expect(result == .copied)
        #expect(poster.postCount == 0)
        #expect(NSPasteboard.general.string(forType: .string) == "clipboard transcript ")
    }

    @Test("reports a fallback when paste events cannot be created")
    func reportsPasteFailure() {
        let client = FakeAccessibilityClient()
        let group = client.addNode(role: "AXGroup")
        client.markAttribute("AXIsEditable", on: group)
        client.focused = group
        let poster = RecordingPasteEventPoster(result: false)
        let delivery = TextDelivery(
            resolver: FocusedTextElementResolver(client: client),
            pasteEventPoster: poster
        )

        let result = delivery.deliver("failed paste transcript", mode: .paste)

        #expect(result == .fallbackCopied(reason: "paste event could not be posted"))
        #expect(poster.postCount == 1)
    }

    @Test("deduplicates candidates and bounds Accessibility traversal")
    func resolverDeduplicatesAndBoundsTraversal() {
        let client = FakeAccessibilityClient()
        let duplicate = client.addNode(role: "AXGroup")
        client.focused = duplicate
        client.focusedApplicationElement = client.application
        client.focusedWindowElement = client.window
        client.childrenOfApplication = [duplicate]
        client.childrenOfWindow = [duplicate]
        let applicationOnly = client.addNode(role: "AXStaticText")
        client.childrenOfApplication.append(applicationOnly)

        let resolver = FocusedTextElementResolver(client: client)
        let candidates = resolver.focusedElementCandidates()

        #expect(candidates.first == duplicate)
        #expect(Set(candidates).count == candidates.count)
        #expect(candidates.firstIndex(of: applicationOnly)! > candidates.firstIndex(of: duplicate)!)

        let largeClient = FakeAccessibilityClient()
        largeClient.childrenOfApplication = (0..<500).map { _ in
            largeClient.addNode(role: "AXGroup")
        }
        let boundedCandidates = FocusedTextElementResolver(client: largeClient)
            .focusedElementCandidates()
        #expect(boundedCandidates.count <= 384)
    }
}

@MainActor
private final class RecordingPasteEventPoster: PasteEventPosting {
    let result: Bool
    private(set) var postCount = 0

    init(result: Bool = true) {
        self.result = result
    }

    func postPaste() -> Bool {
        postCount += 1
        return result
    }
}

@MainActor
private final class FakePasteboard: PasteboardManaging {
    private(set) var changeCount = 0
    private(set) var text: String?
    private(set) var copiedTexts: [String] = []

    init(text: String? = nil) {
        self.text = text
    }

    func copy(_ text: String) {
        self.text = text
        copiedTexts.append(text)
        changeCount += 1
    }

    func snapshot() -> PasteboardSnapshot {
        let items: [[NSPasteboard.PasteboardType: Data]]
        if let text {
            items = [[.string: Data(text.utf8)]]
        } else {
            items = []
        }
        return PasteboardSnapshot(items: items)
    }

    func restore(_ snapshot: PasteboardSnapshot) {
        text = snapshot.items.first?[.string].flatMap { String(data: $0, encoding: .utf8) }
        changeCount += 1
    }
}

@MainActor
private final class ControlledSleep {
    private var continuation: CheckedContinuation<Void, Never>?

    func sleep(_: Duration) async throws {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilSleeping() async {
        while continuation == nil {
            await Task.yield()
        }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private final class FakeAccessibilityClient: AccessibilityClient {
    struct Node {
        var role: String?
        var subrole: String?
        var editable = false
        var attributes = Set<String>()
        var selectedRange: CFRange?
        var markerBounds: CGRect?
        var frame: CGRect?
        var parent: AccessibilityElement?
        var editableAncestor: AccessibilityElement?
        var highestEditableAncestor: AccessibilityElement?
        var children: [AccessibilityElement] = []
        var visibleChildren: [AccessibilityElement] = []
        var contents: [AccessibilityElement] = []
    }

    let system = AccessibilityElement(syntheticID: "system")
    let application = AccessibilityElement(syntheticID: "application")
    let window = AccessibilityElement(syntheticID: "window")
    var nodes: [AccessibilityElement: Node] = [:]
    var trusted = true
    var focused: AccessibilityElement?
    var applicationFocused: AccessibilityElement?
    var windowFocused: AccessibilityElement?
    var focusedApplicationElement: AccessibilityElement?
    var focusedWindowElement: AccessibilityElement?
    var childrenOfApplication: [AccessibilityElement] = []
    var childrenOfWindow: [AccessibilityElement] = []
    var enabledElements: [AccessibilityElement] = []
    var settable = false
    var replacementSucceeds = false
    private(set) var replacedTexts: [String] = []

    init() {
        nodes[system] = Node()
        nodes[application] = Node()
        nodes[window] = Node()
    }

    func addNode(
        role: String? = nil,
        subrole: String? = nil,
        editable: Bool = false
    ) -> AccessibilityElement {
        let element = AccessibilityElement(syntheticID: "node-\(nodes.count)-\(UUID().uuidString)")
        nodes[element] = Node(role: role, subrole: subrole, editable: editable)
        return element
    }

    func isTrusted() -> Bool { trusted }
    func systemWideElement() -> AccessibilityElement { system }
    func frontmostApplication() -> AccessibilityElement? { application }
    func applicationElement(processIdentifier: pid_t) -> AccessibilityElement { application }

    func focusedElement(in element: AccessibilityElement) -> AccessibilityElement? {
        if element == system { return focused }
        if element == application { return applicationFocused ?? focused }
        if element == window { return windowFocused ?? focused }
        return nil
    }

    func focusedApplication(in element: AccessibilityElement) -> AccessibilityElement? {
        element == system ? (focusedApplicationElement ?? application) : nil
    }

    func focusedWindow(in element: AccessibilityElement) -> AccessibilityElement? {
        if element == application || element == window { return focusedWindowElement ?? window }
        return nil
    }

    func parent(of element: AccessibilityElement) -> AccessibilityElement? { nodes[element]?.parent }
    func editableAncestor(of element: AccessibilityElement) -> AccessibilityElement? { nodes[element]?.editableAncestor }
    func highestEditableAncestor(of element: AccessibilityElement) -> AccessibilityElement? {
        nodes[element]?.highestEditableAncestor
    }

    func children(of element: AccessibilityElement) -> [AccessibilityElement] {
        if element == application { return childrenOfApplication }
        if element == window { return childrenOfWindow }
        return nodes[element]?.children ?? []
    }

    func visibleChildren(of element: AccessibilityElement) -> [AccessibilityElement] {
        nodes[element]?.visibleChildren ?? []
    }

    func contents(of element: AccessibilityElement) -> [AccessibilityElement] {
        nodes[element]?.contents ?? []
    }

    func setMessagingTimeout(_ timeout: Float, for element: AccessibilityElement) {}

    func enableWebAccessibility(in element: AccessibilityElement) {
        enabledElements.append(element)
    }

    func role(of element: AccessibilityElement) -> String? { nodes[element]?.role }
    func subrole(of element: AccessibilityElement) -> String? { nodes[element]?.subrole }
    func isEditable(of element: AccessibilityElement) -> Bool {
        guard let node = nodes[element] else { return false }
        return node.editable
            || node.attributes.contains("AXEditable")
            || node.attributes.contains("AXIsEditable")
    }

    func markAttribute(_ attribute: String, on element: AccessibilityElement) {
        nodes[element]?.attributes.insert(attribute)
    }

    func setEditableAncestor(_ ancestor: AccessibilityElement, for element: AccessibilityElement) {
        nodes[element]?.editableAncestor = ancestor
    }

    func hasAttribute(_ attribute: String, in element: AccessibilityElement) -> Bool {
        if attribute == "AXSelectedTextRange" {
            return nodes[element]?.selectedRange != nil
                || nodes[element]?.attributes.contains(attribute) == true
        }
        if attribute == "AXSelectedTextMarkerRange" {
            return nodes[element]?.markerBounds != nil
                || nodes[element]?.attributes.contains(attribute) == true
        }
        return nodes[element]?.attributes.contains(attribute) ?? false
    }

    func selectedTextRange(of element: AccessibilityElement) -> CFRange? { nodes[element]?.selectedRange }
    func textMarkerCaretBounds(of element: AccessibilityElement) -> CGRect? { nodes[element]?.markerBounds }
    func bounds(for range: CFRange, in element: AccessibilityElement) -> CGRect? { nil }
    func frame(of element: AccessibilityElement) -> CGRect? { nodes[element]?.frame }

    func isAttributeSettable(_ attribute: String, in element: AccessibilityElement) -> Bool { settable }

    func replaceSelectedText(_ text: String, in element: AccessibilityElement) -> Bool {
        replacedTexts.append(text)
        return settable && replacementSucceeds
    }
}
