import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private final class PushLoader: NativeMutationPushHTTPLoading {
    var requests: [URLRequest] = []
    var respond: (URLRequest) -> Int

    init(respond: @escaping (URLRequest) -> Int) {
        self.respond = respond
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        let status = respond(request)
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        return (Data("".utf8), response)
    }
}

@main
struct MutationPushTests {
    static func main() async throws {
        var failures = 0
        func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
            if !condition() { failures += 1; print("FAIL: \(label)") }
        }

        let subject = "11111111-2222-3333-4444-555555555555"
        let session = try JSONSerialization.data(withJSONObject: [
            "access_token": "private-access-token",
            "refresh_token": "private-refresh-token"
        ], options: [.sortedKeys])
        let url = URL(string: "https://project.supabase.co")!

        func table(_ request: URLRequest) -> String {
            request.url!.pathComponents.last!.components(separatedBy: "?").first!
        }
        func body(_ request: URLRequest) -> Canonical.JSONValue? {
            guard let data = request.httpBody else { return nil }
            return try? JSONDecoder().decode(Canonical.JSONValue.self, from: data)
        }
        func fields(_ value: Canonical.JSONValue?) -> [String: Canonical.JSONValue]? {
            guard case let .object(fields)? = value else { return nil }
            return fields
        }
        func queryValue(_ request: URLRequest, _ name: String) -> String? {
            URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == name })?.value
        }
        func item(
            _ table: String, _ op: Canonical.MutationOp, _ id: String,
            _ payload: Canonical.JSONValue?
        ) -> Canonical.MutationItem {
            Canonical.MutationItem(table: table, op: op, recordId: id, payload: payload, ts: "2026-09-11T00:00:00.000Z")
        }
        func jobBlob(_ id: String) -> Canonical.JSONValue {
            .object(["id": .string(id), "title": .string("Panel upgrade")])
        }

        // Collection upsert wire contract.
        let okLoader = PushLoader { _ in 201 }
        let service = NativeSupabaseMutationPushService(
            supabaseURL: url, publishableKey: "publishable-key", allowsWrites: true,
            loader: okLoader
        )
        let jobsOutcome = try await service.push(
            sessionBytes: session, expectedUserSubject: subject,
            items: [item("jobs", .upsert, "j1", jobBlob("j1"))]
        )
        expect(jobsOutcome.pushedCount == 1 && jobsOutcome.remaining.isEmpty,
               "a successful upsert is pushed and dropped from the queue")
        let jobsRequest = okLoader.requests[0]
        expect(jobsRequest.httpMethod == "POST" && table(jobsRequest) == "jobs",
               "a collection upsert POSTs to the collection table")
        expect(jobsRequest.value(forHTTPHeaderField: "apikey") == "publishable-key"
               && jobsRequest.value(forHTTPHeaderField: "Authorization") == "Bearer private-access-token",
               "every write is authenticated with the publishable key and bearer token")
        expect(jobsRequest.value(forHTTPHeaderField: "Prefer") == "resolution=merge-duplicates,return=minimal",
               "collection upserts use an idempotent merge-duplicates upsert")
        let jobsFields = fields(body(jobsRequest))
        expect(jobsFields?["id"] == .string("j1")
               && jobsFields?["user_id"] == .string(subject)
               && jobsFields?["data"] == jobBlob("j1")
               && jobsFields?["deleted"] == .bool(false),
               "the collection row wraps the blob under data with an owner and deleted flag")
        expect(jobsFields?["updated_at"] == nil,
               "the client never sends updated_at; the database stamps it authoritatively")

        // Settings upsert scrubs secure credential fields.
        let settingsLoader = PushLoader { _ in 200 }
        _ = try await NativeSupabaseMutationPushService(
            supabaseURL: url, publishableKey: "publishable-key", allowsWrites: true,
            loader: settingsLoader
        ).push(
            sessionBytes: session, expectedUserSubject: subject,
            items: [item("settings", .upsert, "settings", .object([
                "businessName": .string("Ada Electric"),
                "providerKey": .string("secret"),
                "anthropicKey": .string("secret"),
                "groqKey": .string("secret")
            ]))]
        )
        let settingsRequest = settingsLoader.requests[0]
        let settingsData = fields(fields(body(settingsRequest))?["data"])
        expect(fields(body(settingsRequest))?["user_id"] == .string(subject),
               "settings is keyed by the owner")
        expect(settingsData?["businessName"] == .string("Ada Electric"),
               "settings upsert carries plain business fields")
        expect(settingsData?["providerKey"] == nil && settingsData?["anthropicKey"] == nil
               && settingsData?["groqKey"] == nil,
               "settings upsert scrubs every secure credential field before sending")

        // Customer note upsert wire contract.
        let notesLoader = PushLoader { _ in 201 }
        _ = try await NativeSupabaseMutationPushService(
            supabaseURL: url, publishableKey: "publishable-key", allowsWrites: true,
            loader: notesLoader
        ).push(
            sessionBytes: session, expectedUserSubject: subject,
            items: [item("customer_notes", .upsert, "cust-key-1", .string("Prefers morning visits"))]
        )
        let notesFields = fields(body(notesLoader.requests[0]))
        expect(notesFields?["user_id"] == .string(subject)
               && notesFields?["customer_key"] == .string("cust-key-1")
               && notesFields?["note"] == .string("Prefers morning visits"),
               "a customer note upsert sends owner, customer_key, and note")

        // Soft delete wire contract.
        let deleteLoader = PushLoader { _ in 204 }
        let deleteOutcome = try await NativeSupabaseMutationPushService(
            supabaseURL: url, publishableKey: "publishable-key", allowsWrites: true,
            loader: deleteLoader
        ).push(
            sessionBytes: session, expectedUserSubject: subject,
            items: [item("jobs", .delete, "j1", nil)]
        )
        let deleteRequest = deleteLoader.requests[0]
        expect(deleteRequest.httpMethod == "PATCH", "a delete is a soft update, not a hard DELETE")
        expect(queryValue(deleteRequest, "id") == "eq.j1"
               && queryValue(deleteRequest, "user_id") == "eq.\(subject)",
               "a delete is scoped to the exact record and its owner")
        expect(fields(body(deleteRequest))?["deleted"] == .bool(true),
               "a delete sets the soft-delete flag")
        expect(deleteOutcome.pushedCount == 1 && deleteOutcome.remaining.isEmpty,
               "a successful delete is dropped from the queue")

        // Ownership guard: a blob whose id disagrees with the queued id is
        // dropped fail-closed and never sent.
        let mismatchLoader = PushLoader { _ in 201 }
        let mismatchOutcome = try await NativeSupabaseMutationPushService(
            supabaseURL: url, publishableKey: "publishable-key", allowsWrites: true,
            loader: mismatchLoader
        ).push(
            sessionBytes: session, expectedUserSubject: subject,
            items: [item("jobs", .upsert, "j1", jobBlob("DIFFERENT"))]
        )
        expect(mismatchLoader.requests.isEmpty, "a record-id/blob-id mismatch is never sent to the server")
        expect(mismatchOutcome.remaining.isEmpty && mismatchOutcome.pushedCount == 0
               && mismatchOutcome.failedTables == ["jobs"],
               "an unsendable record is dropped rather than wedging the queue")
        expect(mismatchOutcome.lastDiagnosticCode == "record-contract/jobs",
               "a contract failure exposes only a bounded diagnostic code")

        // Transient failure retains the item for retry.
        let failLoader = PushLoader { _ in 500 }
        let failOutcome = try await NativeSupabaseMutationPushService(
            supabaseURL: url, publishableKey: "publishable-key", allowsWrites: true,
            loader: failLoader
        ).push(
            sessionBytes: session, expectedUserSubject: subject,
            items: [item("jobs", .upsert, "j1", jobBlob("j1"))]
        )
        expect(failOutcome.remaining.count == 1 && failOutcome.pushedCount == 0
               && failOutcome.authRejected == false && failOutcome.failedTables == ["jobs"],
               "a transient server failure retains the item without flagging auth")

        // Auth rejection flags the session for refresh and retains the item.
        let authLoader = PushLoader { _ in 401 }
        let authOutcome = try await NativeSupabaseMutationPushService(
            supabaseURL: url, publishableKey: "publishable-key", allowsWrites: true,
            loader: authLoader
        ).push(
            sessionBytes: session, expectedUserSubject: subject,
            items: [item("jobs", .upsert, "j1", jobBlob("j1"))]
        )
        expect(authOutcome.authRejected && authOutcome.remaining.count == 1,
               "an unauthorized response flags the session for refresh and retains the item")
        expect(authOutcome.lastDiagnosticCode == "http-response/jobs/401",
               "an HTTP failure exposes only a bounded table and status diagnostic")

        // Partial progress: successes drop, failures (by table) are retained.
        let partialLoader = PushLoader { request in table(request) == "invoices" ? 500 : 201 }
        let partialOutcome = try await NativeSupabaseMutationPushService(
            supabaseURL: url, publishableKey: "publishable-key", allowsWrites: true,
            loader: partialLoader
        ).push(
            sessionBytes: session, expectedUserSubject: subject,
            items: [
                item("jobs", .upsert, "j1", jobBlob("j1")),
                item("invoices", .upsert, "inv1", .object(["id": .string("inv1")])),
                item("customers", .upsert, "c1", .object(["id": .string("c1")]))
            ]
        )
        expect(partialOutcome.pushedCount == 2, "successful items in a mixed push are pushed")
        expect(partialOutcome.remaining.map(\.recordId) == ["inv1"],
               "only the failed item is retained for retry")
        expect(partialOutcome.failedTables == ["invoices"], "the failed table is reported once")

        // An empty queue makes no requests.
        let emptyLoader = PushLoader { _ in 201 }
        let emptyOutcome = try await NativeSupabaseMutationPushService(
            supabaseURL: url, publishableKey: "publishable-key", allowsWrites: true,
            loader: emptyLoader
        ).push(sessionBytes: session, expectedUserSubject: subject, items: [])
        expect(emptyLoader.requests.isEmpty && emptyOutcome == NativeMutationPushOutcome(
            remaining: [], pushedCount: 0, failedTables: [], authRejected: false, lastDiagnosticCode: nil
        ), "an empty queue is a no-op push")

        // The environment boundary is evaluated before credentials or any
        // request construction, so an unsafe build cannot leak a queued write.
        let blockedLoader = PushLoader { _ in 201 }
        do {
            _ = try await NativeSupabaseMutationPushService(
                supabaseURL: url, publishableKey: "publishable-key", allowsWrites: false,
                loader: blockedLoader
            ).push(
                sessionBytes: session, expectedUserSubject: subject,
                items: [item("jobs", .upsert, "j1", jobBlob("j1"))]
            )
            expect(false, "an environment-blocked push must fail closed")
        } catch NativeMutationPushError.productionWriteBlocked {
            expect(blockedLoader.requests.isEmpty,
                   "an environment-blocked push sends no network request")
        }

        // Pre-flight validation throws before any request.
        do {
            _ = try await NativeSupabaseMutationPushService(
                supabaseURL: URL(string: "http://project.supabase.co")!,
                publishableKey: "publishable-key", allowsWrites: true,
                loader: PushLoader { _ in 201 }
            ).push(sessionBytes: session, expectedUserSubject: subject, items: [item("jobs", .upsert, "j1", jobBlob("j1"))])
            expect(false, "a non-https endpoint must fail closed")
        } catch NativeMutationPushError.invalidConfiguration {
            expect(true, "a non-https endpoint fails closed")
        }

        do {
            _ = try await NativeSupabaseMutationPushService(
                supabaseURL: url, publishableKey: "publishable-key", allowsWrites: true,
                loader: PushLoader { _ in 201 }
            ).push(
                sessionBytes: Data(#"{"refresh_token":"x"}"#.utf8),
                expectedUserSubject: subject,
                items: [item("jobs", .upsert, "j1", jobBlob("j1"))]
            )
            expect(false, "a session without an access token must fail closed")
        } catch NativeMutationPushError.malformedSession {
            expect(true, "a session without an access token fails closed")
        }

        // Phase 12 (12.00b.1, I2): the status → class table, one pure function.
        // A 403 is rejected only on the push that follows one successful
        // refresh in the same pass; 408, 425, 429, 5xx, 3xx and every
        // non-response stay transient.
        typealias Class = NativeMutationPushResponseClass
        let classTable: [(NativeMutationPushResponse, Bool, Class)] = [
            (.http(statusCode: 200), false, .accepted), (.http(statusCode: 201), false, .accepted),
            (.http(statusCode: 204), true, .accepted), (.http(statusCode: 299), false, .accepted),
            (.http(statusCode: 301), false, .transient), (.http(statusCode: 304), true, .transient),
            (.http(statusCode: 400), false, .rejected), (.http(statusCode: 400), true, .rejected),
            (.http(statusCode: 401), false, .authRejected), (.http(statusCode: 401), true, .authRejected),
            (.http(statusCode: 403), false, .authRejected), (.http(statusCode: 403), true, .rejected),
            (.http(statusCode: 404), false, .rejected), (.http(statusCode: 409), false, .rejected),
            (.http(statusCode: 413), false, .rejected), (.http(statusCode: 422), false, .rejected),
            (.http(statusCode: 422), true, .rejected), (.http(statusCode: 405), false, .rejected),
            (.http(statusCode: 408), false, .transient), (.http(statusCode: 408), true, .transient),
            (.http(statusCode: 425), false, .transient), (.http(statusCode: 429), false, .transient),
            (.http(statusCode: 429), true, .transient),
            (.http(statusCode: 500), false, .transient), (.http(statusCode: 502), true, .transient),
            (.http(statusCode: 503), false, .transient), (.http(statusCode: 504), false, .transient),
            (.http(statusCode: 100), false, .transient), (.http(statusCode: 600), false, .transient),
            (.transportError, false, .transient), (.transportError, true, .transient),
            (.nonHTTP, false, .transient), (.nonHTTP, true, .transient),
        ]
        for (response, afterRefresh, expected) in classTable {
            let actual = NativeMutationPushClassification.classify(response, afterAuthRefresh: afterRefresh)
            expect(actual == expected, "classify \(response) afterAuthRefresh=\(afterRefresh) is \(expected) (got \(actual))")
        }

        // A rejected change leaves the remainder: it is returned once, with its
        // status, beside the pushed and retained items. It is not a failed
        // table, and the diagnostic is the bounded rejected/<table>/<status>.
        let rejectLoader = PushLoader { request in
            switch table(request) {
            case "invoices": 422
            case "customers": 503
            default: 201
            }
        }
        let invoiceItem = item("invoices", .upsert, "inv1", .object(["id": .string("inv1")]))
        let rejectOutcome = try await NativeSupabaseMutationPushService(
            supabaseURL: url, publishableKey: "publishable-key", allowsWrites: true, loader: rejectLoader
        ).push(
            sessionBytes: session, expectedUserSubject: subject,
            items: [
                item("jobs", .upsert, "j1", jobBlob("j1")),
                invoiceItem,
                item("customers", .upsert, "c1", .object(["id": .string("c1")])),
            ]
        )
        expect(rejectOutcome.pushedCount == 1, "rejection: the accepted item is pushed")
        expect(rejectOutcome.rejected == [NativeMutationRejection(item: invoiceItem, statusCode: 422)],
               "rejection: the refused item is returned once with its status")
        expect(rejectOutcome.remaining.map(\.recordId) == ["c1"],
               "rejection: only the transient item is retained in the remainder")
        expect(rejectOutcome.failedTables == ["customers"] && !rejectOutcome.authRejected,
               "rejection: a refused table is not a failed table and never flags auth")
        expect(rejectOutcome.lastDiagnosticCode == "rejected/invoices/422",
               "rejection: the bounded rejected/<table>/<status> diagnostic")

        // The first 403 keeps the auth path; the same 403 on the push after one
        // refresh (afterAuthRefresh) is a rejection.
        let forbiddenLoader = PushLoader { _ in 403 }
        let forbiddenService = NativeSupabaseMutationPushService(
            supabaseURL: url, publishableKey: "publishable-key", allowsWrites: true, loader: forbiddenLoader
        )
        let jobItem = item("jobs", .upsert, "j1", jobBlob("j1"))
        let firstForbidden = try await forbiddenService.push(
            sessionBytes: session, expectedUserSubject: subject, items: [jobItem]
        )
        expect(firstForbidden.authRejected && firstForbidden.remaining == [jobItem] && firstForbidden.rejected.isEmpty,
               "403: the first 403 keeps the auth-refresh path")
        let repeatedForbidden = try await forbiddenService.push(
            sessionBytes: session, expectedUserSubject: subject, items: [jobItem], afterAuthRefresh: true
        )
        expect(!repeatedForbidden.authRejected && repeatedForbidden.remaining.isEmpty
               && repeatedForbidden.rejected == [NativeMutationRejection(item: jobItem, statusCode: 403)],
               "403: a 403 that repeats after one refresh is a rejection")
        expect(repeatedForbidden.lastDiagnosticCode == "rejected/jobs/403",
               "403: the repeated 403 reports rejected/jobs/403")
        let repeatedUnauthorized = try await NativeSupabaseMutationPushService(
            supabaseURL: url, publishableKey: "publishable-key", allowsWrites: true, loader: PushLoader { _ in 401 }
        ).push(sessionBytes: session, expectedUserSubject: subject, items: [jobItem], afterAuthRefresh: true)
        expect(repeatedUnauthorized.authRejected && repeatedUnauthorized.rejected.isEmpty,
               "401: a 401 after a refresh stays on the auth path (the coordinator refreshes once per pass)")

        if failures == 0 { print("PASS: native mutation push tests") }
        else { exit(1) }
    }
}
