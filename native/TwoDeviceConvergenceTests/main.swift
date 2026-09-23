import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

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

    private let base = Date(timeIntervalSince1970: 1_757_000_000)

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

        switch method {
        case "GET": return try handleGet(request, table: table)
        case "POST": return try handleUpsert(request, table: table)
        case "PATCH": return try handleDelete(request, table: table)
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
            let rows = (notes[userID] ?? [:]).keys.sorted().map { key in
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
            var rows = (collections[table] ?? [:]).values.filter { row in
                guard row.userID == userID else { return false }
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

// MARK: - React Native reference client

/// A narrow model of the shipped React Native collection sync contract in
/// `utils/sync.ts`: collection upserts include a client `updated_at`, deletes
/// are owner-filtered soft updates, pulls use the database cursor with a
/// five-minute overlap, and ordinary records are remote-wins. It deliberately
/// talks to the same in-memory Data API as the native services so this suite
/// proves wire compatibility rather than only Swift-to-Swift behavior.
final class ReactNativeReferenceClient {
    private struct RemoteRow: Decodable {
        let id: String
        let data: Canonical.JSONValue
        let deleted: Bool
        let updatedAt: String

        enum CodingKeys: String, CodingKey {
            case id, data, deleted
            case updatedAt = "updated_at"
        }
    }

    let subject: String
    private(set) var collections: [String: [String: Canonical.JSONValue]] = [:]
    private(set) var cursors: [String: String] = [:]
    private let baseURL: URL
    private let loader: any NativeMutationPushHTTPLoading

    init(subject: String, baseURL: URL, loader: any NativeMutationPushHTTPLoading) {
        self.subject = subject
        self.baseURL = baseURL
        self.loader = loader
    }

    func upsert(
        table: String,
        id: String,
        data: Canonical.JSONValue,
        clientUpdatedAt: String
    ) async throws {
        var request = URLRequest(url: baseURL.appending(path: "rest/v1/\(table)"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer react-native-token", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(Canonical.JSONValue.object([
            "id": .string(id),
            "user_id": .string(subject),
            "data": data,
            "updated_at": .string(clientUpdatedAt),
            "deleted": .bool(false)
        ]))
        let (_, response) = try await loader.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 201 else {
            throw URLError(.badServerResponse)
        }
        collections[table, default: [:]][id] = data
    }

    func delete(table: String, id: String, clientUpdatedAt: String) async throws {
        var components = URLComponents(
            url: baseURL.appending(path: "rest/v1/\(table)"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "id", value: "eq.\(id)"),
            URLQueryItem(name: "user_id", value: "eq.\(subject)")
        ]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer react-native-token", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(Canonical.JSONValue.object([
            "deleted": .bool(true),
            "updated_at": .string(clientUpdatedAt)
        ]))
        let (_, response) = try await loader.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 204 else {
            throw URLError(.badServerResponse)
        }
        collections[table]?[id] = nil
    }

    func pull(table: String) async throws {
        let start = Self.pullStart(cursors[table])
        var components = URLComponents(
            url: baseURL.appending(path: "rest/v1/\(table)"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "select", value: "id,data,deleted,updated_at"),
            URLQueryItem(name: "user_id", value: "eq.\(subject)"),
            URLQueryItem(name: "updated_at", value: "gte.\(start)"),
            URLQueryItem(name: "order", value: "updated_at.asc,id.asc"),
            URLQueryItem(name: "limit", value: "500"),
            URLQueryItem(name: "offset", value: "0")
        ]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.setValue("Bearer react-native-token", forHTTPHeaderField: "Authorization")
        let (data, response) = try await loader.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        for row in try JSONDecoder().decode([RemoteRow].self, from: data) {
            if row.deleted {
                collections[table]?[row.id] = nil
            } else {
                // Jobs and other ordinary collection records are whole-blob,
                // remote-wins in utils/syncMerge.ts. Invoice and booking
                // exceptions remain covered by the shared native merge tests.
                collections[table, default: [:]][row.id] = row.data
            }
            if let current = cursors[table], current >= row.updatedAt { continue }
            cursors[table] = row.updatedAt
        }
    }

    func title(forJob id: String) -> String? {
        guard case let .object(fields)? = collections["jobs"]?[id],
              case let .string(title)? = fields["title"]
        else { return nil }
        return title
    }

    private static func pullStart(_ watermark: String?) -> String {
        guard let watermark, let date = InMemorySupabase.parse(watermark) else {
            return "1970-01-01T00:00:00.000Z"
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date.addingTimeInterval(-5 * 60))
    }
}

// MARK: - A simulated device

