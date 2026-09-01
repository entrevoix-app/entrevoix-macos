@MainActor
public final class SessionArbiter: SessionArbitrating {
    private var activeLease: SessionLease?
    public init() {}
    public func acquire(_ kind: SessionKind) -> SessionLease? {
        guard activeLease == nil else { return nil }
        let lease = SessionLease(kind: kind)
        activeLease = lease
        return lease
    }
    public func release(_ lease: SessionLease) {
        guard activeLease == lease else { return }
        activeLease = nil
    }
}
