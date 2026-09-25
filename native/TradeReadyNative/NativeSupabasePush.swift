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
    /// Phase 12 (12.00b.1, I2): changes the server refused (a non-auth 4xx,
    /// or a 403 after one refresh). They are not in `remaining`: the
    /// coordinator moves them to the rejected-change store before the queue
    /// drops them, and keeps them queued if it cannot.
    var rejected: [NativeMutationRejection] = []
    /// Fix round 1 (review M1): the record keys of the changes this attempt
    /// got a 403 for. The coordinator's one retry after a refresh passes them
    /// back, so only a change whose 403 repeats is refused.
    var forbiddenKeys: Set<String> = []
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
        try await push(
            sessionBytes: sessionBytes,
            expectedUserSubject: expectedUserSubject,
            items: items,
            forbiddenBeforeRefresh: []
        )
    }

    /// `forbiddenBeforeRefresh` holds, for the coordinator's retry after one
    /// successful session refresh in the same pass, the record keys that got
    /// a 403 before it (the previous outcome's `forbiddenKeys`). A 403 for one
    /// of them is a rejection; a 403 for any other change is still an auth
    /// failure (`NativeMutationPushClassification`, review M1).
    func push(
        sessionBytes: Data,
        expectedUserSubject: String,
        items: [Canonical.MutationItem],
        forbiddenBeforeRefresh: Set<String>
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
        var rejected: [NativeMutationRejection] = []
        var forbiddenKeys: Set<String> = []

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

            let key = NativeMutationPushClassification.recordKey(item)
            let (result, response) = await send(request, forbiddenBeforeRefresh: forbiddenBeforeRefresh.contains(key))
            switch result {
            case .accepted:
                pushed += 1
            case .authRejected:
                Self.reportResponse(response, table: item.table)
                authRejected = true
                if response == .http(statusCode: 403) { forbiddenKeys.insert(key) }
                remaining.append(item)
                Self.appendUnique(item.table, to: &failedTables)
            case .rejected:
                // Phase 12 (12.00b.1, I2): the server will not take this
                // change on a retry. It leaves the remainder, so it can no
                // longer hold the queue; the coordinator sets it aside.
                // Unreachable (`classify` returns `.rejected` only for an HTTP
                // status), but a change is never dropped without one: keep it
                // queued (review fix round 1, M8).
                guard case let .http(statusCode) = response else {
                    remaining.append(item)
                    Self.appendUnique(item.table, to: &failedTables)
                    continue
                }
                Self.reportDiagnostic(stage: "rejected", table: item.table, statusCode: statusCode)
                rejected.append(NativeMutationRejection(item: item, statusCode: statusCode))
            case .transient:
                Self.reportResponse(response, table: item.table)
                remaining.append(item)
                Self.appendUnique(item.table, to: &failedTables)
            }
        }

        return NativeMutationPushOutcome(
            remaining: remaining,
            pushedCount: pushed,
            failedTables: failedTables,
            authRejected: authRejected,
            lastDiagnosticCode: Self.lastDiagnosticCode,
            rejected: rejected,
            forbiddenKeys: forbiddenKeys
        )
    }

    private func send(
        _ request: URLRequest,
        forbiddenBeforeRefresh: Bool
    ) async -> (NativeMutationPushResponseClass, NativeMutationPushResponse) {
        let response: NativeMutationPushResponse
        do {
            let (_, urlResponse) = try await loader.data(for: request)
            if let http = urlResponse as? HTTPURLResponse {
                response = .http(statusCode: http.statusCode)
            } else {
                response = .nonHTTP
            }
        } catch {
            response = .transportError
        }
        return (NativeMutationPushClassification.classify(response, forbiddenBeforeRefresh: forbiddenBeforeRefresh), response)
    }

    /// The bounded diagnostic for a failed (auth or transient) response.
    private static func reportResponse(_ response: NativeMutationPushResponse, table: String) {
        switch response {
        case .transportError: reportDiagnostic(stage: "transport", table: table)
        case .nonHTTP: reportDiagnostic(stage: "non-http-response", table: table)
        case let .http(statusCode): reportDiagnostic(stage: "http-response", table: table, statusCode: statusCode)
        }
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
        // Phase 12 12.00b.2-D (L286.1): every queued upsert passes here on its
        // way to the server, whichever producer queued it and whenever (a
        // queue file written by an earlier build included), so this is where
        // native-private keys (`Canonical.nativePrivateKeyPrefix`) are dropped:
        // at any depth, for every table. The queue and the rejected-change
        // store keep the payload as queued; both are local, and a Retry
        // pushes through here again. A delete sends a constant body.
        guard let payload = item.payload?.removingNativePrivateFields() else {
            throw NativeMutationPushError.malformedSession
        }
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
