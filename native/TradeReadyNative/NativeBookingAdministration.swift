import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Authenticated owner transport for `POST /api/booking/admin`
/// (Phase 8 task 8.07; requirements B1, B2).
///
/// Frozen contract: docs/native-phase-8-contract-decisions.md §1 (G3) and §6.
/// Request: `{action: mint|set_enabled|rotate|status, operationId?,
/// enabled?, expectedRevision?, token?}`.
/// Response: `{ok:true, enabled, token?, revision, operationId?,
/// tokenValid?}`. The raw token is returned exactly once per operation and
/// stored hashed server-side; a lost display copy recovers via confirmed
/// `rotate` with a NEW `operationId` — there is no reveal endpoint.
///
/// Outcome classification (callers must honor it):
/// - Definitive refusal (`notFound`, `alreadyExists`, `operationConflict`,
///   `staleRevision`, `invalidRequest`): retrying the same intent cannot
///   succeed. Reconcile (`status`) or mint a new intent instead.
/// - Transient (`rateLimited`, `unavailable`): safe to retry later with the
///   SAME `operationId` (replay returns the stored response, never a second
///   capability). Never retried in a tight loop.
/// - Unknown mutation outcome (`unknownOutcome`): a timeout, transport error,
///   or 5xx after a mutation — the server may have committed. Recover with
///   `status` (and same-`operationId` replay), never an automatic re-mint or
///   re-rotate. This service performs at most one retry, and only for a 401
///   answered by a fresh bearer via `refreshSession` (same request bytes, same
///   `operationId`, therefore replay-safe).
enum NativeBookingAdminError: LocalizedError, Equatable {
    case invalidConfiguration
    case malformedSession
    case rejectedSession
    case invalidRequest
    case notFound
    case alreadyExists
    case operationConflict
    case staleRevision(currentEnabled: Bool, currentRevision: Int)
    case rateLimited
    case invalidResponse
    case unavailable
    case unknownOutcome

    static func == (lhs: NativeBookingAdminError, rhs: NativeBookingAdminError) -> Bool {
        switch (lhs, rhs) {
        case (.invalidConfiguration, .invalidConfiguration),
             (.malformedSession, .malformedSession),
             (.rejectedSession, .rejectedSession),
             (.invalidRequest, .invalidRequest),
             (.notFound, .notFound),
             (.alreadyExists, .alreadyExists),
             (.operationConflict, .operationConflict),
             (.rateLimited, .rateLimited),
             (.invalidResponse, .invalidResponse),
             (.unavailable, .unavailable),
             (.unknownOutcome, .unknownOutcome):
            return true
        case let (.staleRevision(le, lr), .staleRevision(re, rr)):
            return le == re && lr == rr
        default:
            return false
        }
    }

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            "Booking links are not configured for this build."
        case .malformedSession, .rejectedSession:
            "Your session has expired. Sign in again before managing the booking link."
        case .invalidRequest:
            "This booking-link request was invalid and was not sent."
        case .notFound:
            "The booking link was not found. It may have been removed on another device."
        case .alreadyExists:
            "A booking link already exists. Refresh its status instead of creating another."
        case .operationConflict:
            "This operation was already used for a different request. Start a new operation."
        case .staleRevision:
            "The booking link changed on another device. Refresh its status before trying again."
        case .rateLimited:
            "Too many booking-link requests. Wait a moment and try again."
        case .invalidResponse:
            "The booking service returned an unexpected response."
        case .unavailable:
            "The booking service is unavailable. Check your connection and try again."
        case .unknownOutcome:
            "The request may or may not have reached the server. Check the link status before trying again."
        }
    }
}

enum NativeBookingAdminAction: String, Sendable {
    case mint
    case setEnabled = "set_enabled"
    case rotate
    case status
}

/// Typed result of a booking-admin mutation. `token` is present for
/// mint/rotate only, exactly once per operation; `operationId` echoes the
/// request identity so the caller can replay recovery with the same ID.
struct NativeBookingAdminResult: Equatable, Sendable {
    let enabled: Bool
    let revision: Int
    let token: String?
    let operationId: String?
}

/// Authoritative reconciliation read (§6). Share or adopt a display token
/// ONLY when `tokenValid` is true on a fresh read; an eventually synced
/// display copy is never proof of currency.
struct NativeBookingLinkStatus: Equatable, Sendable {
    let enabled: Bool
    let revision: Int
    let tokenValid: Bool
}

protocol NativeBookingAdministrationHTTPDataLoading: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: NativeBookingAdministrationHTTPDataLoading {}

