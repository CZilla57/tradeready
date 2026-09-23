import Foundation

struct NativeCustomerListEntry: Identifiable {
    let id: String
    var name: String
    var email: String
    var phone: String
    var notes: String?
    var archivedAt: String?
    var invoices: [Invoice]
    var totalSpent: Double
    var totalOwed: Double
    let isManual: Bool

    var isArchived: Bool {
        !(archivedAt ?? "").isEmpty
    }
}

enum NativeCustomerDuplicateReason: String, Equatable {
    case name, phone, email
}

struct NativeCustomerDuplicatePair {
    let a: Customer
    let b: Customer
    let reason: NativeCustomerDuplicateReason
    let key: String
}

struct NativeInvoiceContactBackfill {
    let invoices: [Invoice]
    let changed: Bool
}

enum NativeCustomerEditorSaveIssue: Equatable {
    case nameRequired
    case duplicateName(existingID: String, existingName: String)
    case persistenceFailed
}

enum NativeCustomerEditorMode {
    case create
    case editOrPromote
}

struct NativeCustomerEditorSavePlan {
    let customer: Customer
    let issue: NativeCustomerEditorSaveIssue?

    var canSave: Bool { issue == nil }
}

/// Pure customer-detail action builders. They keep UI presentation separate
/// from identity/persistence choices and make invoice-derived promotion
/// explicit instead of silently mutating historical invoices.
enum NativeCustomerDetailActions {
    static func invoiceDraft(
        for customer: NativeCustomerListEntry,
        storedCustomer: Customer?,
        number: String,
        due: Date
    ) -> Invoice {
        Invoice(
            customerId: storedCustomer?.id ?? "",
            customer: customer.name,
            number: number,
            due: due,
            email: customer.email,
            phone: customer.phone
        )
    }

    static func customerSavingNotes(
        _ notes: String,
        for customer: NativeCustomerListEntry,
        storedCustomer: Customer?
    ) -> Customer {
        var record = storedCustomer ?? Customer(
            name: customer.name,
            email: customer.email,
            phone: customer.phone
        )
        record.notes = notes
        return record
    }
}

enum NativeCustomerMergeError: Error, Equatable {
    case sameCustomer
    case winnerNotFound
    case loserNotFound
    case undoConflict
}

struct NativeCustomerMergeCounts: Equatable {
    var jobs = 0
    var invoices = 0
    var recurringJobs = 0
    var recurringInvoices = 0

    var total: Int { jobs + invoices + recurringJobs + recurringInvoices }
}

struct NativeCustomerMergeUndo: Identifiable {
    fileprivate struct Records {
        let winner: Canonical.Customer
        let loser: Canonical.Customer
        let loserIndex: Int
        let jobs: [Canonical.Job]
        let invoices: [Canonical.Invoice]
        let recurringJobs: [Canonical.RecurringJob]
        let recurringInvoices: [Canonical.RecurringInvoice]
    }

    let id = UUID()
    let winnerName: String
    let loserName: String
    let counts: NativeCustomerMergeCounts
    fileprivate let before: Records
    fileprivate let after: Records
}

struct NativeCustomerMergeResult {
    let snapshot: Canonical.Snapshot
    let undo: NativeCustomerMergeUndo
    let mutations: [Canonical.MutationDraft]
}

