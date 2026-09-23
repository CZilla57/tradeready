import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private final class InitialSyncLoader: NativeInitialSyncHTTPDataLoading {
    var requests: [URLRequest] = []
    var response: (URLRequest) throws -> (Int, Data)

    init(response: @escaping (URLRequest) throws -> (Int, Data)) {
        self.response = response
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        let (status, data) = try response(request)
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        return (data, response)
    }
}

@main
struct InitialSyncTests {
    static func main() async throws {
        var failures = 0
        func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
            if !condition() { failures += 1; print("FAIL: \(label)") }
        }

        let fixtureRoot = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CANONICAL_FIXTURES_PATH"]!)
        let richData = try Data(contentsOf: fixtureRoot.appendingPathComponent("canonical-rich.json"))
        let rich = try JSONDecoder().decode([String: Canonical.JSONValue].self, from: richData)
        let subject = "11111111-2222-3333-4444-555555555555"
        let session = try JSONSerialization.data(withJSONObject: [
            "access_token": "private-access-token",
            "refresh_token": "private-refresh-token"
        ], options: [.sortedKeys])

        func decoded<T: Decodable>(_ type: T.Type, _ value: Canonical.JSONValue) throws -> T {
            try JSONDecoder().decode(type, from: JSONEncoder().encode(value))
        }
        func row(
            id: String,
            value: Canonical.JSONValue,
            deleted: Bool = false,
            userID: String? = nil
        ) -> Canonical.JSONValue {
            .object([
                "id": .string(id),
                "user_id": .string(userID ?? subject),
                "data": value,
                "deleted": .bool(deleted),
                "updated_at": .string("2026-09-08T12:00:00.000Z")
            ])
        }
        func tableName(_ request: URLRequest) -> String {
            request.url!.pathComponents.last!
        }
        func offset(_ request: URLRequest) -> Int {
            let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
            return Int(components?.queryItems?.first(where: { $0.name == "offset" })?.value ?? "0") ?? 0
        }

        var localJobFields: [String: Canonical.JSONValue]
        guard case let .object(jobFields) = rich["job"]! else { fatalError("job fixture") }
        localJobFields = jobFields
        localJobFields["title"] = .string("Local title")
        localJobFields["localFutureField"] = .string("local-only")
        var remoteJobFields = jobFields
        remoteJobFields["serverFutureField"] = .string("remote-only")

        var localInvoiceFields: [String: Canonical.JSONValue]
        guard case let .object(invoiceFields) = rich["invoice"]! else { fatalError("invoice fixture") }
        localInvoiceFields = invoiceFields
        var localPayments: [Canonical.JSONValue]
        guard case let .array(invoicePayments) = invoiceFields["payments"]! else { fatalError("payments fixture") }
        localPayments = invoicePayments
        localPayments.append(.object([
            "id": .string("local-cash"),
            "amount": .number(Decimal(1000)),
            "date": .string("2026-09-01"),
            "method": .string("cash"),
            "futureReceipt": .string("retain-me")
        ]))
        localInvoiceFields["payments"] = .array(localPayments)

        var remoteLegacyInvoiceFields = invoiceFields
        remoteLegacyInvoiceFields["id"] = .string("inv-legacy")
        remoteLegacyInvoiceFields["paid"] = .bool(true)
        remoteLegacyInvoiceFields["paidAt"] = .string("2026-08-01")
        remoteLegacyInvoiceFields.removeValue(forKey: "payments")

        var localBookingFields: [String: Canonical.JSONValue]
        guard case let .object(bookingFields) = rich["bookingRequest"]! else { fatalError("booking fixture") }
        localBookingFields = bookingFields
        guard case let .array(bookingHistory) = bookingFields["history"]! else { fatalError("history fixture") }
        localBookingFields["history"] = .array(bookingHistory + [.object([
            "at": .string("2026-08-10T08:02:00Z"),
            "actor": .string("pro"),
            "event": .string("called"),
            "futureAudit": .string("retain-me")
        ])])

        let local = Canonical.Snapshot(payload: .init(
            invoices: [try decoded(Canonical.Invoice.self, .object(localInvoiceFields))],
            jobs: [try decoded(Canonical.Job.self, .object(localJobFields))],
            customers: [try decoded(Canonical.Customer.self, rich["customer"]!)],
            settings: try decoded(Canonical.Settings.self, rich["settings"]!),
            expenses: [try decoded(Canonical.Expense.self, rich["expense"]!)],
            bookingRequests: [try decoded(Canonical.BookingRequest.self, .object(localBookingFields))]
        ))

