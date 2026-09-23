import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Authenticated owner transport for `POST /api/estimate/portal-manage`
/// (Phase 8 task 8.07; requirement P1).
///
/// Frozen contract: docs/native-phase-8-contract-decisions.md §4 (G4) and §6.
/// Request: `{action: mint|set_enabled|rotate|status, customerId,
/// enabled?, operationId?, token?}`.
/// Response: `{ok:true, token?, enabled?, tokenValid?, adopted?}`.
/// At most one non-revoked row per customer; `mint` refuses with 409
/// `already_exists` when ANY live row exists (re-enable via `set_enabled`,
/// destruction only via `rotate`). `rotate` works from zero rows
/// (rotate-as-create). Unknown/foreign customer stays 404 (no oracle).
///
/// Outcome classification (same lane contract as booking administration):
/// - Definitive refusal (`notFound`, `alreadyExists`, `operationConflict`,
///   `invalidRequest`): a stale-paint Create that hits `already_exists` must
///   refresh authority and adopt only a matching current display copy — never
///   an implicit rotate. Retry-display persistence without repeating server
///   work via the echoed `operationId`.
/// - Transient (`rateLimited`, `unavailable`): retry later with the SAME
///   `operationId` (replay returns the stored response).
/// - Unknown mutation outcome (`unknownOutcome`): timeout, transport error,
///   or 5xx after a mutation — the token row may have committed. Recover
///   with `status`, never an automatic re-mint/re-rotate. At most one
///   401-driven refresh retry per call (same bytes, same `operationId`).
enum NativePortalAdminError: LocalizedError, Equatable {
    case invalidConfiguration
    case malformedSession
    case rejectedSession
    case invalidRequest
    case notFound
    case alreadyExists
    case operationConflict
    case rateLimited
    case invalidResponse
    case unavailable
    case unknownOutcome
    case customerChanged

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            "Customer portal links are not configured for this build."
        case .malformedSession, .rejectedSession:
            "Your session has expired. Sign in again before managing portal links."
        case .invalidRequest:
            "This portal-link request was invalid and was not sent."
        case .notFound:
            "The customer was not found. It may have been removed on another device."
        case .alreadyExists:
            "This customer already has a portal link. Refresh its status instead of creating another."
        case .operationConflict:
            "This operation was already used for a different request. Start a new operation."
        case .rateLimited:
            "Too many portal-link requests. Wait a moment and try again."
        case .invalidResponse:
            "The portal service returned an unexpected response."
        case .unavailable:
            "The portal service is unavailable. Check your connection and try again."
        case .unknownOutcome:
            "The request may or may not have reached the server. Check the link status before trying again."
        case .customerChanged:
            "The customer changed while the request was open. Review the latest customer before managing its link."
        }
    }
}

enum NativePortalAdminAction: String, Sendable {
    case mint
    case setEnabled = "set_enabled"
    case rotate
    case status
}

/// Typed result of a portal-admin mutation. `token` is present for
/// mint/rotate only, exactly once per operation; `operationId` echoes the
/// request identity for replay recovery.
struct NativePortalAdminResult: Equatable, Sendable {
    let customerId: String
    let token: String?
    let enabled: Bool?
    let operationId: String
}

/// Authoritative reconciliation read (§6). Share or adopt a display token
/// ONLY when `tokenValid` is true on a fresh read. `adopted` reports whether
/// the customer is under server authority yet (unadopted customers still
/// resolve through the legacy display copy).
struct NativePortalLinkStatus: Equatable, Sendable {
    let customerId: String
    let enabled: Bool
    let tokenValid: Bool
    let adopted: Bool
}

protocol NativePortalAdministrationHTTPDataLoading: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: NativePortalAdministrationHTTPDataLoading {}

/// Bounded auth-refresh hook (NativeSyncCoordinator convention): invoked at
/// most once per call, only after a 401, and must return current session
/// bytes. A nil hook — or a hook returning nil/stale bytes — surfaces
/// `.rejectedSession` with no retry.
typealias NativePortalAdminSessionRefresh = @Sendable () async -> Data?

/// Authenticated client for the portal-manage endpoint. The device sends no
/// owner identifier and never mints a capability token; the backend verifies
/// the current Supabase bearer and derives row ownership.
struct NativePortalAdministrationService: Sendable {
    static let publicBaseURL = URL(string: "https://gettradereadyapp.com/portal.html")!
    static let maxResponseBytes = 64 * 1024

    private struct StoredSession: Decodable {
        let accessToken: String
        enum CodingKeys: String, CodingKey { case accessToken = "access_token" }
    }

    private struct MutationBody: Encodable {
        let action: String
        let customerId: String
        let enabled: Bool?
        let operationId: String
    }

