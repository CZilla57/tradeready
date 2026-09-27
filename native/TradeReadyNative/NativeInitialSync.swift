import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum NativeInitialSyncError: LocalizedError, Equatable {
    case invalidConfiguration
    case malformedSession
    case rejectedSession
    case unavailable
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            "Cloud sync is not configured for this build."
        case .malformedSession, .rejectedSession:
            "Your sign-in needs to be refreshed before cloud data can load."
        case .unavailable:
            "Cloud data could not be loaded. Check your connection and try again."
        case .invalidResponse:
            "Cloud data could not be safely read. Your local data was not changed."
        }
    }
}

protocol NativeInitialSyncHTTPDataLoading {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: NativeInitialSyncHTTPDataLoading {}

protocol NativeInitialSyncServing {
    /// Returns one fully validated candidate snapshot. The caller owns the
    /// single atomic repository commit after the verified subject is rechecked.
    func pull(
        sessionBytes: Data,
        expectedUserSubject: String,
        localSnapshot: Canonical.Snapshot
    ) async throws -> Canonical.Snapshot

    /// Phase 12 final review (M3): the same full pull, plus the latest server
    /// `updated_at` it read per collection table. The initial sync saves no
    /// delta cursor, so these are the only record of how far the device has
    /// seen each table right after it; booking intake guards its stamp with
    /// them (`AppStore.intakeGuardWatermarks`). A table with no row has none.
    func pullWithWatermarks(
        sessionBytes: Data,
        expectedUserSubject: String,
        localSnapshot: Canonical.Snapshot
    ) async throws -> NativeInitialSyncPull
}

/// One full pull and its per-table watermarks (server `updated_at` strings).
struct NativeInitialSyncPull {
    var snapshot: Canonical.Snapshot
    var watermarks: [String: String]
}

extension NativeInitialSyncServing {
    /// A service that reports no watermarks (the host fakes): intake then
    /// falls back to the saved delta cursor alone.
    func pullWithWatermarks(
        sessionBytes: Data,
        expectedUserSubject: String,
        localSnapshot: Canonical.Snapshot
    ) async throws -> NativeInitialSyncPull {
        NativeInitialSyncPull(
            snapshot: try await pull(
                sessionBytes: sessionBytes, expectedUserSubject: expectedUserSubject, localSnapshot: localSnapshot
            ),
            watermarks: [:]
        )
    }
}

/// The outcome of one incremental delta pull: a validated candidate to commit,
/// the advanced per-table cursor, and any tables whose fetch was isolated as a
/// transient failure (their watermark is deliberately left unadvanced so the
/// next pass retries them). It carries no account identifiers or row values.
struct NativeDeltaPullOutcome {
    var snapshot: Canonical.Snapshot
    var cursor: Canonical.NativeSyncCursor
    var failedTables: [String]
    var lastDiagnosticCode: String?
}

protocol NativeDeltaSyncServing {
    /// Pulls only rows changed since each table's cursor watermark, merges them
    /// into `localSnapshot`, and returns the candidate plus the advanced cursor.
    /// An auth rejection throws `rejectedSession` so the caller can refresh and
    /// retry cleanly; every other single-table failure is isolated in
    /// `failedTables` without discarding the tables that did succeed.
    func pullDelta(
        sessionBytes: Data,
        expectedUserSubject: String,
        localSnapshot: Canonical.Snapshot,
        cursor: Canonical.NativeSyncCursor
    ) async throws -> NativeDeltaPullOutcome
}

/// Phase 3 bootstrap and Phase 4 incremental pull for the JSON-blob sync
/// contract. `pull` does the one-time full bootstrap; `pullDelta` does the
/// cursor-driven incremental refresh. Media transfer remains later Phase 4 work.
struct NativeSupabaseInitialSyncService: NativeInitialSyncServing, NativeDeltaSyncServing {
    private enum Collection: String, CaseIterable {
        case jobs
        case invoices
        case customers
        case expenses
        case pricebook
        case recurringJobs
        case recurringInvoices
        case trips
        case bookingRequests
        case jobPhotos
    }

    private struct StoredSession: Decodable {
        let accessToken: String

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
        }
    }

