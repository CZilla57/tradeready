import Foundation

/// A resolved, enabled analytics configuration (contract §9.2).
struct NativeAnalyticsConfiguration: Equatable, Sendable {
    let apiKey: String
    let host: URL
}

/// The analytics gate (task 11.07, contract §9.2, C14). Pure and
/// Foundation-only; `NativeAnalyticsTransport.live()` feeds it the build
/// flavor and the Info.plist values.
///
/// Analytics is enabled iff all three hold:
/// 1. a non-Debug build (`#if !DEBUG`);
/// 2. `TradeReadyPostHogAPIKey` (Info.plist, from the build setting
///    `TRADEREADY_POSTHOG_API_KEY`) is non-empty after trimming and is not an
///    unexpanded `$(...)` reference;
/// 3. that key does not start with `PLACEHOLDER` (RN `App.tsx:105`).
///
/// `TradeReadyPostHogHost` (from `TRADEREADY_POSTHOG_HOST`) defaults to
/// `https://us.i.posthog.com` when empty. A non-empty host that is not a bare
/// `https` origin disables analytics rather than sending somewhere unexpected.
///
/// Recorded deviation: RN sent PostHog events from dev builds; native Debug is
/// silent. Neither committed build configuration sets a key, so both the
/// Debug (development) and Release (staging) builds are disabled until a key
/// is supplied at build time (see plan §7, 11.07).
enum NativeAnalyticsGate {
    enum Resolution: Equatable, Sendable {
        case enabled(NativeAnalyticsConfiguration)
        case disabled(NativeAnalyticsDiagnostic.Reason)
    }

    static let apiKeyInfoKey = "TradeReadyPostHogAPIKey"
    static let hostInfoKey = "TradeReadyPostHogHost"
    static let defaultHost = "https://us.i.posthog.com"
    static let placeholderPrefix = "PLACEHOLDER"

    static var isDebugBuild: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    static func resolve(isDebugBuild: Bool, apiKey: String?, host: String?) -> Resolution {
        if isDebugBuild { return .disabled(.disabledDebugBuild) }
        guard let key = configured(apiKey) else { return .disabled(.disabledMissingKey) }
        if key.hasPrefix(placeholderPrefix) { return .disabled(.disabledPlaceholderKey) }
        guard let hostURL = resolvedHost(host) else { return .disabled(.disabledInvalidHost) }
        return .enabled(NativeAnalyticsConfiguration(apiKey: key, host: hostURL))
    }

    /// Composes the transport. Only an `.enabled` resolution builds an SDK
    /// adapter; a disabled gate or an adapter that fails to set up yields a
    /// transport that emits nothing. Either way one bounded diagnostic is
    /// reported (§9.2 "one bounded debug log") and nothing crashes.
    static func makeTransport(
        resolution: Resolution,
        makeAdapter: (NativeAnalyticsConfiguration) throws -> NativeAnalyticsSDKAdapter,
        policy: NativeAnalyticsPrivacyPolicy = .standard,
        diagnostics: @escaping NativeAnalyticsTransport.DiagnosticSink = { _ in },
        catalogViolation: @escaping (String) -> Void = NativeAnalyticsTransport.defaultCatalogViolationHandler
    ) -> NativeAnalyticsTransport {
        var adapter: NativeAnalyticsSDKAdapter?
        switch resolution {
        case .disabled(let reason):
            diagnostics(.init(operation: .setup, issues: [.init(key: "", reason: reason)]))
        case .enabled(let configuration):
            do {
                adapter = try makeAdapter(configuration)
            } catch {
                diagnostics(.init(operation: .setup, issues: [.init(key: "", reason: .adapterSetupFailed)]))
            }
        }
        return NativeAnalyticsTransport(
            adapter: adapter,
            policy: policy,
            diagnostics: diagnostics,
            catalogViolation: catalogViolation
        )
    }

    private static func configured(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty, !trimmed.hasPrefix("$(")
        else { return nil }
        return trimmed
    }

    private static func resolvedHost(_ value: String?) -> URL? {
        let raw = configured(value) ?? defaultHost
        guard let url = URL(string: raw),
              url.scheme?.lowercased() == "https",
              let hostName = url.host, !hostName.isEmpty,
              url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/"
        else { return nil }
        return url
    }
}