    private struct StatusBody: Encodable {
        let action = "status"
        let customerId: String
        let token: String?
    }

    private struct ResponseBody: Decodable {
        let ok: Bool?
        let token: String?
        let enabled: Bool?
        let tokenValid: Bool?
        let adopted: Bool?
    }

    private struct ErrorBody: Decodable {
        let error: String?
    }

    let endpoint: URL
    let loader: any NativePortalAdministrationHTTPDataLoading
    let refreshSession: NativePortalAdminSessionRefresh?

    init(
        endpoint: URL,
        loader: any NativePortalAdministrationHTTPDataLoading = URLSession.shared,
        refreshSession: NativePortalAdminSessionRefresh? = nil
    ) {
        self.endpoint = endpoint
        self.loader = loader
        self.refreshSession = refreshSession
    }

    /// Environment boundary: resolves the portal-manage endpoint through the
    /// shared build configuration so non-production builds cannot write to
    /// the production backend and unconfigured builds fail closed.
    static func resolvedEndpoint() throws -> URL {
        do {
            return try BuildEnvironment.endpoint("api/estimate/portal-manage", sendsUserData: true)
        } catch {
            throw NativePortalAdminError.invalidConfiguration
        }
    }

    func mint(customerId: String, operationId: String, sessionBytes: Data) async throws -> NativePortalAdminResult {
        try await mutate(action: .mint, customerId: customerId, enabled: nil, operationId: operationId, sessionBytes: sessionBytes)
    }

    func setEnabled(_ enabled: Bool, customerId: String, operationId: String, sessionBytes: Data) async throws -> NativePortalAdminResult {
        try await mutate(action: .setEnabled, customerId: customerId, enabled: enabled, operationId: operationId, sessionBytes: sessionBytes)
    }

    func rotate(customerId: String, operationId: String, sessionBytes: Data) async throws -> NativePortalAdminResult {
        try await mutate(action: .rotate, customerId: customerId, enabled: nil, operationId: operationId, sessionBytes: sessionBytes)
    }

    func status(customerId: String, token: String? = nil, sessionBytes: Data) async throws -> NativePortalLinkStatus {
        guard Self.isAllowedEndpoint(endpoint) else { throw NativePortalAdminError.invalidConfiguration }
        guard Self.isValidID(customerId) else { throw NativePortalAdminError.invalidRequest }
        if let token, !Self.isValidDisplayToken(token) { throw NativePortalAdminError.invalidRequest }
        let bearer = try Self.bearer(from: sessionBytes)
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(StatusBody(customerId: customerId, token: token))
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let http: HTTPURLResponse
        do {
            (data, http) = try await Self.perform(request, via: loader)
        } catch {
            // Read-only: a timeout is retryable, never an unknown mutation.
            throw NativePortalAdminError.unavailable
        }
        if http.statusCode == 401, let fresh = await Self.refreshed(refreshSession, from: sessionBytes) {
            // Bounded: the retried call never refreshes again.
            var retried = request
            if let freshBearer = try? Self.bearer(from: fresh) {
                retried.setValue("Bearer \(freshBearer)", forHTTPHeaderField: "Authorization")
            }
            let retryData: Data
            let retryHTTP: HTTPURLResponse
            do {
                (retryData, retryHTTP) = try await Self.perform(retried, via: loader)
            } catch {
                throw NativePortalAdminError.unavailable
            }
            return try Self.decodeStatus(data: retryData, statusCode: retryHTTP.statusCode, customerId: customerId)
        }
        if http.statusCode == 401 { throw NativePortalAdminError.rejectedSession }
        return try Self.decodeStatus(data: data, statusCode: http.statusCode, customerId: customerId)
    }

    private static func decodeStatus(
        data: Data,
        statusCode: Int,
        customerId: String
    ) throws -> NativePortalLinkStatus {
        switch statusCode {
        case 200..<300: break
        case 400: throw NativePortalAdminError.invalidRequest
        case 401, 403: throw NativePortalAdminError.rejectedSession
        case 404: throw NativePortalAdminError.notFound
        case 409:
            guard data.count <= maxResponseBytes,
                  let decoded = try? JSONDecoder().decode(ErrorBody.self, from: data)
            else { throw NativePortalAdminError.invalidResponse }
            switch decoded.error {
            case "already_exists": throw NativePortalAdminError.alreadyExists
            case "operation_conflict": throw NativePortalAdminError.operationConflict
            default: throw NativePortalAdminError.invalidResponse
            }
        case 429: throw NativePortalAdminError.rateLimited
        case 500...599: throw NativePortalAdminError.unavailable
        default: throw NativePortalAdminError.unavailable
        }
        guard data.count <= maxResponseBytes,
              let decoded = try? JSONDecoder().decode(ResponseBody.self, from: data),
              decoded.ok == true,
              let enabled = decoded.enabled,
              let tokenValid = decoded.tokenValid,
              let adopted = decoded.adopted,
              decoded.token == nil
        else { throw NativePortalAdminError.invalidResponse }
        return NativePortalLinkStatus(customerId: customerId, enabled: enabled, tokenValid: tokenValid, adopted: adopted)
    }