/// Pure Phase 5 identity and rollup rules ported from the React Native customer
/// utilities. Mutation is deliberately deferred to an AppStore transaction so
/// canonical baselines, unknown fields, and sync-queue writes stay coordinated.
enum NativeCustomerIdentity {
    static func normalizedName(_ value: String?) -> String {
        (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Mirrors AddCustomerScreen's save boundary rather than the broader,
    /// advisory duplicate banner. A new canonical record is blocked only when
    /// its trimmed, case-insensitive name already exists. Existing records may
    /// still be edited into a possible duplicate and reviewed through merge.
    /// The returned copy is trimmed for persistence while a rejected editor
    /// keeps its original draft untouched.
    static func editorSavePlan(
        for candidate: Customer,
        existingCustomers: [Customer],
        mode: NativeCustomerEditorMode
    ) -> NativeCustomerEditorSavePlan {
        var prepared = candidate
        prepared.name = candidate.name.trimmingCharacters(in: .whitespacesAndNewlines)
        prepared.phone = candidate.phone.trimmingCharacters(in: .whitespacesAndNewlines)
        prepared.email = candidate.email.trimmingCharacters(in: .whitespacesAndNewlines)
        prepared.address = candidate.address.trimmingCharacters(in: .whitespacesAndNewlines)
        prepared.notes = candidate.notes.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !prepared.name.isEmpty else {
            return .init(customer: prepared, issue: .nameRequired)
        }

        if mode == .create,
           let duplicate = existingCustomers.first(where: {
               normalizedName($0.name) == normalizedName(prepared.name)
           }) {
            return .init(
                customer: prepared,
                issue: .duplicateName(existingID: duplicate.id, existingName: duplicate.name)
            )
        }

        return .init(customer: prepared, issue: nil)
    }

    static func resolve(
        customers: [Customer],
        customerID: String?,
        customerName: String?
    ) -> Customer? {
        if let customerID, !customerID.isEmpty,
           let exact = customers.first(where: { $0.id == customerID }) {
            return exact
        }
        let key = normalizedName(customerName)
        guard !key.isEmpty else { return nil }
        return customers.first { normalizedName($0.name) == key }
    }

    static func buildList(invoices: [Invoice], customers: [Customer]) -> [NativeCustomerListEntry] {
        var entries: [String: NativeCustomerListEntry] = [:]
        var insertionOrder: [String] = []
        var idByName: [String: String] = [:]

        for customer in customers where !customer.id.isEmpty {
            if entries[customer.id] == nil { insertionOrder.append(customer.id) }
            entries[customer.id] = NativeCustomerListEntry(
                id: customer.id,
                name: customer.name.trimmingCharacters(in: .whitespacesAndNewlines),
                email: customer.email,
                phone: customer.phone,
                notes: customer.notes,
                archivedAt: customer.archivedAt,
                invoices: [],
                totalSpent: 0,
                totalOwed: 0,
                isManual: true
            )
            let key = normalizedName(customer.name)
            if !key.isEmpty { idByName[key] = customer.id }
        }

        for invoice in invoices {
            let nameKey = normalizedName(invoice.customer)
            var id = invoice.customerId
            if id.isEmpty, let matched = idByName[nameKey] { id = matched }
            if id.isEmpty {
                guard !nameKey.isEmpty else { continue }
                id = nameKey
                idByName[nameKey] = id
            }

            if entries[id] == nil {
                insertionOrder.append(id)
                entries[id] = NativeCustomerListEntry(
                    id: id,
                    name: invoice.customer.trimmingCharacters(in: .whitespacesAndNewlines),
                    email: invoice.email,
                    phone: invoice.phone,
                    notes: nil,
                    archivedAt: nil,
                    invoices: [],
                    totalSpent: 0,
                    totalOwed: 0,
                    isManual: false
                )
            }

            guard var entry = entries[id] else { continue }
            entry.invoices.append(invoice)
            entry.totalSpent += invoice.amountPaid
            entry.totalOwed += invoice.balance
            if !invoice.email.isEmpty { entry.email = invoice.email }
            if !invoice.phone.isEmpty { entry.phone = invoice.phone }
            entries[id] = entry
        }

        let order = Dictionary(uniqueKeysWithValues: insertionOrder.enumerated().map { ($1, $0) })
        return insertionOrder.compactMap { entries[$0] }.sorted {
            if $0.totalSpent != $1.totalSpent { return $0.totalSpent > $1.totalSpent }
            return (order[$0.id] ?? 0) < (order[$1.id] ?? 0)
        }
    }

    static func backfillInvoiceContacts(
        invoices: [Invoice],
        customers: [Customer]
    ) -> NativeInvoiceContactBackfill {
        let byID = Dictionary(customers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var byName: [String: Customer] = [:]
        for customer in customers {
            let key = normalizedName(customer.name)
            if !key.isEmpty, byName[key] == nil { byName[key] = customer }
        }

        var changed = false
        let result = invoices.map { invoice -> Invoice in
            let customer = (!invoice.customerId.isEmpty ? byID[invoice.customerId] : nil)
                ?? byName[normalizedName(invoice.customer)]
            guard let customer else { return invoice }

            var updated = invoice
            if updated.email.isEmpty, !customer.email.isEmpty { updated.email = customer.email }
            if updated.phone.isEmpty, !customer.phone.isEmpty { updated.phone = customer.phone }
            if updated != invoice { changed = true }
            return updated
        }
        return .init(invoices: result, changed: changed)
    }

    static func pairKey(_ firstID: String, _ secondID: String) -> String {
        firstID < secondID ? "\(firstID)|\(secondID)" : "\(secondID)|\(firstID)"
    }

    static func isArchived(_ customer: Customer) -> Bool {
        !(customer.archivedAt ?? "").isEmpty
    }

    static func duplicatePairs(in customers: [Customer]) -> [NativeCustomerDuplicatePair] {
        let active = customers.filter { !$0.id.isEmpty && !isArchived($0) }
        var pairs: [NativeCustomerDuplicatePair] = []
        guard active.count > 1 else { return pairs }

        for firstIndex in 0..<(active.count - 1) {
            for secondIndex in (firstIndex + 1)..<active.count {
                let a = active[firstIndex]
                let b = active[secondIndex]
                guard let reason = duplicateReason(a, b) else { continue }
                pairs.append(.init(a: a, b: b, reason: reason, key: pairKey(a.id, b.id)))
            }
        }
        return pairs
    }

    static func filterUndismissed(
        _ pairs: [NativeCustomerDuplicatePair],
        dismissedKeys: some Sequence<String>
    ) -> [NativeCustomerDuplicatePair] {
        let dismissed = Set(dismissedKeys)
        return pairs.filter { !dismissed.contains($0.key) }
    }

    /// Applies the React Native winner/loser merge contract directly to the
    /// loss-preserving canonical records. Only blank winner contact fields are
    /// backfilled, loser references are re-pointed across all four dependent
    /// collections, and every record's preservation metadata stays attached.
    static func merge(
        snapshot source: Canonical.Snapshot,
        winnerID: String,
        loserID: String
    ) throws -> NativeCustomerMergeResult {
        guard winnerID != loserID else { throw NativeCustomerMergeError.sameCustomer }
        let customers = source.payload.customers ?? []
        guard let winnerIndex = customers.firstIndex(where: { $0.id == winnerID })
        else { throw NativeCustomerMergeError.winnerNotFound }
        guard let loserIndex = customers.firstIndex(where: { $0.id == loserID })
        else { throw NativeCustomerMergeError.loserNotFound }

        let winnerBefore = customers[winnerIndex]
        let loserBefore = customers[loserIndex]
        let loserNameKey = normalizedName(loserBefore.name)
        var winnerAfter = winnerBefore
        if isBlank(winnerAfter.email), !isBlank(loserBefore.email) {
            winnerAfter.email = loserBefore.email
        }
        if isBlank(winnerAfter.phone), !isBlank(loserBefore.phone) {
            winnerAfter.phone = loserBefore.phone
        }
        if isBlank(winnerAfter.address), !isBlank(loserBefore.address) {
            winnerAfter.address = loserBefore.address
        }
        let winnerNotes = winnerBefore.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let loserNotes = loserBefore.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !loserNotes.isEmpty, loserNotes != winnerNotes {
            winnerAfter.notes = winnerNotes.isEmpty ? loserNotes : "\(winnerNotes)\n\n\(loserNotes)"
        }
        if let loserCreatedAt = loserBefore.createdAt,
           winnerAfter.createdAt == nil || loserCreatedAt < winnerAfter.createdAt! {
            winnerAfter.createdAt = loserCreatedAt
        }

        var result = source
        var mergedCustomers = customers
        mergedCustomers[winnerIndex] = winnerAfter
        mergedCustomers.remove(at: loserIndex)
        result.payload.customers = mergedCustomers

        let jobsBefore = (source.payload.jobs ?? []).filter {
            belongsToLoser(id: $0.customerId, name: $0.customerName, loserID: loserID, loserNameKey: loserNameKey)
        }
        result.payload.jobs = source.payload.jobs?.map { record in
            guard belongsToLoser(
                id: record.customerId,
                name: record.customerName,
                loserID: loserID,
                loserNameKey: loserNameKey
            ) else { return record }
            var updated = record
            updated.customerId = winnerID
            updated.customerName = winnerBefore.name
            return updated
        }

        let invoicesBefore = (source.payload.invoices ?? []).filter {
            belongsToLoser(id: $0.customerId, name: $0.customer, loserID: loserID, loserNameKey: loserNameKey)
        }
        result.payload.invoices = source.payload.invoices?.map { record in
            guard belongsToLoser(
                id: record.customerId,
                name: record.customer,
                loserID: loserID,
                loserNameKey: loserNameKey
            ) else { return record }
            var updated = record
            updated.customerId = winnerID
            updated.customer = winnerBefore.name
            return updated
        }

        let recurringJobsBefore = (source.payload.recurringJobs ?? []).filter {
            belongsToLoser(id: $0.customerId, name: $0.customerName, loserID: loserID, loserNameKey: loserNameKey)
        }
        result.payload.recurringJobs = source.payload.recurringJobs?.map { record in
            guard belongsToLoser(
                id: record.customerId,
                name: record.customerName,
                loserID: loserID,
                loserNameKey: loserNameKey
            ) else { return record }
            var updated = record
            updated.customerId = winnerID
            updated.customerName = winnerBefore.name
            return updated
        }

        let recurringInvoicesBefore = (source.payload.recurringInvoices ?? []).filter {
            belongsToLoser(id: $0.customerId, name: $0.customerName, loserID: loserID, loserNameKey: loserNameKey)
        }
        result.payload.recurringInvoices = source.payload.recurringInvoices?.map { record in
            guard belongsToLoser(
                id: record.customerId,
                name: record.customerName,
                loserID: loserID,
                loserNameKey: loserNameKey
            ) else { return record }
            var updated = record
            updated.customerId = winnerID
            updated.customerName = winnerBefore.name
            return updated
        }

        let jobsAfter = records(withIDs: jobsBefore.map(\.id), in: result.payload.jobs ?? [], id: \.id)
        let invoicesAfter = records(withIDs: invoicesBefore.map(\.id), in: result.payload.invoices ?? [], id: \.id)
        let recurringJobsAfter = records(
            withIDs: recurringJobsBefore.map(\.id),
            in: result.payload.recurringJobs ?? [],
            id: \.id
        )
        let recurringInvoicesAfter = records(
            withIDs: recurringInvoicesBefore.map(\.id),
            in: result.payload.recurringInvoices ?? [],
            id: \.id
        )
        let counts = NativeCustomerMergeCounts(
            jobs: jobsAfter.count,
            invoices: invoicesAfter.count,
            recurringJobs: recurringJobsAfter.count,
            recurringInvoices: recurringInvoicesAfter.count
        )
        let undo = NativeCustomerMergeUndo(
            winnerName: winnerBefore.name,
            loserName: loserBefore.name,
            counts: counts,
            before: .init(
                winner: winnerBefore,
                loser: loserBefore,
                loserIndex: loserIndex,
                jobs: jobsBefore,
                invoices: invoicesBefore,
                recurringJobs: recurringJobsBefore,
                recurringInvoices: recurringInvoicesBefore
            ),
            after: .init(
                winner: winnerAfter,
                loser: loserBefore,
                loserIndex: loserIndex,
                jobs: jobsAfter,
                invoices: invoicesAfter,
                recurringJobs: recurringJobsAfter,
                recurringInvoices: recurringInvoicesAfter
            )
        )

        var mutations = [
            try mutation(table: "customers", op: .upsert, record: winnerAfter, id: winnerID),
            Canonical.MutationDraft(table: "customers", op: .delete, recordId: loserID, payload: nil)
        ]
        mutations += try jobsAfter.map { try mutation(table: "jobs", op: .upsert, record: $0, id: $0.id) }
        mutations += try invoicesAfter.map { try mutation(table: "invoices", op: .upsert, record: $0, id: $0.id) }
        mutations += try recurringJobsAfter.map {
            try mutation(table: "recurringJobs", op: .upsert, record: $0, id: $0.id)
        }
        mutations += try recurringInvoicesAfter.map {
            try mutation(table: "recurringInvoices", op: .upsert, record: $0, id: $0.id)
        }
        return .init(snapshot: result, undo: undo, mutations: mutations)
    }

    /// Restores only the records touched by `merge`. Exact post-merge wire
    /// equality is required first, so Undo cannot clobber a later local edit or
    /// a row that arrived from another device during the undo window.
    static func undo(
        snapshot source: Canonical.Snapshot,
        token: NativeCustomerMergeUndo
    ) throws -> NativeCustomerMergeResult {
        var result = source
        var customers = source.payload.customers ?? []
        guard let winnerIndex = customers.firstIndex(where: { $0.id == token.before.winner.id }),
              wireEqual(customers[winnerIndex], token.after.winner),
              !customers.contains(where: { $0.id == token.before.loser.id })
        else { throw NativeCustomerMergeError.undoConflict }
        customers[winnerIndex] = token.before.winner
        customers.insert(token.before.loser, at: min(token.before.loserIndex, customers.count))
        result.payload.customers = customers

        try restore(
            token.before.jobs,
            expected: token.after.jobs,
            in: &result.payload.jobs,
            id: \.id
        )
        try restore(
            token.before.invoices,
            expected: token.after.invoices,
            in: &result.payload.invoices,
            id: \.id
        )
        try restore(
            token.before.recurringJobs,
            expected: token.after.recurringJobs,
            in: &result.payload.recurringJobs,
            id: \.id
        )
        try restore(
            token.before.recurringInvoices,
            expected: token.after.recurringInvoices,
            in: &result.payload.recurringInvoices,
            id: \.id
        )

        var mutations = [
            try mutation(
                table: "customers", op: .upsert,
                record: token.before.winner, id: token.before.winner.id
            ),
            try mutation(
                table: "customers", op: .upsert,
                record: token.before.loser, id: token.before.loser.id
            )
        ]
        mutations += try token.before.jobs.map {
            try mutation(table: "jobs", op: .upsert, record: $0, id: $0.id)
        }
        mutations += try token.before.invoices.map {
            try mutation(table: "invoices", op: .upsert, record: $0, id: $0.id)
        }
        mutations += try token.before.recurringJobs.map {
            try mutation(table: "recurringJobs", op: .upsert, record: $0, id: $0.id)
        }
        mutations += try token.before.recurringInvoices.map {
            try mutation(table: "recurringInvoices", op: .upsert, record: $0, id: $0.id)
        }
        return .init(snapshot: result, undo: token, mutations: mutations)
    }

    /// Mirrors the React Native duplicate banner: review the record with less
    /// invoice history, breaking a tie toward the newer customer record.
    static func reviewCandidate(
        for pair: NativeCustomerDuplicatePair,
        entries: [NativeCustomerListEntry]
    ) -> NativeCustomerListEntry? {
        let entryA = entries.first { $0.id == pair.a.id }
        let entryB = entries.first { $0.id == pair.b.id }
        guard let a = entryA, let b = entryB else { return entryB ?? entryA }
        if a.invoices.count != b.invoices.count {
            return a.invoices.count < b.invoices.count ? a : b
        }
        return pair.a.createdAt > pair.b.createdAt ? a : b
    }

    private static func duplicateReason(_ a: Customer, _ b: Customer) -> NativeCustomerDuplicateReason? {
        let aName = duplicateName(a.name), bName = duplicateName(b.name)
        if !aName.isEmpty, aName == bName { return .name }
        let aPhone = phoneKey(a.phone), bPhone = phoneKey(b.phone)
        if !aPhone.isEmpty, aPhone == bPhone { return .phone }
        let aEmail = emailKey(a.email), bEmail = emailKey(b.email)
        if !aEmail.isEmpty, aEmail == bEmail { return .email }
        return nil
    }

    private static func duplicateName(_ value: String) -> String {
        value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").lowercased()
    }

    private static func phoneKey(_ value: String) -> String {
        let digits = value.unicodeScalars.filter { (48...57).contains(Int($0.value)) }.map(String.init).joined()
        return digits.count >= 7 ? digits : ""
    }

    private static func emailKey(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func isBlank(_ value: String) -> Bool {
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func belongsToLoser(
        id: String?,
        name: String,
        loserID: String,
        loserNameKey: String
    ) -> Bool {
        id == loserID || ((id ?? "").isEmpty && normalizedName(name) == loserNameKey)
    }

    private static func records<Record>(
        withIDs ids: [String],
        in records: [Record],
        id: KeyPath<Record, String>
    ) -> [Record] {
        let wanted = Set(ids)
        return records.filter { wanted.contains($0[keyPath: id]) }
    }

    private static func restore<Record: Encodable>(
        _ originals: [Record],
        expected: [Record],
        in records: inout [Record]?,
        id: KeyPath<Record, String>
    ) throws {
        guard originals.count == expected.count else {
            throw NativeCustomerMergeError.undoConflict
        }
        var current = records ?? []
        for (original, merged) in zip(originals, expected) {
            let recordID = original[keyPath: id]
            let matches = current.indices.filter { current[$0][keyPath: id] == recordID }
            guard matches.count == 1, wireEqual(current[matches[0]], merged) else {
                throw NativeCustomerMergeError.undoConflict
            }
            current[matches[0]] = original
        }
        records = current
    }

    private static func mutation<Record: Encodable>(
        table: String,
        op: Canonical.MutationOp,
        record: Record,
        id: String
    ) throws -> Canonical.MutationDraft {
        let data = try mutationEncoder.encode(record)
        let payload = try JSONDecoder().decode(Canonical.JSONValue.self, from: data)
        return .init(table: table, op: op, recordId: id, payload: payload)
    }

    private static func wireEqual<Record: Encodable>(_ lhs: Record, _ rhs: Record) -> Bool {
        guard let lhsBytes = try? mutationEncoder.encode(lhs),
              let rhsBytes = try? mutationEncoder.encode(rhs)
        else { return false }
        return lhsBytes == rhsBytes
    }

    private static let mutationEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()
}