    private struct RemoteCollectionRow: Decodable {
        let id: String
        let userID: String
        let data: Canonical.JSONValue
        let deleted: Bool
        let updatedAt: String

        enum CodingKeys: String, CodingKey {
            case id, data, deleted
            case userID = "user_id"
            case updatedAt = "updated_at"
        }
    }

    private struct RemoteSettingsRow: Decodable {
        let userID: String
        let data: Canonical.JSONValue

        enum CodingKeys: String, CodingKey {
            case data
            case userID = "user_id"
        }
    }

    private struct RemoteNoteRow: Decodable {
        let userID: String
        let customerKey: String
        let note: String

        enum CodingKeys: String, CodingKey {
            case note
            case userID = "user_id"
            case customerKey = "customer_key"
        }
    }

    static let pageSize = 500
    private static let diagnosticDefaultsKey = "TradeReadyInitialSyncDiagnosticCode"

    /// The latest bounded failure code for the current initial-sync attempt.
    /// It contains no account identifiers, URLs, credentials, or row values.
    static var lastDiagnosticCode: String? {
        UserDefaults.standard.string(forKey: diagnosticDefaultsKey)
    }

    let supabaseURL: URL
    let publishableKey: String
    let loader: any NativeInitialSyncHTTPDataLoading

    init(
        supabaseURL: URL,
        publishableKey: String,
        loader: any NativeInitialSyncHTTPDataLoading = URLSession.shared
    ) {
        self.supabaseURL = supabaseURL
        self.publishableKey = publishableKey
        self.loader = loader
    }

    func pull(
        sessionBytes: Data,
        expectedUserSubject: String,
        localSnapshot: Canonical.Snapshot
    ) async throws -> Canonical.Snapshot {
        try await pullWithWatermarks(
            sessionBytes: sessionBytes, expectedUserSubject: expectedUserSubject, localSnapshot: localSnapshot
        ).snapshot
    }

    func pullWithWatermarks(
        sessionBytes: Data,
        expectedUserSubject: String,
        localSnapshot: Canonical.Snapshot
    ) async throws -> NativeInitialSyncPull {
        Self.clearDiagnostic()
        guard supabaseURL.scheme?.lowercased() == "https", supabaseURL.host != nil,
              !publishableKey.isEmpty, !expectedUserSubject.isEmpty
        else { throw NativeInitialSyncError.invalidConfiguration }

        let session: StoredSession
        do { session = try JSONDecoder().decode(StoredSession.self, from: sessionBytes) }
        catch { throw NativeInitialSyncError.malformedSession }
        guard !session.accessToken.isEmpty else { throw NativeInitialSyncError.malformedSession }

        // Every endpoint is drained and validated before the candidate is
        // returned. A later table failure therefore cannot pair a partial local
        // apply with an apparently completed initial-sync gate.
        var remoteCollections: [Collection: [RemoteCollectionRow]] = [:]
        for collection in Collection.allCases {
            do {
                remoteCollections[collection] = try await fetchCollection(
                    collection,
                    subject: expectedUserSubject,
                    accessToken: session.accessToken
                )
            } catch {
                Self.reportDiagnostic(stage: "collection-fetch", table: collection.rawValue)
                throw error
            }
        }
        let settingsRows: [RemoteSettingsRow] = try await fetchRows(
            table: "settings",
            select: "user_id,data",
            subject: expectedUserSubject,
            accessToken: session.accessToken,
            pageSize: 2
        )
        guard settingsRows.count <= 1,
              settingsRows.allSatisfy({ $0.userID == expectedUserSubject })
        else {
            Self.reportDiagnostic(stage: "row-contract", table: "settings")
            throw NativeInitialSyncError.invalidResponse
        }

        let noteRows: [RemoteNoteRow] = try await fetchAllRows(
            table: "customer_notes",
            select: "user_id,customer_key,note",
            subject: expectedUserSubject,
            accessToken: session.accessToken,
            order: "customer_key.asc"
        )
        guard noteRows.allSatisfy({ $0.userID == expectedUserSubject }) else {
            Self.reportDiagnostic(stage: "row-contract", table: "customer_notes")
            throw NativeInitialSyncError.invalidResponse
        }

        var candidate = localSnapshot
        var watermarks = Canonical.NativeSyncCursor.empty()
        for collection in Collection.allCases {
            for row in remoteCollections[collection] ?? [] {
                watermarks = watermarks.advancing(collection.rawValue, to: row.updatedAt)
            }
            do {
                try apply(
                    remoteCollections[collection] ?? [],
                    collection: collection,
                    to: &candidate.payload
                )
            } catch {
                Self.reportDiagnostic(stage: "canonical-apply", table: collection.rawValue)
                throw error
            }
        }
        if let remoteSettings = settingsRows.first?.data {
            do {
                candidate.payload.settings = try mergeSettings(
                    local: candidate.payload.settings,
                    remote: remoteSettings
                )
            } catch {
                Self.reportDiagnostic(stage: "canonical-apply", table: "settings")
                throw error
            }
        }
        if !noteRows.isEmpty {
            var notes = candidate.payload.customerNotes ?? [:]
            for row in noteRows { notes[row.customerKey] = row.note }
            candidate.payload.customerNotes = notes
        }
        candidate.schemaVersion = Canonical.Snapshot.currentSchemaVersion

        // Snapshot encoding is the credential scrub boundary. Decode the
        // scrubbed bytes again so provider credentials never remain in the
        // in-memory candidate returned to the app store either.
        do {
            return NativeInitialSyncPull(
                snapshot: try Canonical.SnapshotCodec.decode(Canonical.SnapshotCodec.encode(candidate)),
                watermarks: watermarks.tables
            )
        } catch {
            Self.reportDiagnostic(stage: "snapshot-validation")
            throw NativeInitialSyncError.invalidResponse
        }
    }

