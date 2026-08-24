import Foundation

enum AppVersion {
    static let fallbackMarketingVersion = "0.0.0"
    static let marketingVersion = marketingVersion(in: Bundle.main.infoDictionary)

    static func marketingVersion(in infoDictionary: [String: Any]?) -> String {
        guard let version = infoDictionary?["CFBundleShortVersionString"] as? String,
              !version.isEmpty else {
            return fallbackMarketingVersion
        }
        return version
    }
}
