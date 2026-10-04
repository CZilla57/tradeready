import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Authenticated owner transport for `POST /api/calendar/busy` (Roadmap
/// Phase 26, spec `docs/superpowers/specs/2026-10-03-calendar-sync-design.md`
/// §3.1, §4.3). A copy of the booking-admin transport
/// (`NativeBookingAdministrationService`): the shared endpoint resolution
/// (`BuildEnvironment.endpoint("api/calendar/busy", sendsUserData: true)`, so
/// non-production builds never write to production and unconfigured builds
/// fail closed), the current Supabase bearer, and at most one retry after a
/// 401 answered by a fresh session.
///
/// Typed outcomes: `ok`, `sourceMismatch` (another device is the source),
/// `unavailable` (503: the table is not deployed yet), `invalid` (400),
/// `offline` (transport errors, 429 and other 5xx: try again later) and
/// `unauthorized`.

struct NativeCalendarSyncCredentials: Sendable {
    let sessionBytes: Data
    /// Fresh session bytes after a 401, or nil (no retry then).
    let refresh: @Sendable () async -> Data?
}

enum NativeCalendarSyncOutcome<Value: Equatable & Sendable>: Equatable, Sendable {
    case ok(Value)
    case sourceMismatch(receivedAt: Date?)
    case unavailable
    case invalid
    case offline
    case unauthorized
}

struct NativeCalendarPutResult: Equatable, Sendable {
    let receivedAt: Date?
    /// No row existed before this put (§4.4: tells the source device that
    /// checks were turned off on another device since its last put).
    let created: Bool
}

@MainActor
protocol NativeCalendarSyncTransporting: AnyObject {
    func put(sourceID: String, snapshotJSON: String?, takeOver: Bool,
             credentials: NativeCalendarSyncCredentials) async -> NativeCalendarSyncOutcome<NativeCalendarPutResult>
    func status(sourceID: String?, credentials: NativeCalendarSyncCredentials) async -> NativeCalendarSyncOutcome<NativeCalendarBusy.ServerStatus>
    func disable(credentials: NativeCalendarSyncCredentials) async -> NativeCalendarSyncOutcome<Bool>
}

@MainActor
final class NativeCalendarSyncTransport: NativeCalendarSyncTransporting {
    static let maxResponseBytes = 16 * 1024

    let endpoint: URL
    let loader: any NativeBookingAdministrationHTTPDataLoading

    init(endpoint: URL, loader: any NativeBookingAdministrationHTTPDataLoading = URLSession.shared) {
        self.endpoint = endpoint
        self.loader = loader
    }

    /// The live transport, or nil when the build has no usable backend.
    static func live() -> NativeCalendarSyncTransport? {
        guard let endpoint = try? BuildEnvironment.endpoint("api/calendar/busy", sendsUserData: true),
              endpoint.host?.hasSuffix(".invalid") == false,
              NativeBookingAdministrationService.isAllowedEndpoint(endpoint)
        else { return nil }
        return NativeCalendarSyncTransport(endpoint: endpoint)
    }

    // MARK: Actions

    func put(sourceID: String, snapshotJSON: String?, takeOver: Bool,
             credentials: NativeCalendarSyncCredentials) async -> NativeCalendarSyncOutcome<NativeCalendarPutResult> {
        guard Self.isSourceID(sourceID) else { return .invalid }
        // The snapshot is spliced in verbatim: it is the exact wire JSON the
        // domain encoded (fixed-alphabet values), so nothing is re-encoded.
        var body = "{\"action\":\"put\",\"sourceId\":\"\(sourceID)\",\"snapshot\":\(snapshotJSON ?? "null")"
        if takeOver { body += ",\"takeOver\":true" }
        body += "}"
        guard body.utf8.count <= NativeCalendarBusy.maxBodyBytes else { return .invalid }
        let (status, data) = await send(Data(body.utf8), credentials: credentials)
        return Self.decode(status: status, data: data) { object in
            guard object["ok"] as? Bool == true else { return nil }
            return NativeCalendarPutResult(receivedAt: NativeCalendarBusy.parseAnyDate(object["receivedAt"] as? String),
                                           created: object["created"] as? Bool ?? false)
        }
    }

    func status(sourceID: String?, credentials: NativeCalendarSyncCredentials) async -> NativeCalendarSyncOutcome<NativeCalendarBusy.ServerStatus> {
        let source = sourceID.flatMap { Self.isSourceID($0) ? $0 : nil }
        let body = source.map { "{\"action\":\"status\",\"sourceId\":\"\($0)\"}" } ?? "{\"action\":\"status\"}"
        let (status, data) = await send(Data(body.utf8), credentials: credentials)
        return Self.decode(status: status, data: data) { object in
            guard object["ok"] as? Bool == true, let enabled = object["enabled"] as? Bool else { return nil }
            return NativeCalendarBusy.ServerStatus(
                enabled: enabled,
                thisDevice: object["thisDevice"] as? Bool ?? false,
                shared: object["shared"] as? Bool ?? false,
                fresh: object["fresh"] as? Bool ?? false,
                computedAt: NativeCalendarBusy.parseAnyDate(object["computedAt"] as? String),
                receivedAt: NativeCalendarBusy.parseAnyDate(object["receivedAt"] as? String))
        }
    }

    func disable(credentials: NativeCalendarSyncCredentials) async -> NativeCalendarSyncOutcome<Bool> {
        let (status, data) = await send(Data("{\"action\":\"disable\"}".utf8), credentials: credentials)
        return Self.decode(status: status, data: data) { object in object["ok"] as? Bool == true ? true : nil }
    }

    // MARK: Wire

    /// (status, body); status 0 means the request never got an answer.
    private func send(_ body: Data, credentials: NativeCalendarSyncCredentials) async -> (Int, Data) {
        guard let bearer = Self.bearer(credentials.sessionBytes) else { return (401, Data()) }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20
        var answer = await perform(request)
        if answer.0 == 401, let fresh = await credentials.refresh(), fresh != credentials.sessionBytes,
           let freshBearer = Self.bearer(fresh) {
            // The first attempt died at authentication, before anything could
            // commit, so one retry with the fresh bearer is safe. Bounded.
            var retried = request
            retried.setValue("Bearer \(freshBearer)", forHTTPHeaderField: "Authorization")
            answer = await perform(retried)
        }
        return answer
    }

    private func perform(_ request: URLRequest) async -> (Int, Data) {
        do {
            let (data, response) = try await loader.data(for: request)
            guard let http = response as? HTTPURLResponse else { return (0, Data()) }
            return (http.statusCode, data)
        } catch {
            return (0, Data())
        }
    }

    static func decode<Value: Equatable & Sendable>(status: Int, data: Data,
                              _ parse: ([String: Any]) -> Value?) -> NativeCalendarSyncOutcome<Value> {
        let object = data.count <= maxResponseBytes
            ? (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            : nil
        switch status {
        case 200..<300:
            guard let object, let value = parse(object) else { return .offline }
            return .ok(value)
        case 400: return .invalid
        case 401, 403: return .unauthorized
        case 409:
            guard object?["error"] as? String == "source_mismatch" else { return .invalid }
            return .sourceMismatch(receivedAt: NativeCalendarBusy.parseAnyDate(object?["receivedAt"] as? String))
        case 503 where object?["error"] as? String == "unavailable":
            return .unavailable
        default:
            return .offline
        }
    }

    private struct StoredSession: Decodable {
        let accessToken: String
        enum CodingKeys: String, CodingKey { case accessToken = "access_token" }
    }

    static func bearer(_ sessionBytes: Data) -> String? {
        guard let session = try? JSONDecoder().decode(StoredSession.self, from: sessionBytes),
              !session.accessToken.isEmpty, session.accessToken.count <= 4096,
              session.accessToken.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
        else { return nil }
        return session.accessToken
    }

    /// A lowercase UUID, as the server requires.
    static func isSourceID(_ value: String) -> Bool {
        guard value.count == 36, let uuid = UUID(uuidString: value) else { return false }
        return uuid.uuidString.lowercased() == value
    }
}