/// One client. It owns exactly what a real install owns: an in-memory snapshot,
/// a durable file-backed mutation queue, and a durable file-backed delta cursor.
/// Two devices in a test share the same `subject` (one account, two phones) and
/// the same ``InMemorySupabase`` instance.
final class Device {
    let subject: String
    var snapshot: Canonical.Snapshot
    let queue: Canonical.NativeMutationQueue
    let cursorStore: Canonical.NativeSyncCursorStore
    private let dir: URL

    init(subject: String, label: String) throws {
        self.subject = subject
        self.snapshot = Canonical.Snapshot(payload: .init())
        self.dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tradeready-converge-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.queue = Canonical.NativeMutationQueue(fileURL: dir.appendingPathComponent("queue.json"))
        self.cursorStore = Canonical.NativeSyncCursorStore(fileURL: dir.appendingPathComponent("cursor.json"))
    }

    var queueFileURL: URL { dir.appendingPathComponent("queue.json") }

    func cleanup() { try? FileManager.default.removeItem(at: dir) }
}

// MARK: - Tests

@main
struct TwoDeviceConvergenceTests {
    static let session = Data(#"{"access_token":"private-access-token"}"#.utf8)
    static let subject = "11111111-2222-3333-4444-555555555555"
    static let supabaseURL = URL(string: "https://project.supabase.co")!

    static func main() async throws {
        var failures = 0
        func expect(_ condition: Bool, _ label: String) {
            if !condition { failures += 1; print("FAIL: \(label)") }
        }

        let fixtureRoot = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CANONICAL_FIXTURES_PATH"]!)
        let rich = try JSONDecoder().decode(
            [String: Canonical.JSONValue].self,
            from: Data(contentsOf: fixtureRoot.appendingPathComponent("canonical-rich.json"))
        )

        // --- Blob builders (produce records whose `id` matches the queued id) --
        func jobBlob(id: String, title: String) -> Canonical.JSONValue {
            guard case var .object(fields) = rich["job"]! else { fatalError("job fixture") }
            fields["id"] = .string(id)
            fields["title"] = .string(title)
            return .object(fields)
        }
        func customerBlob(id: String, name: String) -> Canonical.JSONValue {
            guard case var .object(fields) = rich["customer"]! else { fatalError("customer fixture") }
            fields["id"] = .string(id)
            fields["name"] = .string(name)
            return .object(fields)
        }
        func paymentBlob(id: String, amount: Decimal, date: String) -> Canonical.JSONValue {
            .object([
                "id": .string(id),
                "amount": .number(amount),
                "date": .string(date),
                "method": .string("card")
            ])
        }
        func invoiceBlob(id: String, amount: Decimal, payments: [Canonical.JSONValue]) -> Canonical.JSONValue {
            guard case var .object(fields) = rich["invoice"]! else { fatalError("invoice fixture") }
            fields["id"] = .string(id)
            fields["amount"] = .number(amount)
            fields["paid"] = .bool(false)
            fields["payments"] = .array(payments)
            return .object(fields)
        }
        func decoded<T: Decodable>(_ type: T.Type, _ value: Canonical.JSONValue) throws -> T {
            try JSONDecoder().decode(type, from: JSONEncoder().encode(value))
        }

        // --- Sync primitive: push the queue, then pull the delta (RN's order) --
        // Mirrors `syncIfOnline` (utils/sync.ts) and the coordinator's `runOnce`:
        // local writes reach the server before the pull merges the server state
        // back into the local snapshot.
        let push = NativeSupabaseMutationPushService(
            supabaseURL: supabaseURL, publishableKey: "publishable-key",
            allowsWrites: true, loader: server
        )
        let delta = NativeSupabaseInitialSyncService(
            supabaseURL: supabaseURL, publishableKey: "publishable-key", loader: server
        )
        func sync(_ device: Device) async throws {
            let items = device.queue.load()
            if !items.isEmpty {
                let outcome = try await push.push(
                    sessionBytes: session, expectedUserSubject: device.subject, items: items
                )
                try device.queue.save(outcome.remaining)
            }
            let pull = try await delta.pullDelta(
                sessionBytes: session, expectedUserSubject: device.subject,
                localSnapshot: device.snapshot, cursor: device.cursorStore.load()
            )
            device.snapshot = pull.snapshot
            try device.cursorStore.save(pull.cursor)
        }

        // Local edit helpers that mirror AppStore: mutate the snapshot, then
        // enqueue the matching mutation item.
        func upsertJob(_ device: Device, id: String, title: String) throws {
            var jobs = device.snapshot.payload.jobs ?? []
            let record = try decoded(Canonical.Job.self, jobBlob(id: id, title: title))
            if let idx = jobs.firstIndex(where: { $0.id == id }) { jobs[idx] = record } else { jobs.append(record) }
            device.snapshot.payload.jobs = jobs
            try device.queue.enqueue(table: "jobs", op: .upsert, recordId: id, payload: jobBlob(id: id, title: title))
        }
        func deleteJob(_ device: Device, id: String) throws {
            device.snapshot.payload.jobs?.removeAll { $0.id == id }
            try device.queue.enqueue(table: "jobs", op: .delete, recordId: id, payload: nil)
        }

        let a = try Device(subject: subject, label: "A")
        let b = try Device(subject: subject, label: "B")
        defer { a.cleanup(); b.cleanup() }

        // === Scenario 1: a new record propagates both directions =============
        try upsertJob(a, id: "jA", title: "A's job")
        try await sync(a)                        // A pushes jA, pulls it back
        try upsertJob(b, id: "jB", title: "B's job")
        try await sync(b)                        // B pushes jB, pulls jA + jB
        try await sync(a)                        // A pulls jB

        func jobTitles(_ device: Device) -> [String: String] {
            Dictionary(uniqueKeysWithValues: (device.snapshot.payload.jobs ?? []).map { ($0.id, $0.title) })
        }
        expect(jobTitles(a) == ["jA": "A's job", "jB": "B's job"], "A converges to both devices' jobs")
        expect(jobTitles(b) == ["jA": "A's job", "jB": "B's job"], "B converges to both devices' jobs")
        expect((a.snapshot.payload.jobs ?? []).count == 2, "A holds each record exactly once (no duplicates)")

        // === Scenario 2: concurrent edit to the same record — last writer wins =
        try upsertJob(a, id: "jA", title: "edited-by-A")
        try upsertJob(b, id: "jA", title: "edited-by-B")
        try await sync(a)                        // A pushes "edited-by-A" first (T1)
        try await sync(b)                        // B pushes "edited-by-B" second (T2 > T1)
        try await sync(a)                        // A pulls the winning value
        expect(jobTitles(a)["jA"] == "edited-by-B", "A converges to the last writer's value")
        expect(jobTitles(b)["jA"] == "edited-by-B", "B keeps the last writer's value")
        expect((a.snapshot.payload.jobs ?? []).filter { $0.id == "jA" }.count == 1,
               "a concurrently-edited record never duplicates")

        // === Scenario 3: a delete propagates to the other device =============
        try deleteJob(a, id: "jB")
        try await sync(a)                        // A pushes the soft delete, pulls jB removed
        try await sync(b)                        // B pulls the tombstone
        expect(!(a.snapshot.payload.jobs ?? []).contains { $0.id == "jB" }, "the deleting device drops jB")
        expect(!(b.snapshot.payload.jobs ?? []).contains { $0.id == "jB" }, "the delete propagates to B")
        expect(server.liveRowCount(table: "jobs", userID: subject) == 1, "only the surviving job is live server-side")

        // === Scenario 4: concurrent invoice edits never lose a device's own ===
        // payment. A blob upsert overwrites the whole server row, so the second
        // pusher clobbers the first's payment on the server; the delta pull's
        // payment-ledger union (utils/syncMerge.ts) then rescues the first
        // device's payment when it pulls the overwrite. This is the
        // "server-authoritative payments without overwriting newer local edits"
        // guarantee — asserted where it actually holds: on the pulling client.
        func seedInvoice(_ device: Device, payments: [Canonical.JSONValue]) throws {
            let blob = invoiceBlob(id: "inv1", amount: 1000, payments: payments)
            var invoices = device.snapshot.payload.invoices ?? []
            let record = try decoded(Canonical.Invoice.self, blob)
            if let idx = invoices.firstIndex(where: { $0.id == "inv1" }) { invoices[idx] = record } else { invoices.append(record) }
            device.snapshot.payload.invoices = invoices
            try device.queue.enqueue(table: "invoices", op: .upsert, recordId: "inv1", payload: blob)
        }
        // Both devices start from a shared invoice with no payments.
        try seedInvoice(a, payments: [])
        try await sync(a)
        try await sync(b)                        // B learns inv1 exists
        func paymentIDs(_ device: Device) -> Set<String> {
            Set((device.snapshot.payload.invoices?.first { $0.id == "inv1" }?.payments ?? []).map(\.id))
        }
        expect(paymentIDs(b) == [], "both devices share an empty invoice ledger to start")

        // Concurrent payments to the SAME invoice.
        try seedInvoice(a, payments: [paymentBlob(id: "pA", amount: 100, date: "2026-09-10")])
        try seedInvoice(b, payments: [paymentBlob(id: "pB", amount: 200, date: "2026-09-11")])
        try await sync(a)                        // server ledger: {pA}
        try await sync(b)                        // server ledger: {pB} (blob overwrite)
        try await sync(a)                        // A pulls {pB}; union with local {pA}
        expect(paymentIDs(a) == ["pA", "pB"], "the pulling device keeps its own payment and gains the remote one")
        expect((a.snapshot.payload.invoices?.first { $0.id == "inv1" }?.payments ?? []).count == 2,
               "the merged ledger has no duplicate payments")

        // === Scenario 5: offline durability + idempotent crash-replay =========
        let c = try Device(subject: subject, label: "C")
        defer { c.cleanup() }
        // Offline: two edits accumulate in the durable queue with no network.
        try upsertJob(c, id: "jC", title: "offline-1")
        try upsertJob(c, id: "jC", title: "offline-2")   // dedup: one item for jC
        expect(c.queue.load().count == 1, "repeated offline edits to one record collapse to a single queued item")

        // Simulate a relaunch: a fresh queue instance reads the same file.
        let reopened = Canonical.NativeMutationQueue(fileURL: c.queueFileURL)
        expect(reopened.load().count == 1, "the queue survives a simulated relaunch")

        // Reconnect and push — but simulate a crash BEFORE the queue is cleared,
        // so the identical item is pushed a second time on the next launch.
        let items = c.queue.load()
        _ = try await push.push(sessionBytes: session, expectedUserSubject: subject, items: items)
        _ = try await push.push(sessionBytes: session, expectedUserSubject: subject, items: items)
        try c.queue.save([])                     // the eventual successful commit
        expect(server.liveRowCount(table: "jobs", userID: subject) == 2,
               "an idempotent replay adds jC exactly once (no duplicate from re-push)")

        try await sync(c)
        expect(jobTitles(c)["jC"] == "offline-2", "the offline edit reaches the server and pulls back intact")

        // === Scenario 6: shipped React Native wire contract interoperates =====
        // The RN client still sends `updated_at` from its own clock. The checked-
        // in database trigger must replace it, allowing both clients to share the
        // same server cursor even when the RN device clock is far ahead or behind.
        let swift = try Device(subject: subject, label: "swift-mixed")
        defer { swift.cleanup() }
        let reactNative = ReactNativeReferenceClient(
            subject: subject, baseURL: supabaseURL, loader: server
        )

        try await reactNative.upsert(
            table: "jobs", id: "jMixed", data: jobBlob(id: "jMixed", title: "from React Native"),
            clientUpdatedAt: "2099-01-01T00:00:00.000Z"
        )
        let storedRNRow = server.storedRow(table: "jobs", id: "jMixed", userID: subject)
        expect(storedRNRow?.updatedAt != "2099-01-01T00:00:00.000Z",
               "database authority ignores React Native's future client timestamp")

        try await sync(swift)
        expect(jobTitles(swift)["jMixed"] == "from React Native",
               "Swift pulls a React Native-origin record")
        expect(swift.cursorStore.load().tables["jobs"] == storedRNRow?.updatedAt,
               "Swift persists the server timestamp rather than React Native's device clock")

        try upsertJob(swift, id: "jMixed", title: "edited in Swift")
        try await sync(swift)
        try await reactNative.pull(table: "jobs")
        expect(reactNative.title(forJob: "jMixed") == "edited in Swift",
               "React Native pulls a Swift-origin edit")

        try await reactNative.upsert(
            table: "jobs", id: "jMixed", data: jobBlob(id: "jMixed", title: "RN last writer"),
            clientUpdatedAt: "1990-01-01T00:00:00.000Z"
        )
        try await sync(swift)
        expect(jobTitles(swift)["jMixed"] == "RN last writer",
               "a later React Native write wins despite a stale device timestamp")

        try upsertJob(swift, id: "jSwiftOnly", title: "Swift-created")
        try await sync(swift)
        try await reactNative.pull(table: "jobs")
        expect(reactNative.title(forJob: "jSwiftOnly") == "Swift-created",
               "React Native discovers a Swift-created record")
        try await reactNative.delete(
            table: "jobs", id: "jSwiftOnly", clientUpdatedAt: "2099-01-01T00:00:00.000Z"
        )
        try await sync(swift)
        expect(jobTitles(swift)["jSwiftOnly"] == nil,
               "Swift applies a React Native owner-scoped soft delete")

        if failures == 0 { print("PASS: native and mixed-client convergence tests") }
        else { exit(1) }
    }

    static let server = InMemorySupabase()
}