    /// Incremental pull: fetches only rows changed since each table's watermark,
    /// merges them with the identical logic the full pull uses, and returns the
    /// candidate plus an advanced cursor. Per-table transport, contract, and
    /// decode failures are isolated (the table's watermark is not advanced, so
    /// the next pass retries it) rather than discarding the tables that
    /// succeeded; an auth rejection throws so the caller can refresh and retry.
    /// Settings and customer notes have no per-table cursor — they are small and
    /// fully re-fetched each pass, exactly as the React Native client does.
    func pullDelta(
        sessionBytes: Data,
        expectedUserSubject: String,
        localSnapshot: Canonical.Snapshot,
        cursor: Canonical.NativeSyncCursor
    ) async throws -> NativeDeltaPullOutcome {
        Self.clearDiagnostic()
        guard supabaseURL.scheme?.lowercased() == "https", supabaseURL.host != nil,
              !publishableKey.isEmpty, !expectedUserSubject.isEmpty
        else { throw NativeInitialSyncError.invalidConfiguration }

        let session: StoredSession
        do { session = try JSONDecoder().decode(StoredSession.self, from: sessionBytes) }
        catch { throw NativeInitialSyncError.malformedSession }
        guard !session.accessToken.isEmpty else { throw NativeInitialSyncError.malformedSession }

        var candidate = localSnapshot
        var nextCursor = cursor
        var failedTables: [String] = []

        for collection in Collection.allCases {
            do {
                let rows = try await fetchCollection(
                    collection,
                    subject: expectedUserSubject,
                    accessToken: session.accessToken,
                    since: cursor.pullStart(for: collection.rawValue)
                )
                try apply(rows, collection: collection, to: &candidate.payload)
                for row in rows {
                    nextCursor = nextCursor.advancing(collection.rawValue, to: row.updatedAt)
                }
            } catch NativeInitialSyncError.rejectedSession {
                throw NativeInitialSyncError.rejectedSession
            } catch {
                Self.appendUnique(collection.rawValue, to: &failedTables)
            }
        }

        do {
            let settingsRows: [RemoteSettingsRow] = try await fetchRows(
                table: "settings",
                select: "user_id,data",
                subject: expectedUserSubject,
                accessToken: session.accessToken,
                pageSize: 2
            )
            guard settingsRows.count <= 1,
                  settingsRows.allSatisfy({ $0.userID == expectedUserSubject })
            else {
                Self.reportDiagnostic(stage: "row-contract", table: "settings")
                throw NativeInitialSyncError.invalidResponse
            }
            if let remoteSettings = settingsRows.first?.data {
                candidate.payload.settings = try mergeSettings(
                    local: candidate.payload.settings,
                    remote: remoteSettings
                )
            }
        } catch NativeInitialSyncError.rejectedSession {
            throw NativeInitialSyncError.rejectedSession
        } catch {
            Self.appendUnique("settings", to: &failedTables)
        }

        do {
            let noteRows: [RemoteNoteRow] = try await fetchAllRows(
                table: "customer_notes",
                select: "user_id,customer_key,note",
                subject: expectedUserSubject,
                accessToken: session.accessToken,
                order: "customer_key.asc"
            )
            guard noteRows.allSatisfy({ $0.userID == expectedUserSubject }) else {
                Self.reportDiagnostic(stage: "row-contract", table: "customer_notes")
                throw NativeInitialSyncError.invalidResponse
            }
            if !noteRows.isEmpty {
                var notes = candidate.payload.customerNotes ?? [:]
                for row in noteRows { notes[row.customerKey] = row.note }
                candidate.payload.customerNotes = notes
            }
        } catch NativeInitialSyncError.rejectedSession {
            throw NativeInitialSyncError.rejectedSession
        } catch {
            Self.appendUnique("customer_notes", to: &failedTables)
        }

        candidate.schemaVersion = Canonical.Snapshot.currentSchemaVersion

        // Snapshot encoding is the credential scrub boundary. Re-decode the
        // scrubbed bytes so provider credentials never remain in the candidate.
        let scrubbed: Canonical.Snapshot
        do {
            scrubbed = try Canonical.SnapshotCodec.decode(Canonical.SnapshotCodec.encode(candidate))
        } catch {
            Self.reportDiagnostic(stage: "snapshot-validation")
            throw NativeInitialSyncError.invalidResponse
        }

        return NativeDeltaPullOutcome(
            snapshot: scrubbed,
            cursor: nextCursor,
            failedTables: failedTables,
            lastDiagnosticCode: Self.lastDiagnosticCode
        )
    }

