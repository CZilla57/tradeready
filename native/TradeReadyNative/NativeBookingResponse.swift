import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Authenticated owner transport for `POST /api/booking/respond`
/// (Phase 8 task 8.07; requirements B1, B4).
///
/// Frozen contract: docs/native-phase-8-contract-decisions.md §2.2 (G2) and
/// §7. Request: `{requestId, action: resolve_reschedule|decline,
/// scheduleProof?: {jobId, updatedAt, date, start}}`.
/// Response: `{ok:true, status}`. A 409 carries `{error: invalid_state |
/// schedule_changed, status}` with the current authoritative status echoed.
///
/// Outcome classification:
/// - Definitive refusal (`notFound`, `invalidState`, `scheduleChanged`,
///   `invalidRequest`): the captured view is stale or the transition is
///   illegal. Refresh authoritative state instead of forcing it. The single
///   exception is the documented success-equivalent: a 409 `invalid_state`
///   whose echoed `status` equals the intended target means a retried POST
///   found an already-committed transition — the service returns success, no
///   second write and (for decline) no duplicate customer email occur
///   because the server performs no work on 409.
/// - Transient (`rateLimited`, `unavailable`): safe to retry later; the
///   server answers an already-committed retry with 409 `invalid_state`,
///   which the caller maps through the success-equivalent rule above.
/// - Unknown mutation outcome (`unknownOutcome`): a timeout, transport error,
///   or 5xx after the POST — the transition may have committed. Recover with
///   an authoritative status read, never an automatic resend: re-sending a
///   decline blind could duplicate the customer email if the first POST is
///   still in flight. This service never resends automatically.
enum NativeBookingResponseError: LocalizedError, Equatable {
    case invalidConfiguration
    case malformedSession
    case rejectedSession
    case invalidRequest
    case notFound
    case invalidState(currentStatus: String)
    case scheduleChanged(currentStatus: String)
    case rateLimited
    case invalidResponse
    case unavailable
    case unknownOutcome

    static func == (lhs: NativeBookingResponseError, rhs: NativeBookingResponseError) -> Bool {
        switch (lhs, rhs) {
        case (.invalidConfiguration, .invalidConfiguration),
             (.malformedSession, .malformedSession),
             (.rejectedSession, .rejectedSession),
             (.invalidRequest, .invalidRequest),
             (.notFound, .notFound),
             (.rateLimited, .rateLimited),
             (.invalidResponse, .invalidResponse),
             (.unavailable, .unavailable),
             (.unknownOutcome, .unknownOutcome):
            return true
        case let (.invalidState(ls), .invalidState(rs)):
            return ls == rs
        case let (.scheduleChanged(ls), .scheduleChanged(rs)):
            return ls == rs
        default:
            return false
        }
    }

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            "Booking responses are not configured for this build."
        case .malformedSession, .rejectedSession:
            "Your session has expired. Sign in again before responding to bookings."
        case .invalidRequest:
            "This booking response was invalid and was not sent."
        case .notFound:
            "The booking request was not found. It may have been removed on another device."
        case .invalidState:
            "The booking changed while you were reviewing it. Refresh its status before responding."
        case .scheduleChanged:
            "The job schedule changed after the replacement was prepared. Review the latest schedule before resolving."
        case .rateLimited:
            "Too many booking responses. Wait a moment and try again."
        case .invalidResponse:
            "The booking service returned an unexpected response."
        case .unavailable:
            "The booking service is unavailable. Check your connection and try again."
        case .unknownOutcome:
            "The response may or may not have reached the server. Check the booking status before trying again."
        }
    }
}

enum NativeBookingResponseAction: String, Sendable {
    case resolveReschedule = "resolve_reschedule"
    case decline

    var targetStatus: String {
        switch self {
        case .resolveReschedule: return "confirmed"
        case .decline: return "declined"
        }
    }
}

/// Replacement-schedule publication proof (§7): identifies the exact intended
/// job mutation (record id + write stamp + schedule). A superseding schedule
/// edit after proof generation refuses with `schedule_changed` instead of
/// resolving against the wrong slot. Calls without proof are the accepted
/// legacy path (limitation L2) — native always sends proof for resolves.
struct NativeScheduleProof: Codable, Equatable, Sendable {
    let jobId: String
    let updatedAt: String
    let date: String
    let start: String
}

