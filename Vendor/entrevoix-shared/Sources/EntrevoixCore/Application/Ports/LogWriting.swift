@MainActor
public protocol LogWriting: AnyObject {
    func log(_ message: String)
}