/// Bounded auth-refresh hook (NativeSyncCoordinator convention): invoked at
/// most once per call, only after a 401, and must return current session
/// bytes (same `{access_token,…}` shape). A nil hook — or a hook returning
/// nil — surfaces `.rejectedSession` with no retry.
typealias NativeBookingAdminSessionRefresh = @Sendable () async -> Data?

/// Authenticated client for the booking-admin endpoint. The device sends no
/// owner identifier and never mints a capability token; the backend verifies
/// the current Supabase bearer and derives row ownership.
struct NativeBookingAdministrationService: Sendable {
    static let publicBaseURL = URL(string: "https://gettradereadyapp.com/book.html")!
    static let maxResponseBytes = 64 * 1024

    private struct StoredSession: Decodable {
        let accessToken: String
        enum CodingKeys: String, CodingKey { case accessToken = "access_token" }
    }

    private struct MutationBody: Encodable {
        let action: String
        let operationId: String
        let enabled: Bool?
        let expectedRevision: Int?
    }

    private struct StatusBody: Encodable {
        let action = "status"
        let token: String?
    }

    private struct ResponseBody: Decodable {
        let ok: Bool?
        let enabled: Bool?
        let token: String?
        let revision: Int?
        let operationId: String?
        let tokenValid: Bool?
    }

    private struct ErrorBody: Decodable {
        let error: String?
        let enabled: Bool?
        let revision: Int?
    }

    let endpoint: URL
    let loader: any NativeBookingAdministrationHTTPDataLoading
    let refreshSession: NativeBookingAdminSessionRefresh?

    init(
        endpoint: URL,
        loader: any NativeBookingAdministrationHTTPDataLoading = URLSession.shared,
        refreshSession: NativeBookingAdminSessionRefresh? = nil
    ) {
        self.endpoint = endpoint
        self.loader = loader
        self.refreshSession = refreshSession
    }

    /// Environment boundary: resolves the admin endpoint through the shared
    /// build configuration so non-production builds cannot write to the
    /// production backend and unconfigured builds fail closed.
    static func resolvedEndpoint() throws -> URL {
        do {
            return try BuildEnvironment.endpoint("api/booking/admin", sendsUserData: true)
        } catch {
            throw NativeBookingAdminError.invalidConfiguration
        }
    }

    func mint(operationId: String, expectedRevision: Int? = nil, sessionBytes: Data) async throws -> NativeBookingAdminResult {
        try await mutate(action: .mint, operationId: operationId, enabled: nil, expectedRevision: expectedRevision, sessionBytes: sessionBytes)
    }

    func setEnabled(_ enabled: Bool, operationId: String, expectedRevision: Int? = nil, sessionBytes: Data) async throws -> NativeBookingAdminResult {
        try await mutate(action: .setEnabled, operationId: operationId, enabled: enabled, expectedRevision: expectedRevision, sessionBytes: sessionBytes)
    }

    func rotate(operationId: String, expectedRevision: Int? = nil, sessionBytes: Data) async throws -> NativeBookingAdminResult {
        try await mutate(action: .rotate, operationId: operationId, enabled: nil, expectedRevision: expectedRevision, sessionBytes: sessionBytes)
    }

    func status(token: String? = nil, sessionBytes: Data) async throws -> NativeBookingLinkStatus {
        guard Self.isAllowedEndpoint(endpoint) else { throw NativeBookingAdminError.invalidConfiguration }
        if let token, !Self.isValidDisplayToken(token) { throw NativeBookingAdminError.invalidRequest }
        let bearer = try Self.bearer(from: sessionBytes)
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(StatusBody(token: token))
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let http: HTTPURLResponse
        do {
            (data, http) = try await Self.perform(request, via: loader)
        } catch {
            // Read-only: a timeout is retryable, never an unknown mutation.
            throw NativeBookingAdminError.unavailable
        }
        if http.statusCode == 401, let fresh = await Self.refreshed(refreshSession, from: sessionBytes) {
            // The first attempt died at authentication, before any server
            // state could commit, so one retry with the fresh bearer is safe.
            // Bounded: the retried call never refreshes again.
            var retried = request
            retried.setValue("Bearer \(Self.bearerUnchecked(from: fresh))", forHTTPHeaderField: "Authorization")
            let retryData: Data
            let retryHTTP: HTTPURLResponse
            do {
                (retryData, retryHTTP) = try await Self.perform(retried, via: loader)
            } catch {
                throw NativeBookingAdminError.unavailable
            }
            return try Self.decodeStatus(data: retryData, statusCode: retryHTTP.statusCode)
        }
        if http.statusCode == 401 { throw NativeBookingAdminError.rejectedSession }
        return try Self.decodeStatus(data: data, statusCode: http.statusCode)
    }