struct NativeBookingResponseResult: Equatable, Sendable {
    let status: String
    /// True when the server answered 409 `invalid_state` whose echoed status
    /// already equaled the intended target (retry-after-commit, §2.2).
    /// No new write occurred; for decline, no second customer email.
    let alreadyApplied: Bool
}

protocol NativeBookingResponseHTTPDataLoading: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: NativeBookingResponseHTTPDataLoading {}

/// Bounded auth-refresh hook (NativeSyncCoordinator convention): invoked at
/// most once per call, only after a 401, and must return current session
/// bytes. A nil hook — or a hook returning nil/stale bytes — surfaces
/// `.rejectedSession` with no resend.
typealias NativeBookingResponseSessionRefresh = @Sendable () async -> Data?

/// Authenticated client for the booking-respond endpoint. The device sends no
/// owner identifier; the backend verifies the current Supabase bearer and
/// treats a foreign request id as unknown (404, no oracle).
struct NativeBookingResponseService: Sendable {
    static let maxResponseBytes = 64 * 1024

    private struct StoredSession: Decodable {
        let accessToken: String
        enum CodingKeys: String, CodingKey { case accessToken = "access_token" }
    }

    private struct RequestBody: Encodable {
        let requestId: String
        let action: String
        let scheduleProof: NativeScheduleProof?

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(requestId, forKey: .requestId)
            try container.encode(action, forKey: .action)
            try container.encodeIfPresent(scheduleProof, forKey: .scheduleProof)
        }