        let loader = InitialSyncLoader { request in
            let table = tableName(request)
            switch table {
            case "jobs":
                return (200, try JSONEncoder().encode([row(
                    id: "j_20260812_precision", value: .object(remoteJobFields)
                )]))
            case "invoices":
                return (200, try JSONEncoder().encode([
                    row(id: "inv_1723456789012", value: rich["invoice"]!),
                    row(id: "inv-legacy", value: .object(remoteLegacyInvoiceFields))
                ]))
            case "expenses":
                return (200, try JSONEncoder().encode([row(
                    id: "e-1", value: rich["expense"]!, deleted: true
                )]))
            case "bookingRequests":
                return (200, try JSONEncoder().encode([row(
                    id: "bk-1", value: rich["bookingRequest"]!
                )]))
            case "settings":
                return (200, try JSONEncoder().encode([Canonical.JSONValue.object([
                    "user_id": .string(subject),
                    "data": rich["settings"]!
                ])]))
            case "customer_notes":
                let start = offset(request)
                let count = start == 0 ? NativeSupabaseInitialSyncService.pageSize : 1
                let rows = (start..<(start + count)).map { index in
                    Canonical.JSONValue.object([
                        "user_id": .string(subject),
                        "customer_key": .string("customer-\(index)"),
                        "note": .string("note-\(index)")
                    ])
                }
                return (200, try JSONEncoder().encode(rows))
            default:
                return (200, Data("[]".utf8))
            }
        }
        let service = NativeSupabaseInitialSyncService(
            supabaseURL: URL(string: "https://project.supabase.co")!,
            publishableKey: "publishable-key",
            loader: loader
        )
        let pulled = try await service.pull(
            sessionBytes: session,
            expectedUserSubject: subject,
            localSnapshot: local
        )

        expect(pulled.payload.jobs?.first?.title == "Panel upgrade",
               "remote scalar fields replace the local record")
        expect(pulled.payload.jobs?.first?.preservation.unknownFields["localFutureField"] == nil,
               "whole-record replacement does not retain stale local-only fields")
        expect(pulled.payload.jobs?.first?.preservation.unknownFields["serverFutureField"]
            == .string("remote-only"),
               "whole-record replacement retains remote additive fields")
        expect(pulled.payload.expenses?.isEmpty == true,
               "remote tombstones remove the matching local record")
        expect(pulled.payload.invoices?.first?.payments?.contains(where: { $0.id == "local-cash" }) == true,
               "invoice merge retains a local-only payment")
        expect(pulled.payload.invoices?.first?.payments?.first(where: { $0.id == "local-cash" })?
            .preservation.unknownFields["futureReceipt"] == .string("retain-me"),
               "invoice merge retains unknown payment fields")
        expect(pulled.payload.invoices?.first?.paid == true
               && pulled.payload.invoices?.first?.paidAt == "2026-09-01",
               "merged payment ledgers rederive paid and paidAt")
        expect(pulled.payload.invoices?.first(where: { $0.id == "inv-legacy" })?.payments == nil,
               "a newly pulled legacy paid invoice remains in its legacy representation")
        expect(pulled.payload.bookingRequests?.first?.history?.count == 3,
               "booking history unions the local audit entry")
        expect(pulled.payload.bookingRequests?.first?.history?.last?
            .preservation.unknownFields["futureAudit"] == .string("retain-me"),
               "booking history retains unknown entry fields")
        expect(pulled.payload.settings?.businessName == "Ada Electric"
               && pulled.payload.settings?.providerKey == ""
               && pulled.payload.settings?.anthropicKey == ""
               && pulled.payload.settings?.groqKey == "",
               "remote settings load while credential fields are scrubbed")
        expect(pulled.payload.customerNotes?.count == 501,
               "initial sync drains a collection beyond one Data API page")

        let collectionRequests = loader.requests.filter {
            !["settings", "customer_notes"].contains(tableName($0))
        }
        expect(Set(collectionRequests.map(tableName)).count == 10,
               "all ten production collection tables are pulled")
        expect(loader.requests.allSatisfy {
            $0.httpMethod == "GET"
                && $0.value(forHTTPHeaderField: "apikey") == "publishable-key"
                && $0.value(forHTTPHeaderField: "Authorization") == "Bearer private-access-token"
                && URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)?
                    .queryItems?.contains(URLQueryItem(name: "user_id", value: "eq.\(subject)")) == true
        }, "every read is authenticated and explicitly owner-filtered")

        let wrongOwnerLoader = InitialSyncLoader { request in
            if tableName(request) == "jobs" {
                return (200, try JSONEncoder().encode([row(
                    id: "j_20260812_precision",
                    value: rich["job"]!,
                    userID: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
                )]))
            }
            return (200, Data("[]".utf8))
        }
        do {
            _ = try await NativeSupabaseInitialSyncService(
                supabaseURL: URL(string: "https://project.supabase.co")!,
                publishableKey: "publishable-key",
                loader: wrongOwnerLoader
            ).pull(sessionBytes: session, expectedUserSubject: subject, localSnapshot: local)
            expect(false, "a mismatched response owner must fail closed")
        } catch NativeInitialSyncError.invalidResponse {
            expect(
                NativeSupabaseInitialSyncService.lastDiagnosticCode == "row-contract/jobs",
                "wrong-owner failures expose only a bounded diagnostic code"
            )
        }

        let rejectedLoader = InitialSyncLoader { _ in (401, Data("{}".utf8)) }
        do {
            _ = try await NativeSupabaseInitialSyncService(
                supabaseURL: URL(string: "https://project.supabase.co")!,
                publishableKey: "publishable-key",
                loader: rejectedLoader
            ).pull(sessionBytes: session, expectedUserSubject: subject, localSnapshot: local)
            expect(false, "an unauthorized Data API response must not advance")
        } catch NativeInitialSyncError.rejectedSession {
            expect(
                NativeSupabaseInitialSyncService.lastDiagnosticCode == "http-response/jobs/401",
                "HTTP failures expose only a bounded table and status diagnostic"
            )
        }

        if failures == 0 { print("PASS: native initial sync tests") }
        else { exit(1) }
    }
}
