import Foundation

public enum SessionKind: Sendable, Equatable { case dictation, connectionTest }

public struct SessionLease: Sendable, Equatable {
    public let id: UUID
    public let kind: SessionKind
    public init(id: UUID = UUID(), kind: SessionKind) { self.id = id; self.kind = kind }
}

@MainActor
public protocol SessionArbitrating: AnyObject {
    func acquire(_ kind: SessionKind) -> SessionLease?
    func release(_ lease: SessionLease)
}