    private func fetchCollection(
        _ collection: Collection,
        subject: String,
        accessToken: String,
        since: String? = nil
    ) async throws -> [RemoteCollectionRow] {
        let filters = since.map { [URLQueryItem(name: "updated_at", value: "gte.\($0)")] } ?? []
        let rows: [RemoteCollectionRow] = try await fetchAllRows(
            table: collection.rawValue,
            select: "id,user_id,data,deleted,updated_at",
            subject: subject,
            accessToken: accessToken,
            order: "updated_at.asc,id.asc",
            additionalFilters: filters
        )
        guard rows.allSatisfy({ row in
            row.userID == subject && !row.id.isEmpty && !row.updatedAt.isEmpty
                && Self.recordID(in: row.data) == row.id
        }) else {
            Self.reportDiagnostic(stage: "row-contract", table: collection.rawValue)
            throw NativeInitialSyncError.invalidResponse
        }
        return rows
    }

    private func fetchAllRows<Row: Decodable>(
        table: String,
        select: String,
        subject: String,
        accessToken: String,
        order: String? = nil,
        additionalFilters: [URLQueryItem] = []
    ) async throws -> [Row] {
        var offset = 0
        var result: [Row] = []
        while true {
            let page: [Row] = try await fetchRows(
                table: table,
                select: select,
                subject: subject,
                accessToken: accessToken,
                pageSize: Self.pageSize,
                offset: offset,
                order: order,
                additionalFilters: additionalFilters
            )
            result.append(contentsOf: page)
            guard page.count == Self.pageSize else { return result }
            offset += page.count
        }
    }

