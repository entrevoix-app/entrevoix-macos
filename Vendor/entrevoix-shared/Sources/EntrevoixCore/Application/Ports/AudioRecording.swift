import Foundation

@MainActor
public protocol AudioRecording: AnyObject {
    @discardableResult
    func start(input: AudioInputSelection) throws -> AudioInputStartResult
    func stop() -> URL?
    func cancel()
    func deleteLastCapture()
    func captureSize(at url: URL) -> Int
    func deleteCapture(at url: URL)
}
