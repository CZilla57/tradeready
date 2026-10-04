import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Authenticated owner transport for `POST /api/api-keys/manage` (Roadmap
/// Phase 23, open-API spec §9; the settled contract is the spec's build
/// record §14.1). It copies the `NativePortalAdministrationService` shape: an
/// endpoint allowlist, the Supabase JWT as the bearer, at most one
/// refresh-and-retry after a 401, client operation ids, and typed errors. It
/// holds no state: the server is the authority for every key.
///
/// The raw key (`secret`) appears in exactly two responses, `create` and
/// `rotate`, once. It is wrapped in `NativeAPIKeySecret` as soon as it is
/// decoded and is never stored, logged or echoed in an error. Responses go
/// through an ephemeral session with caching off, so not even a URL cache
/// holds the body.
///
/// Outcome classification:
/// - Definitive refusals (`invalidRequest`, `notFound`, `keyLimit`,
///   `alreadyCompleted`, `operationConflict`, `methodNotAllowed`): the server
///   answered and nothing more will happen for this operation.
/// - Unknown mutation outcome (`unknownOutcome`): a timeout, a dropped
///   connection, a 5xx or an unreadable 200 after `create`/`rotate`. The key
///   may exist. Retry with the SAME `operationId`: the server replays it
///   (`200` if it never committed, else `409 already_completed` with the
///   key's id and prefix and no secret), so a retry never mints a second key.
enum NativeAPIKeyAdminError: LocalizedError, Equatable, Sendable {
    case invalidConfiguration
    case signedOut
    case malformedSession
    /// 401 `unauthorized`, still refused after one session refresh.
    case rejectedSession
    /// 405 `method_not_allowed`.
    case methodNotAllowed
    /// 400 `invalid_request`, or refused on the device before sending.
    case invalidRequest
    /// 404 `not_found`.
    case notFound
    /// 409 `key_limit`.
    case keyLimit(maxLiveKeys: Int)
    /// 409 `already_completed`: the operation committed earlier. No secret.
    case alreadyCompleted(keyId: String, prefix: String)
    /// 409 `operation_conflict`.
    case operationConflict
    /// 429 `rate_limited`, with the wait the app honours before trying again.
    case rateLimited(retryAfter: TimeInterval)
    /// 503 `unavailable` (the migration is not applied yet; fail closed).
    case unavailable
    /// 500 `server_error` on a read.
    case serverError
    /// No connection: the request never reached TradeReady.
    case offline
    /// A mutation's result is unknown; see the type comment.
    case unknownOutcome
    case invalidResponse
    /// The signed-in account changed while the request was open.
    case ownerChanged

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            "API access isn't set up in this build of TradeReady."
        case .signedOut:
            "Sign in to manage API keys."
        case .malformedSession, .rejectedSession:
            "Your session has expired. Sign in again to manage API keys."
        case .methodNotAllowed:
            "This version of TradeReady can't manage API keys. Update the app and try again."
        case .invalidRequest:
            "TradeReady couldn't accept that request. Check the key's name and access, then try again."
        case .notFound:
            "That key wasn't found. It may have been revoked, expired or replaced on another device."
        case let .keyLimit(maxLiveKeys):
            "You already have \(maxLiveKeys) active keys. Revoke one you no longer use before creating another."
        case let .alreadyCompleted(_, prefix):
            "TradeReady already made this key\(prefix.isEmpty ? "" : " (\(prefix)…)"), but it can't show it again. Revoke it and create a new one."
        case .operationConflict:
            "This request clashed with an earlier one, so nothing changed. Start again."
        case let .rateLimited(retryAfter):
            "Too many requests. Try again in about \(Int(retryAfter.rounded(.up))) seconds."
        case .unavailable:
            "API access isn't available right now. Try again later."
        case .serverError:
            "TradeReady had a problem loading your keys. Try again."
        case .offline:
            "Can't reach TradeReady. Check your connection and try again. Nothing was changed."
        case .unknownOutcome:
            "TradeReady couldn't confirm whether that worked. Tap Retry: it sends the same request, so it never makes a second key."
        case .invalidResponse:
            "TradeReady sent an unexpected response. Try again."
        case .ownerChanged:
            "Your account changed while this was loading, so nothing is shown for the wrong account."
        }
    }

    /// Whether a `create`/`rotate` that failed this way may still have
    /// committed (or may be retried as is), so the device keeps its
    /// operation id for an exact retry. Definitive answers clear it.
    var keepsPendingOperation: Bool {
        switch self {
        case .alreadyCompleted, .operationConflict, .invalidRequest, .keyLimit, .notFound,
             .methodNotAllowed, .invalidConfiguration:
            false
        case .signedOut, .malformedSession, .rejectedSession, .rateLimited, .unavailable,
             .serverError, .offline, .unknownOutcome, .invalidResponse, .ownerChanged:
            true
        }
    }
}