    // MARK: - Mutations

    private func mutate(
        action: NativePortalAdminAction,
        customerId: String,
        enabled: Bool?,
        operationId: String,
        sessionBytes: Data
    ) async throws -> NativePortalAdminResult {
        guard Self.isAllowedEndpoint(endpoint) else { throw NativePortalAdminError.invalidConfiguration }
        guard Self.isValidID(customerId) else { throw NativePortalAdminError.invalidRequest }
        // Native always sends a client-generated UUID v4 so response loss
        // replays the same operation instead of minting a second capability.
        guard Self.isValidOperationID(operationId) else { throw NativePortalAdminError.invalidRequest }
        if action == .setEnabled, enabled == nil { throw NativePortalAdminError.invalidRequest }
        let bearer = try Self.bearer(from: sessionBytes)

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(MutationBody(
            action: action.rawValue,
            customerId: customerId,
            enabled: action == .setEnabled ? enabled : nil,
            operationId: operationId
        ))
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let http: HTTPURLResponse
        do {
            (data, http) = try await Self.perform(request, via: loader)
        } catch {
            // Unknown outcome: the token row may have committed. The caller
            // recovers with `status` / same-operationId replay.
            throw NativePortalAdminError.unknownOutcome
        }
        if http.statusCode == 401 {
            guard let fresh = await Self.refreshed(refreshSession, from: sessionBytes),
                  let freshBearer = try? Self.bearer(from: fresh)
            else { throw NativePortalAdminError.rejectedSession }
            var retried = request
            retried.setValue("Bearer \(freshBearer)", forHTTPHeaderField: "Authorization")
            let retryData: Data
            let retryHTTP: HTTPURLResponse
            do {
                (retryData, retryHTTP) = try await Self.perform(retried, via: loader)
            } catch {
                throw NativePortalAdminError.unknownOutcome
            }
            return try Self.decodeMutation(data: retryData, statusCode: retryHTTP.statusCode, action: action, customerId: customerId, operationId: operationId)
        }
        return try Self.decodeMutation(data: data, statusCode: http.statusCode, action: action, customerId: customerId, operationId: operationId)
    }

    private static func decodeMutation(
        data: Data,
        statusCode: Int,
        action: NativePortalAdminAction,
        customerId: String,
        operationId: String
    ) throws -> NativePortalAdminResult {
        switch statusCode {
        case 200..<300: break
        case 400: throw NativePortalAdminError.invalidRequest
        case 401, 403: throw NativePortalAdminError.rejectedSession
        case 404: throw NativePortalAdminError.notFound
        case 409:
            guard data.count <= maxResponseBytes,
                  let decoded = try? JSONDecoder().decode(ErrorBody.self, from: data)
            else { throw NativePortalAdminError.invalidResponse }
            switch decoded.error {
            case "already_exists": throw NativePortalAdminError.alreadyExists
            case "operation_conflict": throw NativePortalAdminError.operationConflict
            default: throw NativePortalAdminError.invalidResponse
            }
        case 429: throw NativePortalAdminError.rateLimited
        case 500...599: throw NativePortalAdminError.unknownOutcome
        default: throw NativePortalAdminError.unavailable
        }
        guard data.count <= maxResponseBytes,
              let decoded = try? JSONDecoder().decode(ResponseBody.self, from: data),
              decoded.ok == true
        else { throw NativePortalAdminError.invalidResponse }
        if action == .mint || action == .rotate {
            guard let token = decoded.token, isValidCapabilityToken(token) else {
                throw NativePortalAdminError.invalidResponse
            }
            return NativePortalAdminResult(customerId: customerId, token: token, enabled: decoded.enabled, operationId: operationId)
        }
        if decoded.token != nil { throw NativePortalAdminError.invalidResponse }
        return NativePortalAdminResult(customerId: customerId, token: nil, enabled: decoded.enabled, operationId: operationId)
    }

    // MARK: - Shared guards