        private enum CodingKeys: String, CodingKey {
            case requestId, action, scheduleProof
        }
    }

    private struct ResponseBody: Decodable {
        let ok: Bool?
        let status: String?
    }

    private struct ErrorBody: Decodable {
        let error: String?
        let status: String?
    }

    let endpoint: URL
    let loader: any NativeBookingResponseHTTPDataLoading
    let refreshSession: NativeBookingResponseSessionRefresh?

    init(
        endpoint: URL,
        loader: any NativeBookingResponseHTTPDataLoading = URLSession.shared,
        refreshSession: NativeBookingResponseSessionRefresh? = nil
    ) {
        self.endpoint = endpoint
        self.loader = loader
        self.refreshSession = refreshSession
    }

    /// Environment boundary: resolves the respond endpoint through the shared
    /// build configuration so non-production builds cannot write to the
    /// production backend and unconfigured builds fail closed.
    static func resolvedEndpoint() throws -> URL {
        do {
            return try BuildEnvironment.endpoint("api/booking/respond", sendsUserData: true)
        } catch {
            throw NativeBookingResponseError.invalidConfiguration
        }
    }

    func resolveReschedule(
        requestId: String,
        proof: NativeScheduleProof,
        sessionBytes: Data
    ) async throws -> NativeBookingResponseResult {
        guard Self.isValidProof(proof) else { throw NativeBookingResponseError.invalidRequest }
        return try await respond(requestId: requestId, action: .resolveReschedule, proof: proof, sessionBytes: sessionBytes)
    }

    func decline(requestId: String, sessionBytes: Data) async throws -> NativeBookingResponseResult {
        try await respond(requestId: requestId, action: .decline, proof: nil, sessionBytes: sessionBytes)
    }

    private func respond(
        requestId: String,
        action: NativeBookingResponseAction,
        proof: NativeScheduleProof?,
        sessionBytes: Data
    ) async throws -> NativeBookingResponseResult {
        guard Self.isAllowedEndpoint(endpoint) else { throw NativeBookingResponseError.invalidConfiguration }
        guard Self.isValidID(requestId) else { throw NativeBookingResponseError.invalidRequest }
        if action == .decline, proof != nil { throw NativeBookingResponseError.invalidRequest }
        let bearer = try Self.bearer(from: sessionBytes)

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(RequestBody(
            requestId: requestId,
            action: action.rawValue,
            scheduleProof: proof
        ))
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let http: HTTPURLResponse
        do {
            (data, http) = try await Self.perform(request, via: loader)
        } catch {
            // Unknown outcome: the transition may have committed (and, for
            // decline, the customer email may have sent). Never resend
            // automatically; recover via authoritative status.
            throw NativeBookingResponseError.unknownOutcome
        }
        if http.statusCode == 401 {
            guard let fresh = await Self.refreshed(refreshSession, from: sessionBytes),
                  let freshBearer = try? Self.bearer(from: fresh)
            else { throw NativeBookingResponseError.rejectedSession }
            // The first attempt died at authentication, before any booking
            // state could commit, so one retry with the fresh bearer cannot
            // duplicate a transition or email.
            var retried = request
            retried.setValue("Bearer \(freshBearer)", forHTTPHeaderField: "Authorization")
            let retryData: Data
            let retryHTTP: HTTPURLResponse
            do {
                (retryData, retryHTTP) = try await Self.perform(retried, via: loader)
            } catch {
                throw NativeBookingResponseError.unknownOutcome
            }
            return try Self.decode(data: retryData, statusCode: retryHTTP.statusCode, action: action)
        }
        return try Self.decode(data: data, statusCode: http.statusCode, action: action)
    }

    private static func decode(
        data: Data,
        statusCode: Int,
        action: NativeBookingResponseAction
    ) throws -> NativeBookingResponseResult {
        switch statusCode {
        case 200..<300: break
        case 400: throw NativeBookingResponseError.invalidRequest
        case 401, 403: throw NativeBookingResponseError.rejectedSession
        case 404: throw NativeBookingResponseError.notFound
        case 409:
            guard data.count <= maxResponseBytes,
                  let decoded = try? JSONDecoder().decode(ErrorBody.self, from: data)
            else { throw NativeBookingResponseError.invalidResponse }
            switch decoded.error {
            case "invalid_state":
                let current = Self.sanitizedStatus(decoded.status)
                // Documented success-equivalent (§2.2): the retry found an
                // already-committed transition to the intended target.
                if current == action.targetStatus {
                    return NativeBookingResponseResult(status: current, alreadyApplied: true)
                }
                throw NativeBookingResponseError.invalidState(currentStatus: current)
            case "schedule_changed":
                throw NativeBookingResponseError.scheduleChanged(currentStatus: Self.sanitizedStatus(decoded.status))
            default: throw NativeBookingResponseError.invalidResponse
            }
        case 429: throw NativeBookingResponseError.rateLimited
        case 500...599: throw NativeBookingResponseError.unknownOutcome
        default: throw NativeBookingResponseError.unavailable
        }
        guard data.count <= maxResponseBytes,
              let decoded = try? JSONDecoder().decode(ResponseBody.self, from: data),
              decoded.ok == true,
              let status = decoded.status, !status.isEmpty, status.count <= 100
        else { throw NativeBookingResponseError.invalidResponse }
        return NativeBookingResponseResult(status: status, alreadyApplied: false)
    }

    // MARK: - Shared guards

    private static func perform(
        _ request: URLRequest,
        via loader: any NativeBookingResponseHTTPDataLoading
    ) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await loader.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw NativeBookingResponseError.invalidResponse }
        return (data, http)
    }

    private static func bearer(from sessionBytes: Data) throws -> String {
        guard let session = try? JSONDecoder().decode(StoredSession.self, from: sessionBytes),
              !session.accessToken.isEmpty,
              session.accessToken.count <= 4096,
              session.accessToken.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
        else { throw NativeBookingResponseError.malformedSession }
        return session.accessToken
    }

    private static func refreshed(
        _ refresh: NativeBookingResponseSessionRefresh?,
        from used: Data
    ) async -> Data? {
        guard let refresh else { return nil }
        guard let fresh = await refresh(), fresh != used,
              (try? bearer(from: fresh)) != nil
        else { return nil }
        return fresh
    }

    private static func sanitizedStatus(_ value: String?) -> String {
        guard let value, !value.isEmpty, value.count <= 100,
              value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
        else { return "unknown" }
        return value
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

    static func isValidProof(_ proof: NativeScheduleProof) -> Bool {
        isValidID(proof.jobId)
            && !proof.updatedAt.isEmpty && proof.updatedAt.count <= 100
            && !proof.date.isEmpty && proof.date.count <= 20
            && !proof.start.isEmpty && proof.start.count <= 20
    }
}
