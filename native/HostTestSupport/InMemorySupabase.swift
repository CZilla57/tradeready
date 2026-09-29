import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Shared host-test support: the in-memory Supabase Data API. Moved unchanged
// out of `native/TwoDeviceConvergenceTests/main.swift` by 11.12 so the
// poor-network suite drives the same server model instead of a second fake.
// Compiled into `run-two-device-convergence-tests.sh` and
// `run-poor-network-tests.sh`.

// MARK: - In-memory Supabase Data API

/// A deterministic, in-process stand-in for the subset of the Supabase Data API
/// that the push transport and delta pull exercise. One instance backs *both*
/// client directions because ``NativeInitialSyncHTTPDataLoading`` and
/// ``NativeMutationPushHTTPLoading`` share the same `data(for:)` signature; the
/// server routes by HTTP method and path.
///
/// `updated_at` is stamped here — never trusted from the request body — from a
/// monotonic clock, exactly as the production database does
/// (`supabase/migrations/20260831_updated_at_server_authority.sql`). That makes
/// "last writer wins" a property of push *order*, not of any device clock, and
/// lets the tests reason about convergence without wall-clock flakiness.
final class InMemorySupabase: NativeInitialSyncHTTPDataLoading, NativeMutationPushHTTPLoading, @unchecked Sendable {
    struct Row {
        var id: String
        var userID: String
        var data: Canonical.JSONValue
        var deleted: Bool
        var updatedAt: String
    }

    /// table -> id -> row (the collection tables carrying an `{id,data,deleted}` blob).
    private var collections: [String: [String: Row]] = [:]
    /// user_id -> settings blob (one row per user).
    private var settings: [String: Canonical.JSONValue] = [:]
    /// user_id -> customer_key -> note.
    private var notes: [String: [String: String]] = [:]

    /// Monotonic server clock in whole seconds past a fixed base. Whole-second
    /// steps sit far inside the cursor's 5-minute overlap, so every pull re-reads
    /// rows it already merged — a free idempotency check on the merge path.
    private var clock = 0

    /// Tokens the server will reject with 401 (drives the auth-refresh path).
    var revokedTokens: Set<String> = []
    /// When set, the next matching request returns this status once, then clears.
    var injectStatusOnce: (method: String, table: String, status: Int)?
    /// Phase 12 (12.00b.2-L fix round 1): while set, every matching request
    /// returns this status (a push that keeps failing while pulls go on).
    var failRequests: (method: String, table: String, status: Int)?

    private let base = Date(timeIntervalSince1970: 1_757_000_000)

    /// Phase 12 (12.00b.2-L fix round 1): moves the server clock forward, so
    /// a later write lands more than the cursor's 5-minute overlap after an
    /// earlier one.
    func advanceClock(seconds: Int) {
        clock += seconds
    }

    private func nextStamp() -> String {
        defer { clock += 1 }
        return Self.formatter.string(from: base.addingTimeInterval(TimeInterval(clock)))
    }

    // The single entry point for both transports.
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let method = request.httpMethod ?? "GET"
        let table = request.url?.pathComponents.last ?? ""

        if let bearer = request.value(forHTTPHeaderField: "Authorization"),
           revokedTokens.contains(bearer.replacingOccurrences(of: "Bearer ", with: "")) {
            return respond(401, Data("{}".utf8), request)
        }
        if let fault = injectStatusOnce, fault.method == method, fault.table == table {
            injectStatusOnce = nil
            return respond(fault.status, Data("{}".utf8), request)
        }
        if let fault = failRequests, fault.method == method, fault.table == table {
            return respond(fault.status, Data("{}".utf8), request)
        }

