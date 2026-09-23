import Foundation

enum TradeReadyEnvironment: String {
    case development, staging, production
}

enum BuildEnvironmentError: LocalizedError {
    case missingBackendURL
    case productionWriteBlocked

    var errorDescription: String? {
        switch self {
        case .missingBackendURL: "This build does not have a valid backend URL configured."
        case .productionWriteBlocked: "This non-production build is blocked from sending data to the production backend."
        }
    }
}

enum BuildEnvironment {
    static let environment = TradeReadyEnvironment(
        rawValue: Bundle.main.object(forInfoDictionaryKey: "TradeReadyEnvironment") as? String ?? "development"
    ) ?? .development

    static var backendBaseURL: URL? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "TradeReadyBackendURL") as? String,
              !value.isEmpty else { return nil }
        return URL(string: value)
    }

    static var supabaseURL: URL? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "TradeReadySupabaseURL") as? String,
              !value.isEmpty else { return nil }
        return URL(string: value)
    }

    /// Public project origin used only to keep non-production builds from
    /// writing to the production Supabase Data API. This is not a credential.
    static var productionSupabaseURL: URL? {
        configuredURL(for: "TradeReadyProductionSupabaseURL")
    }

    /// Public client key for the production project. It is compared locally so
    /// a staging URL cannot accidentally ship with the production app key.
    static var productionSupabasePublishableKey: String? {
        configuredString(for: "TradeReadyProductionSupabasePublishableKey")
    }

    /// Supabase publishable keys are intentionally safe to ship in a client;
    /// authorization remains enforced by Auth and row-level security.
    static var supabasePublishableKey: String? {
        configuredString(for: "TradeReadySupabasePublishableKey")
    }

    static var passwordResetURL: URL? {
        configuredURL(for: "TradeReadyPasswordResetURL")
    }

    static var emailConfirmationURL: URL? {
        configuredURL(for: "TradeReadyEmailConfirmationURL")
    }

    /// RevenueCat Apple SDK keys are public client identifiers, not secrets.
    static var revenueCatAPIKey: String? {
        configuredString(for: "TradeReadyRevenueCatAPIKey")
    }

    static var revenueCatEntitlementID: String? {
        configuredString(for: "TradeReadyRevenueCatEntitlementID")
    }

    private static func configuredURL(for key: String) -> URL? {
        guard let value = configuredString(for: key) else { return nil }
        return URL(string: value)
    }

    private static func configuredString(for key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("$(") else { return nil }
        return trimmed
    }

    static let allowsProductionWrites: Bool = {
        let configured = Bundle.main.object(forInfoDictionaryKey: "TradeReadyAllowProductionWrites") as? String
        return environment == .production && configured?.uppercased() == "YES"
    }()

    /// Direct Data API writes do not pass through `endpoint`, so they require
    /// their own fail-closed environment boundary. Authentication and read-only
    /// pulls intentionally remain available when writes are blocked.
    static var allowsSupabaseDataWrites: Bool {
        permitsSupabaseDataWrites(
            environment: environment,
            configuredURL: supabaseURL,
            productionURL: productionSupabaseURL,
            configuredPublishableKey: supabasePublishableKey,
            productionPublishableKey: productionSupabasePublishableKey,
            productionWritesEnabled: allowsProductionWrites
        )
    }

    static func permitsSupabaseDataWrites(
        environment: TradeReadyEnvironment,
        configuredURL: URL?,
        productionURL: URL?,
        configuredPublishableKey: String?,
        productionPublishableKey: String?,
        productionWritesEnabled: Bool
    ) -> Bool {
        guard let configuredOrigin = supabaseOrigin(configuredURL),
              let productionOrigin = supabaseOrigin(productionURL),
              let configuredKey = publishableKey(configuredPublishableKey),
              let productionKey = publishableKey(productionPublishableKey)
        else { return false }

        let targetsProduction = configuredOrigin.scheme == productionOrigin.scheme
            && configuredOrigin.host == productionOrigin.host
            && configuredOrigin.port == productionOrigin.port

        switch environment {
        case .production:
            return productionWritesEnabled && targetsProduction && configuredKey == productionKey
        case .development, .staging:
            return !targetsProduction && configuredKey != productionKey
        }
    }

    private static func supabaseOrigin(_ url: URL?) -> (scheme: String, host: String, port: Int)? {
        guard let url,
              url.scheme?.lowercased() == "https",
              var host = url.host?.lowercased(), !host.isEmpty,
              url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/"
        else { return nil }
        while host.hasSuffix(".") { host.removeLast() }
        guard !host.isEmpty else { return nil }
        return ("https", host, url.port ?? 443)
    }

    private static func publishableKey(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("sb_publishable_"), trimmed.count > "sb_publishable_".count
        else { return nil }
        return trimmed
    }

    static func endpoint(_ path: String, sendsUserData: Bool = false) throws -> URL {
        guard let base = backendBaseURL else { throw BuildEnvironmentError.missingBackendURL }
        if sendsUserData,
           base.host == "tradeready-backend.tradeready.workers.dev",
           !allowsProductionWrites {
            throw BuildEnvironmentError.productionWriteBlocked
        }
        return base.appending(path: path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
    }
}
