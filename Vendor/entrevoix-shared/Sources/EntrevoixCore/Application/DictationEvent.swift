public enum DictationEvent: Equatable, Sendable {
    case recordingStarted
    case recordingStopped
    case cleanupStarted
    case cleanupStepStarted(current: Int, total: Int)
    case recordingTimedOut
    case providerUnavailable(capability: ProviderCapability, reason: ProviderUnavailabilityReason)
    case sessionEnded
}
