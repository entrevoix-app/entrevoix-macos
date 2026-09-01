@MainActor
public protocol TextDelivering: AnyObject {
    func copy(_ text: String)
    func copyAndPaste(_ text: String)
    func deliver(_ text: String, mode: OutputMode) -> TextDeliveryResult
}