    private func fetchRows<Row: Decodable>(
        table: String,
        select: String,
        subject: String,
        accessToken: String,
        pageSize: Int,
        offset: Int = 0,
        order: String? = nil,
        additionalFilters: [URLQueryItem] = []
    ) async throws -> [Row] {
        guard var components = URLComponents(
            url: supabaseURL.appending(path: "rest/v1/\(table)"),
            resolvingAgainstBaseURL: false
        ) else { throw NativeInitialSyncError.invalidConfiguration }
        var items = [
            URLQueryItem(name: "select", value: select),
            URLQueryItem(name: "user_id", value: "eq.\(subject)"),
            URLQueryItem(name: "limit", value: String(pageSize)),
            URLQueryItem(name: "offset", value: String(offset))
        ]
        items.append(contentsOf: additionalFilters)
        if let order { items.append(URLQueryItem(name: "order", value: order)) }
        components.queryItems = items
        guard let url = components.url else { throw NativeInitialSyncError.invalidConfiguration }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do { (data, response) = try await loader.data(for: request) }
        catch {
            Self.reportDiagnostic(stage: "transport", table: table)
            throw NativeInitialSyncError.unavailable
        }
        guard let http = response as? HTTPURLResponse else {
            Self.reportDiagnostic(stage: "non-http-response", table: table)
            throw NativeInitialSyncError.unavailable
        }
        guard (200..<300).contains(http.statusCode) else {
            Self.reportDiagnostic(stage: "http-response", table: table, statusCode: http.statusCode)
            if http.statusCode == 401 || http.statusCode == 403 {
                throw NativeInitialSyncError.rejectedSession
            }
            throw NativeInitialSyncError.unavailable
        }
        do { return try JSONDecoder().decode([Row].self, from: data) }
        catch {
            Self.reportDiagnostic(stage: "wire-decode", table: table)
            throw NativeInitialSyncError.invalidResponse
        }
    }

    private func apply(
        _ rows: [RemoteCollectionRow],
        collection: Collection,
        to payload: inout Canonical.SnapshotPayload
    ) throws {
        switch collection {
        case .jobs:
            payload.jobs = try merge(payload.jobs, rows: rows, id: \.id)
        case .invoices:
            payload.invoices = try merge(
                payload.invoices,
                rows: rows,
                id: \.id,
                combine: Self.mergeInvoice
            )
        case .customers:
            payload.customers = try merge(payload.customers, rows: rows, id: \.id)
        case .expenses:
            payload.expenses = try merge(payload.expenses, rows: rows, id: \.id)
        case .pricebook:
            payload.pricebook = try merge(payload.pricebook, rows: rows, id: \.id)
        case .recurringJobs:
            payload.recurringJobs = try merge(payload.recurringJobs, rows: rows, id: \.id)
        case .recurringInvoices:
            payload.recurringInvoices = try merge(payload.recurringInvoices, rows: rows, id: \.id)
        case .trips:
            payload.trips = try merge(payload.trips, rows: rows, id: \.id)
        case .bookingRequests:
            payload.bookingRequests = try merge(
                payload.bookingRequests,
                rows: rows,
                id: \.id,
                combine: Self.mergeBookingRequest
            )
        case .jobPhotos:
            payload.jobPhotos = try merge(payload.jobPhotos, rows: rows, id: \.id)
        }
    }

    private func merge<Record: Codable>(
        _ local: [Record]?,
        rows: [RemoteCollectionRow],
        id: KeyPath<Record, String>,
        combine: (Record?, Record) throws -> Record = { _, remote in remote }
    ) throws -> [Record]? {
        guard !rows.isEmpty else { return local }
        var records = local ?? []
        for row in rows {
            if row.deleted {
                records.removeAll { $0[keyPath: id] == row.id }
                continue
            }
            let remote: Record
            do { remote = try Self.decode(Record.self, from: row.data) }
            catch { throw NativeInitialSyncError.invalidResponse }
            guard remote[keyPath: id] == row.id else {
                throw NativeInitialSyncError.invalidResponse
            }
            if let index = records.firstIndex(where: { $0[keyPath: id] == row.id }) {
                records[index] = try combine(records[index], remote)
            } else {
                records.append(try combine(nil, remote))
            }
        }
        return records
    }

    private func mergeSettings(
        local: Canonical.Settings?,
        remote: Canonical.JSONValue
    ) throws -> Canonical.Settings {
        guard case let .object(remoteFields) = remote else {
            throw NativeInitialSyncError.invalidResponse
        }
        var fields: [String: Canonical.JSONValue]
        if let local,
           case let .object(localFields) = try Self.wrap(local)
        {
            fields = localFields
        } else {
            fields = [:]
        }
        for (key, value) in remoteFields { fields[key] = value }
        for key in Canonical.SnapshotCodec.secureSettingsKeys {
            fields.removeValue(forKey: key)
        }
        do { return try Self.decode(Canonical.Settings.self, from: .object(fields)) }
        catch { throw NativeInitialSyncError.invalidResponse }
    }

