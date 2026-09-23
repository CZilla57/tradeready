import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private final class DeltaLoader: NativeInitialSyncHTTPDataLoading {
    var requests: [URLRequest] = []
    var response: (URLRequest) throws -> (Int, Data)

    init(response: @escaping (URLRequest) throws -> (Int, Data)) {
        self.response = response
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        let (status, data) = try response(request)
        let http = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        return (data, http)
    }
}

@main
struct DeltaSyncTests {
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
        let subject = "11111111-2222-3333-4444-555555555555"
        let session = Data(#"{"access_token":"private-access-token"}"#.utf8)
        let supabaseURL = URL(string: "https://project.supabase.co")!

        func decoded<T: Decodable>(_ type: T.Type, _ value: Canonical.JSONValue) throws -> T {
            try JSONDecoder().decode(type, from: JSONEncoder().encode(value))
        }
        func jobData(id: String, title: String) -> Canonical.JSONValue {
            guard case var .object(fields) = rich["job"]! else { fatalError("job fixture") }
            fields["id"] = .string(id)
            fields["title"] = .string(title)
            return .object(fields)
        }
        func row(id: String, data: Canonical.JSONValue, updatedAt: String, deleted: Bool = false, userID: String? = nil) -> Canonical.JSONValue {
            .object([
                "id": .string(id),
                "user_id": .string(userID ?? subject),
                "data": data,
                "deleted": .bool(deleted),
                "updated_at": .string(updatedAt)
            ])
        }
        func table(_ request: URLRequest) -> String {
            request.url!.pathComponents.last ?? ""
        }
        func query(_ request: URLRequest, _ name: String) -> String? {
            URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == name }?.value
        }
        func encodeRows(_ rows: [Canonical.JSONValue]) throws -> Data {
            try JSONEncoder().encode(rows)
        }

        // Local snapshot: one existing job (stale title) the delta will update.
        let localSnapshot = Canonical.Snapshot(payload: .init(
            jobs: [try decoded(Canonical.Job.self, jobData(id: "j1", title: "Old title"))]
        ))
        let service = NativeSupabaseInitialSyncService(
            supabaseURL: supabaseURL, publishableKey: "publishable-key", loader: DeltaLoader { _ in (200, Data("[]".utf8)) }
        )

        // --- Cursor value type ---------------------------------------------
        var cursor = Canonical.NativeSyncCursor.empty()
        expect(cursor.version == Canonical.NativeSyncCursor.currentVersion, "an empty cursor uses the current version")
        expect(cursor.pullStart(for: "jobs") == Canonical.NativeSyncCursor.epoch, "no watermark pulls from the epoch")
        cursor = cursor.advancing("jobs", to: "2026-09-08T12:00:00.000Z")
        expect(cursor.tables["jobs"] == "2026-09-08T12:00:00.000Z", "advancing records the watermark")
        expect(cursor.advancing("jobs", to: "2026-09-08T09:00:00.000Z").tables["jobs"] == "2026-09-08T12:00:00.000Z",
               "advancing keeps the later of two watermarks")
        expect(cursor.pullStart(for: "jobs") == "2026-09-08T11:55:00.000Z",
               "a watermark pulls from five minutes before it (overlap window)")