enum NativeAPIKeyAdminAction: String, Sendable {
    case list, create, rotate, revoke, activity

    /// `create`/`rotate` mint a key; `revoke` changes one. Their transport
    /// failures are unknown outcomes, never "offline".
    var isMutation: Bool { self == .create || self == .rotate || self == .revoke }
}

/// A freshly minted key: the summary, the raw key exactly once, and (for a
/// rotation) the key it replaces with its new end time.
struct NativeAPIKeyIssued: Equatable, Sendable {
    let key: NativeAPIKeySummary
    let secret: NativeAPIKeySecret
    let previous: NativeAPIKeySummary?
}

protocol NativeAPIKeyAdministrationHTTPDataLoading: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: NativeAPIKeyAdministrationHTTPDataLoading {}

/// Bounded auth refresh (portal-admin convention): called at most once per
/// request, only after a 401, and must return current session bytes.
typealias NativeAPIKeySessionRefresh = @Sendable () async -> Data?

/// The seam Settings › API access talks to. The app's implementation is the
/// store-bound `NativeAPIKeyStoreManager`; host tests fake it.
@MainActor
protocol NativeAPIKeyManaging {
    func list() async throws -> NativeAPIKeyList
    func create(_ request: NativeAPIKeyCreateRequest, operationId: String) async throws -> NativeAPIKeyIssued
    func rotate(keyId: String, grace: NativeAPIKeyGrace, operationId: String) async throws -> NativeAPIKeyIssued
    func revoke(keyId: String) async throws -> NativeAPIKeySummary
    func activity(keyId: String?) async throws -> [NativeAPIActivityEvent]
}

struct NativeAPIKeyAdministrationService: Sendable {
    static let endpointPath = "api/api-keys/manage"
    static let maxResponseBytes = 256 * 1024
    static let defaultMaxLiveKeys = 5

    /// No disk cache, no cookie store: nothing from these responses lands on
    /// disk (`.ephemeral` keeps its cache in memory, and the requests also
    /// ignore it).
    static let ephemeralLoader: URLSession = URLSession(configuration: .ephemeral)

    let endpoint: URL
    let loader: any NativeAPIKeyAdministrationHTTPDataLoading
    let refreshSession: NativeAPIKeySessionRefresh?
    let now: @Sendable () -> Date

    init(
        endpoint: URL,
        loader: any NativeAPIKeyAdministrationHTTPDataLoading = NativeAPIKeyAdministrationService.ephemeralLoader,
        refreshSession: NativeAPIKeySessionRefresh? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.endpoint = endpoint
        self.loader = loader
        self.refreshSession = refreshSession
        self.now = now
    }

    /// The same service with a refresh hook bound to the current session.
    func withRefresh(_ refresh: NativeAPIKeySessionRefresh?) -> Self {
        .init(endpoint: endpoint, loader: loader, refreshSession: refresh, now: now)
    }

    /// Environment boundary: the shared build configuration, so a
    /// non-production build cannot reach the production backend and an
    /// unconfigured build fails closed.
    static func resolvedEndpoint() throws -> URL {
        do {
            return try BuildEnvironment.endpoint(endpointPath, sendsUserData: true)
        } catch {
            throw NativeAPIKeyAdminError.invalidConfiguration
        }
    }

    // MARK: Actions

    func list(sessionBytes: Data) async throws -> NativeAPIKeyList {
        let data = try await send(action: .list, body: ListBody(), sessionBytes: sessionBytes)
        guard let decoded = try? JSONDecoder().decode(ListResponse.self, from: data), decoded.ok == true,
              decoded.secret == nil, let keys = decoded.keys
        else { throw NativeAPIKeyAdminError.invalidResponse }
        let maxLiveKeys = decoded.maxLiveKeys.flatMap { $0 > 0 ? $0 : nil } ?? Self.defaultMaxLiveKeys
        return NativeAPIKeyList(keys: try keys.map { try summary($0) }, maxLiveKeys: maxLiveKeys)
    }

