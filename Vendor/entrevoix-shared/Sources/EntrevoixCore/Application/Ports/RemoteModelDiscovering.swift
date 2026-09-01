import Foundation

public protocol RemoteModelDiscovering: Sendable {
    func discoverModels(configuration: ProviderConfiguration, apiKey: String) async throws -> [String]
}
