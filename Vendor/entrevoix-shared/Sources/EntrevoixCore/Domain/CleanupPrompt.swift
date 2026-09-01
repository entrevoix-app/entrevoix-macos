import Foundation

public struct CleanupPrompt: Codable, Equatable, Identifiable, Sendable {
    public static let allowedSystemImageNames = [
        "wand.and.stars", "sparkles", "text.badge.checkmark", "doc.text", "envelope",
        "message", "briefcase", "graduationcap", "terminal", "quote.bubble"
    ]
    public let id: UUID
    public var name: String
    public var systemImageName: String
    public var instructions: String

    public init(
        id: UUID = UUID(),
        name: String,
        systemImageName: String,
        instructions: String
    ) {
        self.id = id
        self.name = name
        self.systemImageName = systemImageName
        self.instructions = instructions
    }
}