    private static func decodeStatus(data: Data, statusCode: Int) throws -> NativeBookingLinkStatus {
        switch statusCode {
        case 200..<300: break
        case 401, 403: throw NativeBookingAdminError.rejectedSession
        case 404: throw NativeBookingAdminError.notFound
        case 429: throw NativeBookingAdminError.rateLimited
        case 500...599: throw NativeBookingAdminError.unavailable
        default: throw NativeBookingAdminError.unavailable
        }
        guard data.count <= maxResponseBytes,
              let decoded = try? JSONDecoder().decode(ResponseBody.self, from: data),
              decoded.ok == true,
              let enabled = decoded.enabled,
              let revision = decoded.revision, revision >= 0,
              decoded.token == nil
        else { throw NativeBookingAdminError.invalidResponse }
        return NativeBookingLinkStatus(
            enabled: enabled,
            revision: revision,
            tokenValid: decoded.tokenValid ?? false
        )
    }

    // MARK: - Mutations

    private func mutate(
        action: NativeBookingAdminAction,
        operationId: String,
        enabled: Bool?,
        expectedRevision: Int?,
        sessionBytes: Data
    ) async throws -> NativeBookingAdminResult {
        guard Self.isAllowedEndpoint(endpoint) else { throw NativeBookingAdminError.invalidConfiguration }
        guard Self.isValidOperationID(operationId) else { throw NativeBookingAdminError.invalidRequest }
        if action == .setEnabled, enabled == nil { throw NativeBookingAdminError.invalidRequest }
        if let expectedRevision, expectedRevision < 0 { throw NativeBookingAdminError.invalidRequest }
        let bearer = try Self.bearer(from: sessionBytes)

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(MutationBody(
            action: action.rawValue,
            operationId: operationId,
            enabled: action == .setEnabled ? enabled : nil,
            expectedRevision: expectedRevision
        ))
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let http: HTTPURLResponse
        do {
            (data, http) = try await Self.perform(request, via: loader)
        } catch {
            // Unknown outcome: the mutation may have committed server-side.
            // The caller recovers with `status` / same-operationId replay.
            throw NativeBookingAdminError.unknownOutcome
        }
        if http.statusCode == 401 {
            guard let fresh = await Self.refreshed(refreshSession, from: sessionBytes) else {
                throw NativeBookingAdminError.rejectedSession
            }
            var retried = request
            retried.setValue("Bearer \(Self.bearerUnchecked(from: fresh))", forHTTPHeaderField: "Authorization")
            let retryData: Data
            let retryHTTP: HTTPURLResponse
            do {
                (retryData, retryHTTP) = try await Self.perform(retried, via: loader)
            } catch {
                throw NativeBookingAdminError.unknownOutcome
            }
            return try Self.decodeMutation(data: retryData, statusCode: retryHTTP.statusCode, action: action, operationId: operationId)
        }
        return try Self.decodeMutation(data: data, statusCode: http.statusCode, action: action, operationId: operationId)
    }

    private static func decodeMutation(
        data: Data,
        statusCode: Int,
        action: NativeBookingAdminAction,
        operationId: String
    ) throws -> NativeBookingAdminResult {
        switch statusCode {
        case 200..<300: break
        case 400: throw NativeBookingAdminError.invalidRequest
        case 401, 403: throw NativeBookingAdminError.rejectedSession
        case 404: throw NativeBookingAdminError.notFound
        case 409:
            guard data.count <= maxResponseBytes,
                  let decoded = try? JSONDecoder().decode(ErrorBody.self, from: data)
            else { throw NativeBookingAdminError.invalidResponse }
            switch decoded.error {
            case "already_exists": throw NativeBookingAdminError.alreadyExists
            case "operation_conflict": throw NativeBookingAdminError.operationConflict
            case "stale_revision":
                guard let enabled = decoded.enabled, let revision = decoded.revision, revision >= 0 else {
                    throw NativeBookingAdminError.invalidResponse
                }
                throw NativeBookingAdminError.staleRevision(currentEnabled: enabled, currentRevision: revision)
            default: throw NativeBookingAdminError.invalidResponse
            }
        case 429: throw NativeBookingAdminError.rateLimited
        case 500...599: throw NativeBookingAdminError.unknownOutcome
        default: throw NativeBookingAdminError.unavailable
        }
        guard data.count <= maxResponseBytes,
              let decoded = try? JSONDecoder().decode(ResponseBody.self, from: data),
              decoded.ok == true,
              let enabled = decoded.enabled,
              let revision = decoded.revision, revision >= 0
        else { throw NativeBookingAdminError.invalidResponse }
        if action == .mint || action == .rotate {
            guard let token = decoded.token, isValidCapabilityToken(token) else {
                throw NativeBookingAdminError.invalidResponse
            }
            return NativeBookingAdminResult(enabled: enabled, revision: revision, token: token, operationId: decoded.operationId ?? operationId)
        }
        if decoded.token != nil { throw NativeBookingAdminError.invalidResponse }
        return NativeBookingAdminResult(enabled: enabled, revision: revision, token: nil, operationId: decoded.operationId ?? operationId)
    }