        // --- First pass: empty cursor, full-from-epoch fetch, merge+advance -
        let firstLoader = DeltaLoader { request in
            switch table(request) {
            case "jobs":
                return (200, try encodeRows([
                    row(id: "j1", data: jobData(id: "j1", title: "New title"), updatedAt: "2026-09-08T10:00:00.000Z"),
                    row(id: "j2", data: jobData(id: "j2", title: "Fresh"), updatedAt: "2026-09-08T12:00:00.000Z")
                ]))
            case "settings":
                return (200, try encodeRows([.object(["user_id": .string(subject), "data": rich["settings"]!])]))
            case "customer_notes":
                return (200, try encodeRows([.object([
                    "user_id": .string(subject), "customer_key": .string("ada"), "note": .string("VIP")
                ])]))
            default:
                return (200, Data("[]".utf8))
            }
        }
        let firstService = NativeSupabaseInitialSyncService(
            supabaseURL: supabaseURL, publishableKey: "publishable-key", loader: firstLoader
        )
        let first = try await firstService.pullDelta(
            sessionBytes: session, expectedUserSubject: subject,
            localSnapshot: localSnapshot, cursor: .empty()
        )
        expect(first.failedTables.isEmpty, "a clean pass reports no failed tables")
        let firstJobs = first.snapshot.payload.jobs ?? []
        expect(firstJobs.contains { $0.id == "j1" && $0.title == "New title" }, "an existing record is updated from the delta")
        expect(firstJobs.contains { $0.id == "j2" }, "a new remote record is added")
        expect(first.cursor.tables["jobs"] == "2026-09-08T12:00:00.000Z",
               "the jobs watermark advances to the newest row seen")
        expect(first.snapshot.payload.customerNotes?["ada"] == "VIP", "customer notes are merged in")
        // The jobs request used the epoch lower bound on the first pass.
        if let jobsRequest = firstLoader.requests.first(where: { table($0) == "jobs" }) {
            expect(query(jobsRequest, "updated_at") == "gte.\(Canonical.NativeSyncCursor.epoch)",
                   "the first jobs pull filters from the epoch")
            expect(query(jobsRequest, "user_id") == "eq.\(subject)", "every pull is owner-scoped")
        } else {
            expect(false, "a jobs request was issued")
        }
        // Settings are scrubbed of secure keys through the snapshot codec boundary.
        if let settings = first.snapshot.payload.settings {
            let encoded = try JSONEncoder().encode(settings)
            let object = try JSONDecoder().decode([String: Canonical.JSONValue].self, from: encoded)
            for key in Canonical.SnapshotCodec.secureSettingsKeys {
                expect(object[key] == nil, "the delta scrubs \(key) from merged settings")
            }
        } else {
            expect(false, "settings were merged")
        }

        // --- Second pass sends the overlap-adjusted lower bound -------------
        let secondLoader = DeltaLoader { request in
            table(request) == "settings"
                ? (200, Data("[]".utf8))
                : (200, Data("[]".utf8))
        }
        let secondService = NativeSupabaseInitialSyncService(
            supabaseURL: supabaseURL, publishableKey: "publishable-key", loader: secondLoader
        )
        _ = try await secondService.pullDelta(
            sessionBytes: session, expectedUserSubject: subject,
            localSnapshot: localSnapshot, cursor: first.cursor
        )
        if let jobsRequest = secondLoader.requests.first(where: { table($0) == "jobs" }) {
            expect(query(jobsRequest, "updated_at") == "gte.2026-09-08T11:55:00.000Z",
                   "a later pull resumes from five minutes before the watermark")
        } else {
            expect(false, "the second pass issued a jobs request")
        }

        // --- Deleted rows remove the local record --------------------------
        let deleteLoader = DeltaLoader { request in
            table(request) == "jobs"
                ? (200, try encodeRows([row(
                    id: "j1", data: jobData(id: "j1", title: "New title"),
                    updatedAt: "2026-09-09T10:00:00.000Z", deleted: true
                )]))
                : (200, Data("[]".utf8))
        }
        let deleteService = NativeSupabaseInitialSyncService(
            supabaseURL: supabaseURL, publishableKey: "publishable-key", loader: deleteLoader
        )
        let afterDelete = try await deleteService.pullDelta(
            sessionBytes: session, expectedUserSubject: subject,
            localSnapshot: localSnapshot, cursor: .empty()
        )
        expect(!(afterDelete.snapshot.payload.jobs ?? []).contains { $0.id == "j1" },
               "a soft-deleted remote row removes the local record")

