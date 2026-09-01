import Foundation

public protocol SecretStoring: AnyObject {
    func read(profileIDs: [UUID]) throws -> [UUID: String]
    func save(_ secrets: [UUID: String]) throws
}