    // MARK: - Shared guards

    private static func perform(
        _ request: URLRequest,
        via loader: any NativeBookingAdministrationHTTPDataLoading
    ) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await loader.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw NativeBookingAdminError.invalidResponse }
        return (data, http)
    }

    private static func bearer(from sessionBytes: Data) throws -> String {
        guard let session = try? JSONDecoder().decode(StoredSession.self, from: sessionBytes),
              !session.accessToken.isEmpty,
              session.accessToken.count <= 4096,
              session.accessToken.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
        else { throw NativeBookingAdminError.malformedSession }
        return session.accessToken
    }

    private static func bearerUnchecked(from sessionBytes: Data) -> String {
        (try? JSONDecoder().decode(StoredSession.self, from: sessionBytes))?.accessToken ?? ""
    }

    private static func refreshed(
        _ refresh: NativeBookingAdminSessionRefresh?,
        from used: Data
    ) async -> Data? {
        guard let refresh else { return nil }
        guard let fresh = await refresh(), fresh != used,
              (try? JSONDecoder().decode(StoredSession.self, from: fresh))?.accessToken.isEmpty == false
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

    static func isValidOperationID(_ value: String) -> Bool {
        guard value.count == 36 else { return false }
        guard let uuid = UUID(uuidString: value) else { return false }
        // Canonical UUID string round-trip rejects malformed shapes; the
        // version (v4) and variant (RFC 4122) nibbles must match the frozen
        // server vocabulary or the route answers `Invalid operation id`.
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

    static func isValidDisplayToken(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 512
            && value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
    }

    /// Customer-facing share URL. The token is validated before encoding so
    /// a stale or fabricated display copy can never become a share URL.
    static func bookingURL(token: String) -> URL? {
        guard isValidCapabilityToken(token),
              var components = URLComponents(url: publicBaseURL, resolvingAgainstBaseURL: false)
        else { return nil }
        components.queryItems = [URLQueryItem(name: "b", value: token)]
        return components.url
    }

    static func isValidBookingURL(_ url: URL, token: String) -> Bool {
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
        return values["b"] == token
    }
}

/// Durable-mirror rule for the server-acknowledged booking link. Merges ONLY
/// the server-issued `token`/`enabled` keys into the `bookingLink` object;
/// every other settings field — including unknown forward-compatible fields
/// at both levels — survives the JSON round-trip untouched.
/// `set_enabled` results (no token) require an existing link and update the
/// flag only, preserving the token. Fails closed when there is nothing
/// truthful to mirror.
enum NativeBookingAdminMirror {
    static func apply(
        to settings: Canonical.Settings,
        token: String?,
        enabled: Bool
    ) throws -> Canonical.Settings {
        if let token {
            guard NativeBookingAdministrationService.isValidCapabilityToken(token) else {
                throw NativeBookingAdminError.invalidResponse
            }
        }
        let encoded = try JSONEncoder().encode(settings)
        guard var fields = try? JSONDecoder().decode([String: Canonical.JSONValue].self, from: encoded) else {
            throw NativeBookingAdminError.invalidResponse
        }
        var link: [String: Canonical.JSONValue]
        switch fields["bookingLink"] {
        case let .object(existing):
            link = existing
        case .null, nil:
            guard token != nil else { throw NativeBookingAdminError.invalidResponse }
            link = [:]
        default:
            throw NativeBookingAdminError.invalidResponse
        }
        if let token { link["token"] = .string(token) }
        guard link["token"] != nil else { throw NativeBookingAdminError.invalidResponse }
        link["enabled"] = .bool(enabled)
        fields["bookingLink"] = .object(link)
        guard let merged = try? JSONDecoder().decode(
            Canonical.Settings.self,
            from: JSONEncoder().encode(fields)
        ) else { throw NativeBookingAdminError.invalidResponse }
        return merged
    }
}