    private static func perform(
        _ request: URLRequest,
        via loader: any NativePortalAdministrationHTTPDataLoading
    ) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await loader.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw NativePortalAdminError.invalidResponse }
        return (data, http)
    }

    private static func bearer(from sessionBytes: Data) throws -> String {
        guard let session = try? JSONDecoder().decode(StoredSession.self, from: sessionBytes),
              !session.accessToken.isEmpty,
              session.accessToken.count <= 4096,
              session.accessToken.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
        else { throw NativePortalAdminError.malformedSession }
        return session.accessToken
    }

    private static func refreshed(
        _ refresh: NativePortalAdminSessionRefresh?,
        from used: Data
    ) async -> Data? {
        guard let refresh else { return nil }
        guard let fresh = await refresh(), fresh != used,
              (try? bearer(from: fresh)) != nil
        else { return nil }
        return fresh
    }

    static func isAllowedEndpoint(_ url: URL) -> Bool {
        guard url.host != nil, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil
        else { return false }
        if url.scheme?.lowercased() == "https" { return true }
        return url.scheme?.lowercased() == "http"
            && ["localhost", "127.0.0.1", "::1"].contains(url.host ?? "")
    }

    static func isValidID(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.count <= 200 && trimmed == value
    }

    static func isValidOperationID(_ value: String) -> Bool {
        guard value.count == 36 else { return false }
        guard let uuid = UUID(uuidString: value) else { return false }
        let canonical = uuid.uuidString.lowercased()
        guard canonical == value.lowercased() else { return false }
        let versionIndex = canonical.index(canonical.startIndex, offsetBy: 14)
        let variantIndex = canonical.index(canonical.startIndex, offsetBy: 19)
        return canonical[versionIndex] == "4" && "89ab".contains(canonical[variantIndex])
    }

    /// Server-minted capability: 24 random bytes rendered as 48 hex chars.
    static func isValidCapabilityToken(_ value: String) -> Bool {
        guard value.count == 48 else { return false }
        return value.allSatisfy { $0.isASCII && $0.isHexDigit }
    }

    /// Display copy presented for a status read. Legacy blob copies predate
    /// server RNG, so only emptiness/whitespace/size are enforced here;
    /// currency is decided by the server's `tokenValid`, never locally.
    static func isValidDisplayToken(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 512
            && value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
    }

    /// Customer-facing share URL. The token is validated before encoding so
    /// a stale or fabricated display copy can never become a share URL.
    static func portalURL(token: String) -> URL? {
        guard isValidCapabilityToken(token),
              var components = URLComponents(url: publicBaseURL, resolvingAgainstBaseURL: false)
        else { return nil }
        components.queryItems = [URLQueryItem(name: "p", value: token)]
        return components.url
    }

    static func isValidPortalURL(_ url: URL, token: String) -> Bool {
        guard isValidCapabilityToken(token),
              url.scheme?.lowercased() == "https",
              url.host?.lowercased() == publicBaseURL.host?.lowercased(),
              url.path == publicBaseURL.path,
              url.user == nil, url.password == nil, url.fragment == nil,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return false }
        let values = Dictionary(
            (components.queryItems ?? []).map { ($0.name, $0.value ?? "") },
            uniquingKeysWith: { first, _ in first }
        )
        return values["p"] == token
    }
}

/// Durable-mirror rule for the server-acknowledged portal link. Merges ONLY
/// the server-issued `token`/`enabled` keys into the `portal` object of the
/// EXACT customer; every other customer field — including unknown
/// forward-compatible fields at both levels — survives the JSON round-trip
/// untouched. `set_enabled` results (no token) require an existing portal
/// copy and update the flag only. A mismatched customer id fails closed
/// (exact-ID recheck at the mirror boundary).
enum NativePortalAdminMirror {
    static func apply(
        to customer: Canonical.Customer,
        customerId: String,
        token: String?,
        enabled: Bool
    ) throws -> Canonical.Customer {
        guard customer.id == customerId, !customerId.isEmpty else {
            throw NativePortalAdminError.customerChanged
        }
        if let token {
            guard NativePortalAdministrationService.isValidCapabilityToken(token) else {
                throw NativePortalAdminError.invalidResponse
            }
        }
        let encoded = try JSONEncoder().encode(customer)
        guard var fields = try? JSONDecoder().decode([String: Canonical.JSONValue].self, from: encoded) else {
            throw NativePortalAdminError.invalidResponse
        }
        var portal: [String: Canonical.JSONValue]
        switch fields["portal"] {
        case let .object(existing):
            portal = existing
        case .null, nil:
            guard token != nil else { throw NativePortalAdminError.invalidResponse }
            portal = [:]
        default:
            throw NativePortalAdminError.invalidResponse
        }
        if let token { portal["token"] = .string(token) }
        guard portal["token"] != nil else { throw NativePortalAdminError.invalidResponse }
        portal["enabled"] = .bool(enabled)
        fields["portal"] = .object(portal)
        guard let merged = try? JSONDecoder().decode(
            Canonical.Customer.self,
            from: JSONEncoder().encode(fields)
        ), merged.id == customerId else { throw NativePortalAdminError.invalidResponse }
        return merged
    }
}