    func create(_ request: NativeAPIKeyCreateRequest, operationId: String, sessionBytes: Data) async throws -> NativeAPIKeyIssued {
        guard Self.isValidOperationID(operationId),
              case let .success(name) = NativeAPIKeyName.normalize(request.name), name == request.name,
              !request.scopes.isEmpty, request.scopes == NativeAPIScope.canonical(request.scopes)
        else { throw NativeAPIKeyAdminError.invalidRequest }
        let body = CreateBody(
            operationId: operationId, name: request.name,
            scopes: request.scopes.map(\.rawValue), expiry: request.expiry.rawValue
        )
        let data = try await send(action: .create, body: body, sessionBytes: sessionBytes)
        return try issued(from: data, expectsPrevious: false)
    }

    func rotate(keyId: String, grace: NativeAPIKeyGrace, operationId: String, sessionBytes: Data) async throws -> NativeAPIKeyIssued {
        guard Self.isValidOperationID(operationId), Self.isValidKeyID(keyId) else {
            throw NativeAPIKeyAdminError.invalidRequest
        }
        let body = RotateBody(operationId: operationId, keyId: keyId, grace: grace.rawValue)
        let data = try await send(action: .rotate, body: body, sessionBytes: sessionBytes)
        return try issued(from: data, expectsPrevious: true)
    }

    func revoke(keyId: String, sessionBytes: Data) async throws -> NativeAPIKeySummary {
        guard Self.isValidKeyID(keyId) else { throw NativeAPIKeyAdminError.invalidRequest }
        let data = try await send(action: .revoke, body: RevokeBody(keyId: keyId), sessionBytes: sessionBytes)
        guard let decoded = try? JSONDecoder().decode(KeyResponse.self, from: data), decoded.ok == true,
              decoded.secret == nil, let key = decoded.key
        else { throw NativeAPIKeyAdminError.unknownOutcome }
        guard let parsed = try? summary(key), parsed.id.lowercased() == keyId.lowercased() else {
            throw NativeAPIKeyAdminError.unknownOutcome
        }
        return parsed
    }

    func activity(keyId: String?, sessionBytes: Data) async throws -> [NativeAPIActivityEvent] {
        if let keyId, !Self.isValidKeyID(keyId) { throw NativeAPIKeyAdminError.invalidRequest }
        let data = try await send(action: .activity, body: ActivityBody(keyId: keyId), sessionBytes: sessionBytes)
        guard let decoded = try? JSONDecoder().decode(ActivityResponse.self, from: data), decoded.ok == true,
              decoded.secret == nil, let events = decoded.events
        else { throw NativeAPIKeyAdminError.invalidResponse }
        return try events.enumerated().map { index, wire in
            NativeAPIActivityEvent(
                id: index, at: try Self.date(wire.at), keyId: wire.keyId ?? "", kind: NativeAPIActivityKind(raw: wire.event ?? ""),
                route: wire.route ?? "", status: wire.status ?? 0, ip: wire.ip
            )
        }
    }

    // MARK: Transport

    private func send<Body: Encodable>(action: NativeAPIKeyAdminAction, body: Body, sessionBytes: Data) async throws -> Data {
        guard Self.isAllowedEndpoint(endpoint) else { throw NativeAPIKeyAdminError.invalidConfiguration }
        let bearer = try Self.bearer(from: sessionBytes)
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        request.httpBody = try encoder.encode(body)
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        var (data, http) = try await perform(request, action: action)
        if http.statusCode == 401 {
            // Bounded: one refresh, then the same bytes (same operationId)
            // once more. The retried call never refreshes again.
            guard let fresh = await refreshed(from: sessionBytes),
                  let freshBearer = try? Self.bearer(from: fresh)
            else { throw NativeAPIKeyAdminError.rejectedSession }
            var retried = request
            retried.setValue("Bearer \(freshBearer)", forHTTPHeaderField: "Authorization")
            (data, http) = try await perform(retried, action: action)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw Self.error(
                status: http.statusCode, body: data, retryAfter: http.value(forHTTPHeaderField: "Retry-After"),
                action: action, now: now()
            )
        }
        guard data.count <= Self.maxResponseBytes else {
            throw action.isMutation ? NativeAPIKeyAdminError.unknownOutcome : NativeAPIKeyAdminError.invalidResponse
        }
        return data
    }

