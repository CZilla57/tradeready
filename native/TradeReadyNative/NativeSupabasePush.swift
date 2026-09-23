import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum NativeMutationPushError: LocalizedError, Equatable {
    case invalidConfiguration
    case malformedSession
    case productionWriteBlocked

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            "Cloud sync is not configured for this build."
        case .malformedSession:
            "Your sign-in needs to be refreshed before local changes can upload."
        case .productionWriteBlocked:
            "Cloud writes are blocked because this build does not have a safe Supabase environment."
        }
    }
}

protocol NativeMutationPushHTTPLoading {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: NativeMutationPushHTTPLoading {}

/// The result of one push pass. The caller persists `remaining` as the new
/// queue and, when `authRejected` is set, refreshes the session before the next
/// attempt. Successful items are dropped; failed items are retained for retry.
struct NativeMutationPushOutcome: Equatable {
    var remaining: [Canonical.MutationItem]
    var pushedCount: Int
    var failedTables: [String]
    var authRejected: Bool
    var lastDiagnosticCode: String?
}

/// Phase 4 write path for the existing JSON-blob sync contract.
///
/// It drains the durable ``Canonical/NativeMutationQueue`` to Supabase's Data
/// API using the same owner-filtered, credential-scrubbed, bounded-diagnostic
/// discipline as ``NativeSupabaseInitialSyncService``. Every write is idempotent
/// — collection and settings upserts resolve on their primary key and deletes
/// are soft `deleted = true` updates — so a crash between a server success and
/// the local queue commit safely replays. `updated_at` is never sent; the
/// database stamps it authoritatively.
struct NativeSupabaseMutationPushService {
    private static let diagnosticDefaultsKey = "TradeReadyMutationPushDiagnosticCode"

    /// Tables whose primary key is the record `id` and whose row wraps the blob
    /// in a `data` column. Everything else (`settings`, `customer_notes`) has a
    /// bespoke row shape handled explicitly below.
    private static let collectionTables: Set<String> = [
        "jobs", "invoices", "customers", "expenses", "pricebook",
        "recurringJobs", "recurringInvoices", "trips", "bookingRequests", "jobPhotos"
    ]

    private struct StoredSession: Decodable {
        let accessToken: String

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
        }
    }

    /// The latest bounded failure code for the most recent push attempt. It
    /// contains no account identifiers, URLs, credentials, or row values.
    static var lastDiagnosticCode: String? {
        UserDefaults.standard.string(forKey: diagnosticDefaultsKey)
    }

    let supabaseURL: URL
    let publishableKey: String
    let allowsWrites: Bool
    let loader: any NativeMutationPushHTTPLoading

    init(
        supabaseURL: URL,
        publishableKey: String,
        allowsWrites: Bool,
        loader: any NativeMutationPushHTTPLoading = URLSession.shared
    ) {
        self.supabaseURL = supabaseURL
        self.publishableKey = publishableKey
        self.allowsWrites = allowsWrites
        self.loader = loader
    }

    func push(
        sessionBytes: Data,
        expectedUserSubject: String,
        items: [Canonical.MutationItem]
    ) async throws -> NativeMutationPushOutcome {
        Self.clearDiagnostic()
        guard allowsWrites else { throw NativeMutationPushError.productionWriteBlocked }
        guard supabaseURL.scheme?.lowercased() == "https", supabaseURL.host != nil,
              !publishableKey.isEmpty, !expectedUserSubject.isEmpty
        else { throw NativeMutationPushError.invalidConfiguration }

        let session: StoredSession
        do { session = try JSONDecoder().decode(StoredSession.self, from: sessionBytes) }
        catch { throw NativeMutationPushError.malformedSession }
        guard !session.accessToken.isEmpty else { throw NativeMutationPushError.malformedSession }

        guard !items.isEmpty else {
            return NativeMutationPushOutcome(
                remaining: [], pushedCount: 0, failedTables: [], authRejected: false,
                lastDiagnosticCode: nil
            )
        }

        var remaining: [Canonical.MutationItem] = []
        var pushed = 0
        var failedTables: [String] = []
        var authRejected = false

        for item in items {
            let request: URLRequest
            do {
                request = try buildRequest(
                    for: item,
                    subject: expectedUserSubject,
                    accessToken: session.accessToken
                )
            } catch {
                // A record whose blob id disagrees with its queued id, or an
                // unexpected row shape, can never be safely pushed. Drop it —
                // retaining it would wedge the queue behind an unsendable item —
                // and record a bounded diagnostic.
                Self.reportDiagnostic(stage: "record-contract", table: item.table)
                Self.appendUnique(item.table, to: &failedTables)
                continue
            }

            switch await send(request, table: item.table) {
            case .success:
                pushed += 1
            case .authRejected:
                authRejected = true
                remaining.append(item)
                Self.appendUnique(item.table, to: &failedTables)
            case .transient:
                remaining.append(item)
                Self.appendUnique(item.table, to: &failedTables)
            }
        }

        return NativeMutationPushOutcome(
            remaining: remaining,
            pushedCount: pushed,
            failedTables: failedTables,
            authRejected: authRejected,
            lastDiagnosticCode: Self.lastDiagnosticCode
        )
    }

    private enum SendResult {
        case success
        case authRejected
        case transient
    }