    private static func mergeInvoice(
        local: Canonical.Invoice?,
        remote: Canonical.Invoice
    ) throws -> Canonical.Invoice {
        guard let local else { return reconcilePaidFields(remote) }
        var byID: [String: Canonical.Payment] = [:]
        for payment in try effectivePayments(local) { byID[payment.id] = payment }
        for incoming in try effectivePayments(remote) {
            guard let existing = byID[incoming.id] else {
                byID[incoming.id] = incoming
                continue
            }
            if let existingVoid = existing.voidedAt, let incomingVoid = incoming.voidedAt {
                byID[incoming.id] = existingVoid < incomingVoid ? existing : incoming
            } else if existing.voidedAt != nil {
                byID[incoming.id] = existing
            } else {
                byID[incoming.id] = incoming
            }
        }
        var next = remote
        next.payments = byID.values.sorted {
            $0.date == $1.date ? $0.id < $1.id : $0.date < $1.date
        }
        return reconcilePaidFields(next)
    }

    private static func effectivePayments(_ invoice: Canonical.Invoice) throws -> [Canonical.Payment] {
        if let payments = invoice.payments, !payments.isEmpty { return payments }
        guard invoice.paid else { return [] }
        return [try decode(Canonical.Payment.self, from: .object([
            "id": .string("legacy_\(invoice.id)"),
            "amount": .number(invoice.amount),
            "date": .string(invoice.paidAt ?? invoice.due),
            "method": .string("other"),
            "note": .string("Recorded before payment history was itemised")
        ]))]
    }

    private static func reconcilePaidFields(_ invoice: Canonical.Invoice) -> Canonical.Invoice {
        guard let payments = invoice.payments, !payments.isEmpty else { return invoice }
        var next = invoice
        let collected = payments.reduce(Decimal.zero) {
            $0 + ($1.voidedAt == nil ? $1.amount : 0)
        }
        let settled = invoice.amount - collected <= Decimal(string: "0.005")!
        next.paid = settled
        guard settled else {
            next.paidAt = nil
            return next
        }
        let chronological = payments.sorted {
            $0.date == $1.date ? $0.id < $1.id : $0.date < $1.date
        }
        var running = Decimal.zero
        var closingDate = chronological.last?.date
        for payment in chronological where payment.voidedAt == nil {
            running += payment.amount
            if running >= invoice.amount - Decimal(string: "0.005")! {
                closingDate = payment.date
                break
            }
        }
        next.paidAt = closingDate
        return next
    }

    private static func mergeBookingRequest(
        local: Canonical.BookingRequest?,
        remote: Canonical.BookingRequest
    ) throws -> Canonical.BookingRequest {
        guard let local else { return remote }
        let localHistory = local.history ?? []
        guard !localHistory.isEmpty else { return remote }
        var next = remote
        var history = remote.history ?? []
        var keys = Set(history.map { "\($0.at)|\($0.actor)|\($0.event)" })
        for entry in localHistory {
            let key = "\(entry.at)|\(entry.actor)|\(entry.event)"
            if keys.insert(key).inserted { history.append(entry) }
        }
        next.history = history.enumerated().sorted {
            $0.element.at == $1.element.at
                ? $0.offset < $1.offset
                : $0.element.at < $1.element.at
        }.map(\.element)
        return next
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
    /// never include URLs, subjects, tokens, response bodies, or row values.
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
        print("TradeReadyInitialSync stage=\(stage) table=\(tableValue) status=\(statusValue)")
    }

    static func clearDiagnostic() {
        UserDefaults.standard.removeObject(forKey: diagnosticDefaultsKey)
    }

    private static func decode<T: Decodable>(
        _ type: T.Type,
        from value: Canonical.JSONValue
    ) throws -> T {
        try JSONDecoder().decode(type, from: JSONEncoder().encode(value))
    }