        // --- A single failing table is isolated, not fatal -----------------
        let isolatedLoader = DeltaLoader { request in
            switch table(request) {
            case "invoices": return (500, Data("{}".utf8))
            case "jobs":
                return (200, try encodeRows([row(
                    id: "j2", data: jobData(id: "j2", title: "Fresh"), updatedAt: "2026-09-08T12:00:00.000Z"
                )]))
            default: return (200, Data("[]".utf8))
            }
        }
        let isolatedService = NativeSupabaseInitialSyncService(
            supabaseURL: supabaseURL, publishableKey: "publishable-key", loader: isolatedLoader
        )
        let isolated = try await isolatedService.pullDelta(
            sessionBytes: session, expectedUserSubject: subject,
            localSnapshot: localSnapshot, cursor: .empty()
        )
        expect(isolated.failedTables == ["invoices"], "a failing table is reported and isolated")
        expect(isolated.cursor.tables["invoices"] == nil, "a failed table's watermark is not advanced")
        expect(isolated.cursor.tables["jobs"] == "2026-09-08T12:00:00.000Z", "sibling tables still advance")
        expect((isolated.snapshot.payload.jobs ?? []).contains { $0.id == "j2" }, "sibling tables still merge")

        // --- An ownership violation isolates that table (fail-closed) -------
        let ownershipLoader = DeltaLoader { request in
            table(request) == "jobs"
                ? (200, try encodeRows([row(
                    id: "jx", data: jobData(id: "jx", title: "Intruder"),
                    updatedAt: "2026-09-08T12:00:00.000Z", userID: "99999999-0000-0000-0000-000000000000"
                )]))
                : (200, Data("[]".utf8))
        }
        let ownershipService = NativeSupabaseInitialSyncService(
            supabaseURL: supabaseURL, publishableKey: "publishable-key", loader: ownershipLoader
        )
        let ownership = try await ownershipService.pullDelta(
            sessionBytes: session, expectedUserSubject: subject,
            localSnapshot: localSnapshot, cursor: .empty()
        )
        expect(ownership.failedTables == ["jobs"], "a row owned by another user isolates the table")
        expect(ownership.cursor.tables["jobs"] == nil, "an ownership violation never advances the cursor")
        expect(!(ownership.snapshot.payload.jobs ?? []).contains { $0.id == "jx" }, "a foreign row is never applied")

        // --- Auth rejection aborts so the caller can refresh ---------------
        let authLoader = DeltaLoader { request in
            table(request) == "jobs" ? (401, Data("{}".utf8)) : (200, Data("[]".utf8))
        }
        let authService = NativeSupabaseInitialSyncService(
            supabaseURL: supabaseURL, publishableKey: "publishable-key", loader: authLoader
        )
        do {
            _ = try await authService.pullDelta(
                sessionBytes: session, expectedUserSubject: subject,
                localSnapshot: localSnapshot, cursor: .empty()
            )
            expect(false, "an auth rejection must throw")
        } catch NativeInitialSyncError.rejectedSession {
            expect(true, "an auth rejection throws rejectedSession")
        } catch {
            expect(false, "an auth rejection throws rejectedSession, not \(error)")
        }

        // --- Preflight throws on a malformed session -----------------------
        do {
            _ = try await service.pullDelta(
                sessionBytes: Data("not json".utf8), expectedUserSubject: subject,
                localSnapshot: localSnapshot, cursor: .empty()
            )
            expect(false, "a malformed session must throw")
        } catch NativeInitialSyncError.malformedSession {
            expect(true, "a malformed session throws malformedSession")
        } catch {
            expect(false, "a malformed session throws malformedSession, not \(error)")
        }

        // --- Cursor store round-trip + version tolerance -------------------
        let fileManager = FileManager.default
        let dir = fileManager.temporaryDirectory
            .appendingPathComponent("tradeready-cursor-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: dir) }
        let storeURL = dir.appendingPathComponent("cursor.json")
        let store = Canonical.NativeSyncCursorStore(fileURL: storeURL)
        expect(store.load() == .empty(), "a missing cursor file loads as empty")
        try store.save(first.cursor)
        expect(store.load() == first.cursor, "a saved cursor round-trips")
        // A wrong-version file recovers to empty (forces one safe full pull).
        try Data(#"{"version":1,"tables":{"jobs":"2020-01-01T00:00:00.000Z"}}"#.utf8)
            .write(to: storeURL, options: .atomic)
        expect(store.load() == .empty(), "a stale-version cursor loads as empty")
        try store.removeAll()
        expect(!fileManager.fileExists(atPath: storeURL.path), "removeAll deletes the cursor file")

        if failures == 0 { print("PASS: native delta sync tests") }
        else { exit(1) }
    }
}
