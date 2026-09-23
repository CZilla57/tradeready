import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Typed Stripe Connect lifecycle transport mirroring
/// `screens/SettingsPaymentsScreen.tsx` against the existing Worker routes:
/// `GET /api/stripe/connect-status`,
/// `POST /api/stripe/create-connect-account` → `{ onboarding_url }`,
/// `POST /api/stripe/disconnect`.
///
/// Standalone-compilable (Foundation only) so the `swiftc` focused harness
/// compiles it alone. Validation mirrors `NativeInvoiceDeliveryService`:
/// endpoints must be host-bearing URLs with no embedded credentials, and only
/// the returned onboarding URL (opened in the system browser) is trusted —
/// the return navigation is a refresh trigger, never proof of connection.
enum NativeStripeConnectError: Error, Equatable {
    case invalidConfiguration, malformedSession, rejectedSession, invalidResponse, unavailable
}

struct NativeStripeConnectStatus: Equatable {
    /// No connected account on file (or the account was deleted on Stripe's side).
    var connected: Bool
    /// Mirrors the status API's `details_submitted` contract — not a full
    /// charges/payouts capability model; UI copy must not claim more.
    var detailsSubmitted: Bool
    var displayName: String?
}

protocol NativeStripeConnectHTTPDataLoading: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}
extension URLSession: NativeStripeConnectHTTPDataLoading {}

struct NativeStripeConnectService: Sendable {
    private struct Session: Decodable {
        let accessToken: String
        enum CodingKeys: String, CodingKey { case accessToken = "access_token" }
    }
    private struct StatusBody: Decodable {
        var connected: Bool?
        var detailsSubmitted: Bool?
        var displayName: String?
        enum CodingKeys: String, CodingKey {
            case connected
            case detailsSubmitted = "details_submitted"
            case displayName = "display_name"
        }
    }
    private struct OnboardingBody: Decodable {
        var onboardingURL: String?
        enum CodingKeys: String, CodingKey { case onboardingURL = "onboarding_url" }
    }

    let statusEndpoint: URL
    let connectEndpoint: URL
    let disconnectEndpoint: URL
    let loader: any NativeStripeConnectHTTPDataLoading

    init(
        statusEndpoint: URL,
        connectEndpoint: URL,
        disconnectEndpoint: URL,
        loader: any NativeStripeConnectHTTPDataLoading = URLSession.shared
    ) {
        self.statusEndpoint = statusEndpoint
        self.connectEndpoint = connectEndpoint
        self.disconnectEndpoint = disconnectEndpoint
        self.loader = loader
    }

    func status(sessionBytes: Data) async throws -> NativeStripeConnectStatus {
        guard Self.validEndpoint(statusEndpoint) else { throw NativeStripeConnectError.invalidConfiguration }
        let token = try accessToken(sessionBytes)
        var request = URLRequest(url: statusEndpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await load(request)
        try success(response)
        guard let body = try? JSONDecoder().decode(StatusBody.self, from: data),
              let connected = body.connected
        else { throw NativeStripeConnectError.invalidResponse }
        // A connected account deleted on Stripe's side reads as disconnected.
        guard connected else { return NativeStripeConnectStatus(connected: false, detailsSubmitted: false, displayName: nil) }
        return NativeStripeConnectStatus(
            connected: true,
            detailsSubmitted: body.detailsSubmitted ?? false,
            displayName: body.displayName.flatMap { $0.isEmpty ? nil : $0 })
    }

    /// Starts (or resumes) onboarding; the returned URL must be opened in the
    /// system browser. Refresh status on foreground return afterwards.
    func beginOnboarding(sessionBytes: Data) async throws -> URL {
        guard Self.validEndpoint(connectEndpoint) else { throw NativeStripeConnectError.invalidConfiguration }
        let token = try accessToken(sessionBytes)
        var request = URLRequest(url: connectEndpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await load(request)
        try success(response)
        guard let body = try? JSONDecoder().decode(OnboardingBody.self, from: data),
              let raw = body.onboardingURL,
              let url = URL(string: raw),
              Self.validPublicURL(url)
        else { throw NativeStripeConnectError.invalidResponse }
        return url
    }

    func disconnect(sessionBytes: Data) async throws {
        guard Self.validEndpoint(disconnectEndpoint) else { throw NativeStripeConnectError.invalidConfiguration }
        let token = try accessToken(sessionBytes)
        var request = URLRequest(url: disconnectEndpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (_, response) = try await load(request)
        try success(response)
    }

    private func accessToken(_ bytes: Data) throws -> String {
        guard let session = try? JSONDecoder().decode(Session.self, from: bytes),
              !session.accessToken.isEmpty
        else { throw NativeStripeConnectError.malformedSession }
        return session.accessToken
    }

    private func load(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do { return try await loader.data(for: request) }
        catch { throw NativeStripeConnectError.unavailable }
    }

    private func success(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw NativeStripeConnectError.invalidResponse }
        if http.statusCode == 401 || http.statusCode == 403 { throw NativeStripeConnectError.rejectedSession }
        guard (200..<300).contains(http.statusCode) else { throw NativeStripeConnectError.unavailable }
    }

    private static func validEndpoint(_ url: URL) -> Bool {
        url.host != nil && url.user == nil && url.password == nil
            && url.query == nil && url.fragment == nil
            && (url.scheme == "https"
                || (url.scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(url.host ?? "")))
    }

    private static func validPublicURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host != nil && url.user == nil && url.password == nil && url.fragment == nil
    }
}