    private static func wrap<T: Encodable>(_ value: T) throws -> Canonical.JSONValue {
        try JSONDecoder().decode(Canonical.JSONValue.self, from: JSONEncoder().encode(value))
    }
}

// MARK: - Phase 12 (12.00b.1, I2): one record, for Discard

/// What the server holds for one record.
enum NativeServerRecord: Equatable {
    /// The live row's data: a collection record, the settings blob, or a
    /// customer note's text (`.string`).
    case present(Canonical.JSONValue)
    /// No row, or a tombstone.
    case absent
}

/// Discard (owner decision D3) replaces this device's copy of one refused
/// record with the server's current version. A targeted fetch of that one
/// record, not a cursor rewind: it costs one request, returns exactly the
/// server's row, and tells "the server has no such record" (a refused
/// insert) apart from "the row did not change" — a rewind refetches the
/// whole table and still cannot see an absent row.
protocol NativeServerRecordFetching {
    /// The server's current row for `table`/`recordId`, owner-checked like
    /// the delta pull. An auth rejection throws `rejectedSession`.
    func fetchServerRecord(
        table: String,
        recordId: String,
        sessionBytes: Data,
        expectedUserSubject: String
    ) async throws -> NativeServerRecord

    /// `snapshot` with that one record replaced by the server's version:
    /// taken exactly (an invoice's local payments are not merged in), or
    /// removed when the server has none. Settings the server lacks stay
    /// local (the pull does the same). The result passes the snapshot codec
    /// (the credential scrub), like every pull candidate.
    func applyingServerRecord(
        _ record: NativeServerRecord,
        table: String,
        recordId: String,
        to snapshot: Canonical.Snapshot
    ) throws -> Canonical.Snapshot
}

extension NativeSupabaseInitialSyncService: NativeServerRecordFetching {
    func fetchServerRecord(
        table: String,
        recordId: String,
        sessionBytes: Data,
        expectedUserSubject: String
    ) async throws -> NativeServerRecord {
        guard supabaseURL.scheme?.lowercased() == "https", supabaseURL.host != nil,
              !publishableKey.isEmpty, !expectedUserSubject.isEmpty, !recordId.isEmpty
        else { throw NativeInitialSyncError.invalidConfiguration }
        let session: StoredSession
        do { session = try JSONDecoder().decode(StoredSession.self, from: sessionBytes) }
        catch { throw NativeInitialSyncError.malformedSession }
        guard !session.accessToken.isEmpty else { throw NativeInitialSyncError.malformedSession }
        let subject = expectedUserSubject

        if Collection(rawValue: table) != nil {
            let rows: [RemoteCollectionRow] = try await fetchRows(
                table: table,
                select: "id,user_id,data,deleted,updated_at",
                subject: subject,
                accessToken: session.accessToken,
                pageSize: 2,
                additionalFilters: [URLQueryItem(name: "id", value: "eq.\(recordId)")]
            )
            guard rows.count <= 1, rows.allSatisfy({ row in
                row.userID == subject && row.id == recordId && Self.recordID(in: row.data) == recordId
            }) else {
                Self.reportDiagnostic(stage: "row-contract", table: table)
                throw NativeInitialSyncError.invalidResponse
            }
            guard let row = rows.first, !row.deleted else { return .absent }
            return .present(row.data)
        }
        switch table {
        case "settings":
            let rows: [RemoteSettingsRow] = try await fetchRows(
                table: "settings",
                select: "user_id,data",
                subject: subject,
                accessToken: session.accessToken,
                pageSize: 2
            )
            guard rows.count <= 1, rows.allSatisfy({ $0.userID == subject }) else {
                Self.reportDiagnostic(stage: "row-contract", table: "settings")
                throw NativeInitialSyncError.invalidResponse
            }
            return rows.first.map { .present($0.data) } ?? .absent
        case "customer_notes":
            let rows: [RemoteNoteRow] = try await fetchRows(
                table: "customer_notes",
                select: "user_id,customer_key,note",
                subject: subject,
                accessToken: session.accessToken,
                pageSize: 2,
                additionalFilters: [URLQueryItem(name: "customer_key", value: "eq.\(recordId)")]
            )
            guard rows.count <= 1, rows.allSatisfy({ $0.userID == subject && $0.customerKey == recordId }) else {
                Self.reportDiagnostic(stage: "row-contract", table: "customer_notes")
                throw NativeInitialSyncError.invalidResponse
            }
            return rows.first.map { .present(.string($0.note)) } ?? .absent
        default:
            throw NativeInitialSyncError.invalidConfiguration
        }
    }