    private func perform(_ request: URLRequest, action: NativeAPIKeyAdminAction) async throws -> (Data, HTTPURLResponse) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await loader.data(for: request)
        } catch {
            throw Self.transportError(error, action: action)
        }
        guard let http = response as? HTTPURLResponse else {
            throw action.isMutation ? NativeAPIKeyAdminError.unknownOutcome : NativeAPIKeyAdminError.invalidResponse
        }
        return (data, http)
    }

    private func refreshed(from used: Data) async -> Data? {
        guard let refreshSession, let fresh = await refreshSession(), fresh != used,
              (try? Self.bearer(from: fresh)) != nil
        else { return nil }
        return fresh
    }

    /// A request that never left the device is "offline" for every action.
    /// Anything else after a mutation may have committed: unknown outcome.
    static func transportError(_ error: Error, action: NativeAPIKeyAdminAction) -> NativeAPIKeyAdminError {
        if let urlError = error as? URLError, notSentCodes.contains(urlError.code) { return .offline }
        return action.isMutation ? .unknownOutcome : .offline
    }

    private static let notSentCodes: Set<URLError.Code> = [
        .notConnectedToInternet, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
        .dataNotAllowed, .internationalRoamingOff, .callIsActive,
    ]

    /// Every §14.1 status and code, mapped once.
    static func error(
        status: Int,
        body: Data,
        retryAfter: String?,
        action: NativeAPIKeyAdminAction,
        now: Date
    ) -> NativeAPIKeyAdminError {
        let decoded = body.count <= maxResponseBytes ? try? JSONDecoder().decode(ErrorBody.self, from: body) : nil
        switch status {
        case 400: return .invalidRequest
        case 401, 403: return .rejectedSession
        case 404: return .notFound
        case 405: return .methodNotAllowed
        case 409:
            switch decoded?.error {
            case "key_limit":
                return .keyLimit(maxLiveKeys: decoded?.maxLiveKeys.flatMap { $0 > 0 ? $0 : nil } ?? defaultMaxLiveKeys)
            case "already_completed":
                let id = decoded?.key?.id ?? ""
                let prefix = decoded?.key?.prefix ?? ""
                return .alreadyCompleted(keyId: isValidKeyID(id) ? id : "", prefix: isDisplayPrefix(prefix) ? prefix : "")
            case "operation_conflict":
                return .operationConflict
            default:
                return action.isMutation ? .unknownOutcome : .invalidResponse
            }
        case 429:
            return .rateLimited(retryAfter: NativeAPIRetryAfter.seconds(from: retryAfter, now: now))
        case 503 where decoded?.error == "unavailable":
            return .unavailable
        case 500...599:
            return action.isMutation ? .unknownOutcome : (status == 503 ? .unavailable : .serverError)
        default:
            return action.isMutation ? .unknownOutcome : .invalidResponse
        }
    }

    // MARK: Decoding

    private func issued(from data: Data, expectsPrevious: Bool) throws -> NativeAPIKeyIssued {
        // The server committed (200). Anything unreadable from here on is an
        // unknown outcome, so the retry path (same operationId) recovers.
        guard let decoded = try? JSONDecoder().decode(KeyResponse.self, from: data), decoded.ok == true,
              let wireKey = decoded.key, let raw = decoded.secret,
              let secret = NativeAPIKeySecret(raw),
              let key = try? summary(wireKey),
              raw.hasPrefix(key.prefix), !key.prefix.isEmpty
        else { throw NativeAPIKeyAdminError.unknownOutcome }
        var previous: NativeAPIKeySummary?
        if expectsPrevious {
            guard let wirePrevious = decoded.previous, let parsed = try? summary(wirePrevious) else {
                throw NativeAPIKeyAdminError.unknownOutcome
            }
            previous = parsed
        }
        return NativeAPIKeyIssued(key: key, secret: secret, previous: previous)
    }

    private func summary(_ wire: KeySummaryWire) throws -> NativeAPIKeySummary {
        guard let id = wire.id, Self.isValidKeyID(id), let scopes = wire.scopes else {
            throw NativeAPIKeyAdminError.invalidResponse
        }
        let prefix = wire.prefix ?? ""
        guard prefix.isEmpty || Self.isDisplayPrefix(prefix) else { throw NativeAPIKeyAdminError.invalidResponse }
        let revokedAt = try Self.date(wire.revokedAt)
        let expiresAt = try Self.date(wire.expiresAt)
        let replacedBy = wire.replacedBy.flatMap { $0.isEmpty ? nil : $0 }
        let status = wire.status.flatMap(NativeAPIKeyStatus.init(rawValue:))
            ?? NativeAPIKeyStatus.derive(revokedAt: revokedAt, expiresAt: expiresAt, replacedBy: replacedBy, now: now())
        return NativeAPIKeySummary(
            id: id, name: wire.name ?? "", prefix: prefix, scopes: NativeAPIScope.parse(scopes),
            createdAt: try Self.date(wire.createdAt), expiresAt: expiresAt, revokedAt: revokedAt,
            lastUsedAt: try Self.date(wire.lastUsedAt), replacedBy: replacedBy, status: status
        )
    }

    /// ISO-8601 UTC, with or without fractional seconds. `nil` stays `nil`;
    /// a present but unreadable time fails closed (an unreadable `expiresAt`
    /// must never read as "never expires").
    static func date(_ value: String?) throws -> Date? {
        guard let value else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: value) { return date }
        throw NativeAPIKeyAdminError.invalidResponse
    }

    // MARK: Guards

    static func isAllowedEndpoint(_ url: URL) -> Bool {
        guard url.host != nil, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil,
              url.path.hasSuffix("/" + endpointPath)
        else { return false }
        if url.scheme?.lowercased() == "https" { return true }
        return url.scheme?.lowercased() == "http"
            && ["localhost", "127.0.0.1", "::1"].contains(url.host ?? "")
    }

    /// The device always sends a fresh UUID v4 (the Worker requires v4).
    static func isValidOperationID(_ value: String) -> Bool {
        guard value.count == 36, let uuid = UUID(uuidString: value) else { return false }
        let canonical = uuid.uuidString.lowercased()
        guard canonical == value.lowercased() else { return false }
        let versionIndex = canonical.index(canonical.startIndex, offsetBy: 14)
        let variantIndex = canonical.index(canonical.startIndex, offsetBy: 19)
        return canonical[versionIndex] == "4" && "89ab".contains(canonical[variantIndex])
    }

    /// A fresh operation id: lower-case UUID v4.
    static func newOperationID() -> String { UUID().uuidString.lowercased() }

    static func isValidKeyID(_ value: String) -> Bool {
        value.count == 36 && UUID(uuidString: value) != nil
    }

    /// `trk_` plus up to 8 base64url characters: display only.
    static func isDisplayPrefix(_ value: String) -> Bool {
        guard value.hasPrefix(NativeAPIKeySecret.keyPrefix), value.utf8.count <= 12 else { return false }
        return value.utf8.dropFirst(4).allSatisfy { byte in
            (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
                || (byte >= 0x30 && byte <= 0x39) || byte == 0x2D || byte == 0x5F
        }
    }

    private static func bearer(from sessionBytes: Data) throws -> String {
        guard let session = try? JSONDecoder().decode(StoredSession.self, from: sessionBytes),
              !session.accessToken.isEmpty,
              session.accessToken.count <= 4096,
              session.accessToken.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
        else { throw NativeAPIKeyAdminError.malformedSession }
        return session.accessToken
    }

    // MARK: Wire types

    private struct StoredSession: Decodable {
        let accessToken: String
        enum CodingKeys: String, CodingKey { case accessToken = "access_token" }
    }

    private struct ListBody: Encodable { let action = "list" }

    private struct CreateBody: Encodable {
        let action = "create"
        let operationId: String
        let name: String
        let scopes: [String]
        let expiry: String
    }

    private struct RotateBody: Encodable {
        let action = "rotate"
        let operationId: String
        let keyId: String
        let grace: String
    }

    private struct RevokeBody: Encodable {
        let action = "revoke"
        let keyId: String
    }

    private struct ActivityBody: Encodable {
        let action = "activity"
        let keyId: String?

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(action, forKey: .action)
            try container.encodeIfPresent(keyId, forKey: .keyId)
        }

        enum CodingKeys: String, CodingKey { case action, keyId }
    }

    private struct KeySummaryWire: Decodable {
        let id: String?
        let name: String?
        let prefix: String?
        let scopes: [String]?
        let createdAt: String?
        let expiresAt: String?
        let revokedAt: String?
        let lastUsedAt: String?
        let replacedBy: String?
        let status: String?
    }

    private struct ListResponse: Decodable {
        let ok: Bool?
        let keys: [KeySummaryWire]?
        let maxLiveKeys: Int?
        let secret: String?
    }

    private struct KeyResponse: Decodable {
        let ok: Bool?
        let key: KeySummaryWire?
        let secret: String?
        let previous: KeySummaryWire?
    }

    private struct ActivityWire: Decodable {
        let at: String?
        let keyId: String?
        let event: String?
        let route: String?
        let status: Int?
        let ip: String?
    }

    private struct ActivityResponse: Decodable {
        let ok: Bool?
        let events: [ActivityWire]?
        let secret: String?
    }

    private struct ErrorBody: Decodable {
        struct Key: Decodable {
            let id: String?
            let prefix: String?
        }
        let error: String?
        let maxLiveKeys: Int?
        let key: Key?
    }
}
