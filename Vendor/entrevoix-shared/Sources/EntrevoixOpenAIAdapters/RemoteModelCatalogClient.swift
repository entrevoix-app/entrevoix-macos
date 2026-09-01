import Foundation
import EntrevoixCore

public struct RemoteModelCatalogClient: RemoteModelDiscovering {
    private let transport: any HTTPTransporting

    public init(transport: any HTTPTransporting = SafeNetworkSession()) {
        self.transport = transport
    }

    public func discoverModels(configuration: ProviderConfiguration, apiKey: String) async throws -> [String] {
        var discoveryConfiguration = configuration
        discoveryConfiguration.path = configuration.pathForModelDiscovery
        guard let url = discoveryConfiguration.endpointURL else { throw ModelCatalogError.invalidEndpoint }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = configuration.timeout
        switch configuration.authentication {
        case .bearer:
            guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ModelCatalogError.missingAPIKey }
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        case .apiKey:
            guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !configuration.customHeaderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ModelCatalogError.missingAPIKey }
            request.setValue(apiKey, forHTTPHeaderField: configuration.customHeaderName)
        case .none: break
        }
        let (data, response) = try await transport.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ModelCatalogError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw ModelCatalogError.http(http.statusCode) }
        let values = try JSONDecoder().decode(Response.self, from: data).data.map(\.id)
        return Array(Set(values.filter { !$0.isEmpty })).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private struct Response: Decodable { let data: [Model]; struct Model: Decodable { let id: String } }
}

enum ModelCatalogError: LocalizedError, LogSafeError, UserFacingErrorProviding {
    case invalidEndpoint, missingAPIKey, invalidResponse, http(Int)
    var errorDescription: String? { "Could not load the provider model catalogue." }
    var logMessage: String { "Model catalogue request failed." }
    var userFacingMessage: UserFacingErrorMessage { .verbatim("Could not load the provider model catalogue.") }
}

private extension ProviderConfiguration {
    var pathForModelDiscovery: String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "models" : trimmed
    }
}