    private func send(_ request: URLRequest, table: String) async -> SendResult {
        let data: Data
        let response: URLResponse
        do { (data, response) = try await loader.data(for: request) }
        catch {
            Self.reportDiagnostic(stage: "transport", table: table)
            return .transient
        }
        _ = data
        guard let http = response as? HTTPURLResponse else {
            Self.reportDiagnostic(stage: "non-http-response", table: table)
            return .transient
        }
        guard (200..<300).contains(http.statusCode) else {
            Self.reportDiagnostic(stage: "http-response", table: table, statusCode: http.statusCode)
            if http.statusCode == 401 || http.statusCode == 403 { return .authRejected }
            return .transient
        }
        return .success
    }

    private func buildRequest(
        for item: Canonical.MutationItem,
        subject: String,
        accessToken: String
    ) throws -> URLRequest {
        switch item.op {
        case .upsert:
            return try upsertRequest(for: item, subject: subject, accessToken: accessToken)
        case .delete:
            return try deleteRequest(for: item, subject: subject, accessToken: accessToken)
        }
    }

    private func upsertRequest(
        for item: Canonical.MutationItem,
        subject: String,
        accessToken: String
    ) throws -> URLRequest {
        guard let payload = item.payload else { throw NativeMutationPushError.malformedSession }
        let body: Canonical.JSONValue
        switch item.table {
        case "settings":
            guard case let .object(fields) = payload else {
                throw NativeMutationPushError.invalidConfiguration
            }
            var scrubbed = fields
            for key in Canonical.SnapshotCodec.secureSettingsKeys { scrubbed.removeValue(forKey: key) }
            body = .object(["user_id": .string(subject), "data": .object(scrubbed)])
        case "customer_notes":
            guard case .string = payload else { throw NativeMutationPushError.invalidConfiguration }
            body = .object([
                "user_id": .string(subject),
                "customer_key": .string(item.recordId),
                "note": payload
            ])
        default:
            guard Self.collectionTables.contains(item.table),
                  Self.recordID(in: payload) == item.recordId
            else { throw NativeMutationPushError.invalidConfiguration }
            body = .object([
                "id": .string(item.recordId),
                "user_id": .string(subject),
                "data": payload,
                "deleted": .bool(false)
            ])
        }

        var request = try baseRequest(path: "rest/v1/\(item.table)")
        request.httpMethod = "POST"
        request.setValue(
            "resolution=merge-duplicates,return=minimal",
            forHTTPHeaderField: "Prefer"
        )
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try Self.encoder.encode(body)
        return request
    }

    private func deleteRequest(
        for item: Canonical.MutationItem,
        subject: String,
        accessToken: String
    ) throws -> URLRequest {
        guard var components = URLComponents(
            url: supabaseURL.appending(path: "rest/v1/\(item.table)"),
            resolvingAgainstBaseURL: false
        ) else { throw NativeMutationPushError.invalidConfiguration }

        var query = [URLQueryItem(name: "user_id", value: "eq.\(subject)")]
        switch item.table {
        case "settings":
            break // one row per user, keyed by user_id alone
        case "customer_notes":
            query.append(URLQueryItem(name: "customer_key", value: "eq.\(item.recordId)"))
        default:
            guard Self.collectionTables.contains(item.table) else {
                throw NativeMutationPushError.invalidConfiguration
            }
            query.append(URLQueryItem(name: "id", value: "eq.\(item.recordId)"))
        }
        components.queryItems = query
        guard let url = components.url else { throw NativeMutationPushError.invalidConfiguration }

        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue(publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("return=minimal", forHTTPHeaderField: "Prefer")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try Self.encoder.encode(Canonical.JSONValue.object(["deleted": .bool(true)]))
        return request
    }

    private func baseRequest(path: String) throws -> URLRequest {
        guard let components = URLComponents(
            url: supabaseURL.appending(path: path),
            resolvingAgainstBaseURL: false
        ), let url = components.url else { throw NativeMutationPushError.invalidConfiguration }
        var request = URLRequest(url: url)
        request.setValue(publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private static func recordID(in value: Canonical.JSONValue) -> String? {
        guard case let .object(fields) = value,
              case let .string(id)? = fields["id"]
        else { return nil }
        return id
    }

    private static func appendUnique(_ table: String, to tables: inout [String]) {
        if !tables.contains(table) { tables.append(table) }
    }

    /// Emits only a bounded stage, known table name, and HTTP status. It must
    /// never include URLs, subjects, tokens, request bodies, or row values.
    private static func reportDiagnostic(
        stage: String,
        table: String? = nil,
        statusCode: Int? = nil
    ) {
        let tableValue = table ?? "none"
        let statusValue = statusCode.map(String.init) ?? "none"
        let code = [stage, table, statusCode.map(String.init)]
            .compactMap { $0 }
            .joined(separator: "/")
        if UserDefaults.standard.string(forKey: diagnosticDefaultsKey) == nil {
            UserDefaults.standard.set(code, forKey: diagnosticDefaultsKey)
        }
        print("TradeReadyMutationPush stage=\(stage) table=\(tableValue) status=\(statusValue)")
    }

    static func clearDiagnostic() {
        UserDefaults.standard.removeObject(forKey: diagnosticDefaultsKey)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()
}