        switch method {
        case "GET": return try handleGet(request, table: table)
        case "POST": return try handleUpsert(request, table: table)
        case "PATCH":
            if let body = request.httpBody,
               case let .object(fields)? = try? JSONDecoder().decode(Canonical.JSONValue.self, from: body),
               fields["data"] != nil {
                return try handleGuardedUpdate(request, table: table)
            }
            return try handleDelete(request, table: table)
        default: return respond(405, Data("{}".utf8), request)
        }
    }

    private func handleGet(_ request: URLRequest, table: String) throws -> (Data, URLResponse) {
        let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
        let items = components?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        let userID = value("user_id")?.replacingOccurrences(of: "eq.", with: "") ?? ""
        let limit = Int(value("limit") ?? "500") ?? 500
        let offset = Int(value("offset") ?? "0") ?? 0

        switch table {
        case "settings":
            let payload: [Canonical.JSONValue] = settings[userID].map {
                [.object(["user_id": .string(userID), "data": $0])]
            } ?? []
            return respond(200, try Self.encode(payload), request)
        case "customer_notes":
            // Phase 12 (12.00b.1): Discard's targeted fetch of one note.
            let only = value("customer_key")?.replacingOccurrences(of: "eq.", with: "")
            let rows = (notes[userID] ?? [:]).keys.sorted().filter { only == nil || $0 == only }.map { key in
                Canonical.JSONValue.object([
                    "user_id": .string(userID),
                    "customer_key": .string(key),
                    "note": .string(notes[userID]![key]!)
                ])
            }
            return respond(200, try Self.encode(rows), request)
        default:
            let since = value("updated_at")?.replacingOccurrences(of: "gte.", with: "")
            let sinceDate = since.flatMap(Self.parse)
            // Phase 12 (12.00b.1): Discard's targeted fetch of one record.
            let onlyID = value("id")?.replacingOccurrences(of: "eq.", with: "")
            var rows = (collections[table] ?? [:]).values.filter { row in
                guard row.userID == userID else { return false }
                if let onlyID, row.id != onlyID { return false }
                guard let sinceDate, let rowDate = Self.parse(row.updatedAt) else { return true }
                return rowDate >= sinceDate
            }
            // Match the server's `order=updated_at.asc,id.asc` so pagination is stable.
            rows.sort { $0.updatedAt == $1.updatedAt ? $0.id < $1.id : $0.updatedAt < $1.updatedAt }
            let page = Array(rows.dropFirst(offset).prefix(limit))
            let payload = page.map { row in
                Canonical.JSONValue.object([
                    "id": .string(row.id),
                    "user_id": .string(row.userID),
                    "data": row.data,
                    "deleted": .bool(row.deleted),
                    "updated_at": .string(row.updatedAt)
                ])
            }
            return respond(200, try Self.encode(payload), request)
        }
    }

    private func handleUpsert(_ request: URLRequest, table: String) throws -> (Data, URLResponse) {
        guard let body = request.httpBody,
              let json = try? JSONDecoder().decode(Canonical.JSONValue.self, from: body),
              case let .object(fields) = json,
              case let .string(userID)? = fields["user_id"]
        else { return respond(400, Data("{}".utf8), request) }

        switch table {
        case "settings":
            settings[userID] = fields["data"]
        case "customer_notes":
            guard case let .string(key)? = fields["customer_key"],
                  case let .string(note)? = fields["note"]
            else { return respond(400, Data("{}".utf8), request) }
            notes[userID, default: [:]][key] = note
        default:
            guard case let .string(id)? = fields["id"], let data = fields["data"] else {
                return respond(400, Data("{}".utf8), request)
            }
            collections[table, default: [:]][id] = Row(
                id: id, userID: userID, data: data, deleted: false, updatedAt: nextStamp()
            )
        }
        return respond(201, Data("{}".utf8), request)
    }

    /// Phase 12 (12.00b.2-L, P12-017): the push's guarded upsert, a PATCH of
    /// `data` filtered on `user_id`, `id` and `updated_at=lte.<timestamp>`
    /// with `select=id` and `return=representation`: the row is written (and
    /// stamped) only when it has not been written since that timestamp, and
    /// the reply lists the rows written, as PostgREST does.
    private func handleGuardedUpdate(_ request: URLRequest, table: String) throws -> (Data, URLResponse) {
        let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
        let items = components?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        guard let body = request.httpBody,
              case let .object(fields)? = try? JSONDecoder().decode(Canonical.JSONValue.self, from: body),
              let data = fields["data"],
              let since = value("updated_at").map({ $0.replacingOccurrences(of: "lte.", with: "") }),
              let sinceDate = Self.parse(since)
        else { return respond(400, Data("{}".utf8), request) }
        let userID = value("user_id")?.replacingOccurrences(of: "eq.", with: "") ?? ""
        let id = value("id")?.replacingOccurrences(of: "eq.", with: "") ?? ""
        guard var row = collections[table]?[id], row.userID == userID,
              let rowDate = Self.parse(row.updatedAt), rowDate <= sinceDate
        else { return respond(200, try Self.encode([]), request) }
        row.data = data
        row.updatedAt = nextStamp()
        collections[table]![id] = row
        return respond(200, try Self.encode([.object(["id": .string(id)])]), request)
    }

    private func handleDelete(_ request: URLRequest, table: String) throws -> (Data, URLResponse) {
        let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
        let items = components?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        let userID = value("user_id")?.replacingOccurrences(of: "eq.", with: "") ?? ""

        switch table {
        case "settings":
            settings[userID] = nil
        case "customer_notes":
            if let key = value("customer_key")?.replacingOccurrences(of: "eq.", with: "") {
                notes[userID]?[key] = nil
            }
        default:
            let id = value("id")?.replacingOccurrences(of: "eq.", with: "") ?? ""
            if var row = collections[table]?[id], row.userID == userID {
                row.deleted = true
                row.updatedAt = nextStamp()
                collections[table]![id] = row
            }
        }
        return respond(204, Data("{}".utf8), request)
    }

    // Test-only inspection: the non-deleted rows the server holds for a table.
    func liveRows(table: String, userID: String) -> [Row] {
        (collections[table] ?? [:]).values.filter { $0.userID == userID && !$0.deleted }
    }

    // Test-only inspection: how many non-deleted rows the server holds for a table.
    func liveRowCount(table: String, userID: String) -> Int {
        (collections[table] ?? [:]).values.filter { $0.userID == userID && !$0.deleted }.count
    }

    /// Test-only inspection used to prove that an older React Native client's
    /// `updated_at` value was ignored in favor of the database clock.
    func storedRow(table: String, id: String, userID: String) -> Row? {
        guard let row = collections[table]?[id], row.userID == userID else { return nil }
        return row
    }

    private func respond(_ status: Int, _ data: Data, _ request: URLRequest) -> (Data, URLResponse) {
        let http = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        return (data, http)
    }

    private static func encode(_ rows: [Canonical.JSONValue]) throws -> Data {
        try JSONEncoder().encode(rows)
    }

    static func parse(_ value: String) -> Date? {
        withFraction.date(from: value) ?? withoutFraction.date(from: value)
    }

    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let withoutFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