    func applyingServerRecord(
        _ record: NativeServerRecord,
        table: String,
        recordId: String,
        to snapshot: Canonical.Snapshot
    ) throws -> Canonical.Snapshot {
        var candidate = snapshot
        if let collection = Collection(rawValue: table) {
            try replace(record, recordId: recordId, collection: collection, in: &candidate.payload)
        } else if table == "settings" {
            if case let .present(data) = record {
                candidate.payload.settings = try mergeSettings(local: candidate.payload.settings, remote: data)
            }
        } else if table == "customer_notes" {
            switch record {
            case let .present(.string(note)):
                var notes = candidate.payload.customerNotes ?? [:]
                notes[recordId] = note
                candidate.payload.customerNotes = notes
            case .present:
                throw NativeInitialSyncError.invalidResponse
            case .absent:
                if candidate.payload.customerNotes?[recordId] != nil {
                    candidate.payload.customerNotes?.removeValue(forKey: recordId)
                }
            }
        } else {
            throw NativeInitialSyncError.invalidResponse
        }
        candidate.schemaVersion = Canonical.Snapshot.currentSchemaVersion
        do {
            return try Canonical.SnapshotCodec.decode(Canonical.SnapshotCodec.encode(candidate))
        } catch {
            throw NativeInitialSyncError.invalidResponse
        }
    }

    private func replace(
        _ record: NativeServerRecord,
        recordId: String,
        collection: Collection,
        in payload: inout Canonical.SnapshotPayload
    ) throws {
        switch collection {
        case .jobs: payload.jobs = try replacing(payload.jobs, record, recordId, \.id)
        case .invoices:
            // The server's invoice exactly: `mergeInvoice` with no local copy
            // only reconciles its own paid fields.
            payload.invoices = try replacing(payload.invoices, record, recordId, \.id) {
                try Self.mergeInvoice(local: nil, remote: $0)
            }
        case .customers: payload.customers = try replacing(payload.customers, record, recordId, \.id)
        case .expenses: payload.expenses = try replacing(payload.expenses, record, recordId, \.id)
        case .pricebook: payload.pricebook = try replacing(payload.pricebook, record, recordId, \.id)
        case .recurringJobs: payload.recurringJobs = try replacing(payload.recurringJobs, record, recordId, \.id)
        case .recurringInvoices:
            payload.recurringInvoices = try replacing(payload.recurringInvoices, record, recordId, \.id)
        case .trips: payload.trips = try replacing(payload.trips, record, recordId, \.id)
        case .bookingRequests:
            payload.bookingRequests = try replacing(payload.bookingRequests, record, recordId, \.id) {
                try Self.mergeBookingRequest(local: nil, remote: $0)
            }
        case .jobPhotos: payload.jobPhotos = try replacing(payload.jobPhotos, record, recordId, \.id)
        }
    }

    private func replacing<Record: Codable>(
        _ local: [Record]?,
        _ record: NativeServerRecord,
        _ recordId: String,
        _ id: KeyPath<Record, String>,
        server: (Record) throws -> Record = { $0 }
    ) throws -> [Record]? {
        var records = local ?? []
        switch record {
        case .absent:
            guard records.contains(where: { $0[keyPath: id] == recordId }) else { return local }
            records.removeAll { $0[keyPath: id] == recordId }
        case let .present(data):
            let remote: Record
            do { remote = try Self.decode(Record.self, from: data) }
            catch { throw NativeInitialSyncError.invalidResponse }
            guard remote[keyPath: id] == recordId else { throw NativeInitialSyncError.invalidResponse }
            let value = try server(remote)
            if let index = records.firstIndex(where: { $0[keyPath: id] == recordId }) {
                records[index] = value
            } else {
                records.append(value)
            }
        }
        return records
    }
}
