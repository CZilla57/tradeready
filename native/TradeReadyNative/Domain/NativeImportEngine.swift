import Foundation

// MARK: - CSV import engine (task 9.07, requirements I1-I3)
//
// Pure port of `utils/importEngine.ts` (+ `upsertCustomerInList` and
// `nextInvoiceNumber`). Each builder returns the FULL next array plus per-row
// outcomes and counts; the caller does load/save. Customers are created only
// through the shared upsert so the normalized-name join and blank-field backfill
// rules cannot be bypassed. `importBatchId` is stamped on CREATED records only.

struct NativeRowOutcome: Equatable {
    var rowIndex: Int
    /// "ok" | "skip" | "flag"
    var status: String
    var reason: String?
}

struct NativeImportCounts: Equatable {
    var ok = 0
    var skip = 0
    var flag = 0
    var created = 0
    var matched = 0
}

struct NativeCustomerImportResult {
    var records: [Canonical.Customer]
    var outcomes: [NativeRowOutcome]
    var counts: NativeImportCounts
}

struct NativeJobImportResult {
    var customers: [Canonical.Customer]
    var jobs: [Canonical.Job]
    var outcomes: [NativeRowOutcome]
    var counts: NativeImportCounts
}

struct NativeInvoiceImportResult {
    var customers: [Canonical.Customer]
    var invoices: [Canonical.Invoice]
    var outcomes: [NativeRowOutcome]
    var counts: NativeImportCounts
}

struct NativeExpenseImportResult {
    var expenses: [Canonical.Expense]
    var outcomes: [NativeRowOutcome]
    var counts: NativeImportCounts
}

/// Injectable identity/clock so import results are deterministic under test.
struct NativeImportEnvironment {
    var nowMs: () -> Int64
    var today: () -> String
    var newCustomerID: () -> String
    var newJobID: () -> String
    var newExpenseID: () -> String

    static func live() -> NativeImportEnvironment {
        var customerCounter = 0
        var jobCounter = 0
        var expenseCounter = 0
        return NativeImportEnvironment(
            nowMs: { Int64(Date().timeIntervalSince1970 * 1000) },
            today: { NativeCashBasis.ymd(Date()) },
            newCustomerID: { customerCounter += 1; return "c\(Int64(Date().timeIntervalSince1970 * 1000))_\(customerCounter)" },
            newJobID: { jobCounter += 1; return "j\(Int64(Date().timeIntervalSince1970 * 1000))_\(jobCounter)" },
            newExpenseID: { expenseCounter += 1; return "e\(Int64(Date().timeIntervalSince1970 * 1000))_\(expenseCounter)" }
        )
    }
}

enum NativeImportEngine {
    // MARK: canonical record plumbing

    /// Encode a canonical record back into its JSON field bag (preserving any
    /// unknown fields it carries) so edits merge instead of replacing.
    static func fields<T: Encodable>(_ value: T) -> [String: Canonical.JSONValue] {
        guard let data = try? JSONEncoder().encode(value),
              let object = try? JSONDecoder().decode(Canonical.JSONValue.self, from: data),
              case let .object(fields) = object
        else { return [:] }
        return fields
    }

    static func decode<T: Decodable>(_ type: T.Type, _ fields: [String: Canonical.JSONValue]) -> T? {
        guard let data = try? JSONEncoder().encode(Canonical.JSONValue.object(fields)) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    /// First non-empty cell whose column maps to `key`, joined with spaces.
    static func fieldValue(_ row: [String], _ mapping: [String?], _ key: String) -> String {
        var parts: [String] = []
        for index in mapping.indices where mapping[index] == key {
            let value = (index < row.count ? row[index] : "").trimmingCharacters(in: .whitespaces)
            if !value.isEmpty { parts.append(value) }
        }
        return parts.joined(separator: " ")
    }

    static func normalizeName(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespaces).lowercased()
    }

    // MARK: customers

    /// `upsertCustomerInList`: backfill only BLANK contact fields, never clobber.
    static func upsertCustomer(
        _ customers: [Canonical.Customer],
        name: String,
        email: String = "",
        phone: String = "",
        address: String = "",
        createdAt: String,
        newID: () -> String
    ) -> (customer: Canonical.Customer?, customers: [Canonical.Customer], changed: Bool) {
        let key = normalizeName(name)
        if key.isEmpty { return (nil, customers, false) }

        if let index = customers.firstIndex(where: { normalizeName($0.name) == key }) {
            let existing = customers[index]
            var merged = fields(existing)
            let mergedEmail = existing.email.isEmpty ? email : existing.email
            let mergedPhone = existing.phone.isEmpty ? phone : existing.phone
            let mergedAddress = existing.address.isEmpty ? address : existing.address
            merged["email"] = .string(mergedEmail)
            merged["phone"] = .string(mergedPhone)
            merged["address"] = .string(mergedAddress)
            let changed = mergedEmail != existing.email || mergedPhone != existing.phone || mergedAddress != existing.address
            guard changed, let updated = decode(Canonical.Customer.self, merged) else {
                return (existing, customers, false)
            }
            var next = customers
            next[index] = updated
            return (updated, next, true)
        }

        let created = decode(Canonical.Customer.self, [
            "id": .string(newID()),
            "name": .string(name.trimmingCharacters(in: .whitespaces)),
            "email": .string(email),
            "phone": .string(phone),
            "address": .string(address),
            "notes": .string(""),
            "createdAt": .string(createdAt),
        ])!
        return (created, customers + [created], true)
    }

    static func buildCustomerImport(
        rows: [[String]],
        mapping: [String?],
        existing: [Canonical.Customer],
        batchID: String,
        environment: NativeImportEnvironment
    ) -> NativeCustomerImportResult {
        var accumulator = existing
        var outcomes: [NativeRowOutcome] = []
        var counts = NativeImportCounts()

        for (rowIndex, row) in rows.enumerated() {
            let name = fieldValue(row, mapping, "name")
            if name.isEmpty {
                outcomes.append(NativeRowOutcome(rowIndex: rowIndex, status: "skip", reason: "No customer name"))
                counts.skip += 1
                continue
            }
            let notes = fieldValue(row, mapping, "notes")
            let existedBefore = accumulator.contains { normalizeName($0.name) == normalizeName(name) }
            let result = upsertCustomer(
                accumulator, name: name,
                email: fieldValue(row, mapping, "email"),
                phone: fieldValue(row, mapping, "phone"),
                address: fieldValue(row, mapping, "address"),
                createdAt: environment.today(),
                newID: environment.newCustomerID
            )
            guard let customer = result.customer else {
                outcomes.append(NativeRowOutcome(rowIndex: rowIndex, status: "skip", reason: "No customer name"))
                counts.skip += 1
                continue
            }
            if existedBefore {
                accumulator = result.customers
                counts.matched += 1
            } else {
                accumulator = result.customers.map { record in
                    guard record.id == customer.id else { return record }
                    var updated = fields(record)
                    updated["importBatchId"] = .string(batchID)
                    if !notes.isEmpty { updated["notes"] = .string(notes) }
                    return decode(Canonical.Customer.self, updated) ?? record
                }
                counts.created += 1
            }
            outcomes.append(NativeRowOutcome(rowIndex: rowIndex, status: "ok", reason: nil))
            counts.ok += 1
        }
        return NativeCustomerImportResult(records: accumulator, outcomes: outcomes, counts: counts)
    }

    /// Undo helper: drop every record created by a batch.
    static func stripBatch<T>(_ records: [T], batchID: String, batchIDOf: (T) -> String?) -> [T] {
        records.filter { batchIDOf($0) != batchID }
    }

    // MARK: jobs

    private static let statusKeywords: [(status: String, words: [String])] = [
        ("estimate_sent", ["estimate sent", "quote sent", "quoted", "estimate", "quote"]),
        ("in_progress", ["in progress", "started", "working", "active"]),
        ("declined", ["declined", "lost", "cancelled", "canceled", "rejected"]),
        ("scheduled", ["scheduled", "booked", "upcoming"]),
        ("approved", ["approved", "won", "accepted"]),
        ("complete", ["complete", "completed", "done", "closed", "finished"]),
        ("invoiced", ["invoiced", "billed"]),
        ("paid", ["paid"]),
        ("lead", ["lead", "new", "inquiry", "enquiry", "prospect"]),
    ]

    static func mapJobStatus(_ raw: String) -> (status: String, recognized: Bool) {
        let value = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if value.isEmpty { return ("lead", false) }
        for entry in statusKeywords where entry.words.contains(where: { value.contains($0) }) {
            return (entry.status, true)
        }
        return ("lead", false)
    }

    static func buildJobImport(
        rows: [[String]],
        mapping: [String?],
        existingCustomers: [Canonical.Customer],
        existingJobs: [Canonical.Job],
        batchID: String,
        dateFormat: NativeDateFormat?,
        environment: NativeImportEnvironment
    ) -> NativeJobImportResult {
        var customers = existingCustomers
        var jobs = existingJobs
        var outcomes: [NativeRowOutcome] = []
        var counts = NativeImportCounts()

        for (rowIndex, row) in rows.enumerated() {
            let title = fieldValue(row, mapping, "title")
            let customerName = fieldValue(row, mapping, "customerName")
            if title.isEmpty || customerName.isEmpty {
                outcomes.append(NativeRowOutcome(rowIndex: rowIndex, status: "skip", reason: "Missing job title or customer"))
                counts.skip += 1
                continue
            }

            let existedBefore = customers.contains { normalizeName($0.name) == normalizeName(customerName) }
            let result = upsertCustomer(
                customers, name: customerName, createdAt: environment.today(), newID: environment.newCustomerID
            )
            let customer = result.customer!
            customers = existedBefore
                ? result.customers
                : result.customers.map { record in
                    guard record.id == customer.id else { return record }
                    var updated = fields(record)
                    updated["importBatchId"] = .string(batchID)
                    return decode(Canonical.Customer.self, updated) ?? record
                }

            let statusRaw = fieldValue(row, mapping, "status")
            let (status, recognized) = mapJobStatus(statusRaw)
            let scheduledDate = NativeImportMapping.parseImportDate(fieldValue(row, mapping, "scheduledDate"), format: dateFormat)
            let estimateTotal = parseMoney(fieldValue(row, mapping, "estimateTotal").replacingOccurrences(
                of: "[^0-9.-]", with: "", options: .regularExpression
            )) ?? 0

            let jobFields: [String: Canonical.JSONValue] = [
                "id": .string(environment.newJobID()),
                "customerId": .string(customer.id),
                "customerName": .string(customer.name),
                "title": .string(title),
                "description": .string(fieldValue(row, mapping, "description")),
                "status": .string(status),
                "scheduledDate": scheduledDate.map { Canonical.JSONValue.string($0) } ?? .null,
                "address": .string(fieldValue(row, mapping, "address")),
                "estimateTotal": .number(estimateTotal),
                "laborHours": .number(0),
                "laborRate": .number(0),
                "materials": .array([]),
                "materialMarkup": .number(0),
                "overhead": .number(0),
                "margin": .number(0),
                "notes": .string(fieldValue(row, mapping, "notes")),
                "invoiceId": .null,
                "createdAt": .string(environment.today()),
                "importBatchId": .string(batchID),
                // estimateSentAt deliberately absent → no follow-up nudge on imports.
            ]
            if let job = decode(Canonical.Job.self, jobFields) { jobs.append(job) }

            if !statusRaw.isEmpty && !recognized {
                outcomes.append(NativeRowOutcome(rowIndex: rowIndex, status: "flag", reason: "Unknown status \"\(statusRaw)\" → lead"))
                counts.flag += 1
            } else {
                outcomes.append(NativeRowOutcome(rowIndex: rowIndex, status: "ok", reason: nil))
                counts.ok += 1
            }
        }
        return NativeJobImportResult(customers: customers, jobs: jobs, outcomes: outcomes, counts: counts)
    }

    // MARK: invoices

    static func parseMoney(_ raw: String) -> Decimal? {
        let cleaned = raw.replacingOccurrences(of: "[^0-9.\\-]", with: "", options: .regularExpression)
        if cleaned.isEmpty { return nil }
        guard let value = Decimal(string: cleaned, locale: Locale(identifier: "en_US_POSIX")),
              NSDecimalNumber(decimal: value).doubleValue.isFinite else { return nil }
        return value
    }

    private static let paidClaimPattern = try! NSRegularExpression(pattern: "paid|yes|true", options: .caseInsensitive)

    /// Unique invoice id whose embedded ms decodes back to the source issue date
    /// (UTC reader), bumping the intra-day slot on collision.
    static func uniqueImportInvoiceID(
        dateString: String?,
        index: Int,
        nowMs: Int64,
        usedIDs: inout Set<String>
    ) -> String {
        var dayFloor: Int64
        if let dateString {
            let parts = dateString.split(separator: "-").compactMap { Int64($0) }
            if parts.count == 3 {
                var utc = Calendar(identifier: .gregorian)
                utc.timeZone = TimeZone(secondsFromGMT: 0)!
                let date = utc.date(from: DateComponents(year: Int(parts[0]), month: Int(parts[1]), day: Int(parts[2])))!
                dayFloor = Int64(date.timeIntervalSince1970 * 1000)
            } else {
                dayFloor = nowMs - (nowMs % 86_400_000)
            }
        } else {
            dayFloor = nowMs - (nowMs % 86_400_000)
        }
        var slot = 1 + (((nowMs % 86_400_000) + Int64(index)) % 86_399_998)
        var id = String(dayFloor + slot)
        while usedIDs.contains(id) {
            slot = slot >= 86_399_998 ? 1 : slot + 1
            id = String(dayFloor + slot)
        }
        usedIDs.insert(id)
        return id
    }

    /// `nextInvoiceNumber`: digits of every existing number, max + 1, floored by
    /// the configured starting number.
    static func nextInvoiceNumber(_ invoices: [Canonical.Invoice], prefix: String?, startNumber: Int?) -> String {
        let normalizedPrefix = normalizedInvoicePrefix(prefix)
        let start = (startNumber != nil && startNumber! >= 1) ? startNumber! : 1
        let numbers: [Int] = invoices.compactMap { invoice in
            var raw = invoice.number
            if raw.uppercased().hasPrefix(normalizedPrefix.uppercased()) {
                raw = String(raw.dropFirst(normalizedPrefix.count))
            }
            let digits = raw.filter { $0.isNumber }
            guard !digits.isEmpty, let value = Int(digits) else { return nil }
            return value
        }
        let next = max(numbers.isEmpty ? 1 : (numbers.max() ?? 0) + 1, start)
        return "\(normalizedPrefix)-" + String(format: "%04d", next)
    }

    static func normalizedInvoicePrefix(_ prefix: String?) -> String {
        let trimmed = (prefix ?? "").trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "[-\\s]+$", with: "", options: .regularExpression)
        return trimmed.isEmpty ? "INV" : trimmed
    }

    static func buildInvoiceImport(
        rows: [[String]],
        mapping: [String?],
        existingCustomers: [Canonical.Customer],
        existingInvoices: [Canonical.Invoice],
        batchID: String,
        dateFormat: NativeDateFormat?,
        invoicePrefix: String?,
        invoiceStartNumber: Int?,
        environment: NativeImportEnvironment
    ) -> NativeInvoiceImportResult {
        var customers = existingCustomers
        var invoices = existingInvoices
        var outcomes: [NativeRowOutcome] = []
        var counts = NativeImportCounts()
        var usedIDs = Set(existingInvoices.map(\.id))
        let nowMs = environment.nowMs()

        for (rowIndex, row) in rows.enumerated() {
            let customerName = fieldValue(row, mapping, "customer")
            guard let amount = parseMoney(fieldValue(row, mapping, "amount")), !customerName.isEmpty else {
                outcomes.append(NativeRowOutcome(rowIndex: rowIndex, status: "skip", reason: "Missing customer or amount"))
                counts.skip += 1
                continue
            }

            let existedBefore = customers.contains { normalizeName($0.name) == normalizeName(customerName) }
            let result = upsertCustomer(
                customers, name: customerName,
                email: fieldValue(row, mapping, "email"),
                phone: fieldValue(row, mapping, "phone"),
                createdAt: environment.today(),
                newID: environment.newCustomerID
            )
            let customer = result.customer!
            if existedBefore {
                customers = result.customers
                counts.matched += 1
            } else {
                customers = result.customers.map { record in
                    guard record.id == customer.id else { return record }
                    var updated = fields(record)
                    updated["importBatchId"] = .string(batchID)
                    return decode(Canonical.Customer.self, updated) ?? record
                }
                counts.created += 1
            }

            let dueParsed = NativeImportMapping.parseImportDate(fieldValue(row, mapping, "due"), format: dateFormat)
            let paidAtCell = fieldValue(row, mapping, "paidAt")
            let paidAtParsed = NativeImportMapping.parseImportDate(paidAtCell, format: dateFormat)
            let paid = paidAtParsed != nil
            let trimmedPaidCell = paidAtCell.trimmingCharacters(in: .whitespaces)
            let claimedPaid = paidAtParsed == nil && !trimmedPaidCell.isEmpty && paidClaimPattern.firstMatch(
                in: trimmedPaidCell,
                range: NSRange(trimmedPaidCell.startIndex..., in: trimmedPaidCell)
            ) != nil

            let due = dueParsed ?? environment.today()
            let idDateString = dueParsed ?? paidAtParsed
            let id = uniqueImportInvoiceID(dateString: idDateString, index: rowIndex, nowMs: nowMs, usedIDs: &usedIDs)

            let mappedNumber = fieldValue(row, mapping, "number")
            let number = mappedNumber.isEmpty
                ? nextInvoiceNumber(invoices, prefix: invoicePrefix, startNumber: invoiceStartNumber)
                : mappedNumber

            let emailCell = fieldValue(row, mapping, "email")
            let phoneCell = fieldValue(row, mapping, "phone")
            var invoiceFields: [String: Canonical.JSONValue] = [
                "id": .string(id),
                "customer": .string(customer.name),
                "customerId": .string(customer.id),
                "number": .string(number),
                "amount": .number(amount),
                "due": .string(due),
                "email": .string(emailCell.isEmpty ? customer.email : emailCell),
                "phone": .string(phoneCell.isEmpty ? customer.phone : phoneCell),
                "desc": .string(fieldValue(row, mapping, "desc")),
                "paid": .bool(paid),
                "importBatchId": .string(batchID),
            ]
            if let paidAt = paidAtParsed { invoiceFields["paidAt"] = .string(paidAt) }
            if let invoice = decode(Canonical.Invoice.self, invoiceFields) { invoices.append(invoice) }

            if claimedPaid {
                outcomes.append(NativeRowOutcome(rowIndex: rowIndex, status: "flag", reason: "Marked paid but no paid date → imported outstanding"))
                counts.flag += 1
            } else {
                outcomes.append(NativeRowOutcome(rowIndex: rowIndex, status: "ok", reason: nil))
                counts.ok += 1
            }
        }
        return NativeInvoiceImportResult(customers: customers, invoices: invoices, outcomes: outcomes, counts: counts)
    }

    // MARK: expenses

    static func mapExpenseCategory(_ raw: String) -> (id: String, recognized: Bool) {
        let value = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if value.isEmpty { return ("other", false) }
        for category in NativeExpenseCategories.all {
            if category.id == value || category.label.lowercased() == value || value.contains(category.id) {
                return (category.id, true)
            }
        }
        let extra: [(id: String, words: [String])] = [
            ("fuel", ["gas", "fuel", "mileage", "transport"]),
            ("tools", ["tool", "equipment", "rental"]),
            ("labor", ["subcontractor", "sub", "labour", "labor", "crew"]),
            ("marketing", ["ad", "advertis", "marketing"]),
            ("software", ["software", "subscription", "app"]),
            ("insurance", ["insurance"]),
            ("materials", ["material", "supply", "supplies", "lumber"]),
        ]
        for entry in extra where entry.words.contains(where: { value.contains($0) }) {
            return (entry.id, true)
        }
        return ("other", false)
    }

    static func buildExpenseImport(
        rows: [[String]],
        mapping: [String?],
        existingExpenses: [Canonical.Expense],
        batchID: String,
        dateFormat: NativeDateFormat?,
        environment: NativeImportEnvironment
    ) -> NativeExpenseImportResult {
        var expenses = existingExpenses
        var outcomes: [NativeRowOutcome] = []
        var counts = NativeImportCounts()

        for (rowIndex, row) in rows.enumerated() {
            let amount = parseMoney(fieldValue(row, mapping, "amount"))
            let date = NativeImportMapping.parseImportDate(fieldValue(row, mapping, "date"), format: dateFormat)
            guard let amount, let date else {
                let reason = amount == nil ? "Missing amount" : "Unparseable date"
                outcomes.append(NativeRowOutcome(rowIndex: rowIndex, status: "skip", reason: reason))
                counts.skip += 1
                continue
            }
            let categoryRaw = fieldValue(row, mapping, "category")
            let (category, recognized) = mapExpenseCategory(categoryRaw)
            if let expense = decode(Canonical.Expense.self, [
                "id": .string(environment.newExpenseID()),
                "createdAt": .string(environment.today()),
                "description": .string(fieldValue(row, mapping, "description")),
                "amount": .number(amount),
                "category": .string(category),
                "date": .string(date),
                "notes": .string(fieldValue(row, mapping, "notes")),
                "receiptUri": .null,
                "importBatchId": .string(batchID),
            ]) {
                expenses.append(expense)
            }

            if !categoryRaw.isEmpty && !recognized {
                outcomes.append(NativeRowOutcome(rowIndex: rowIndex, status: "flag", reason: "Unknown category \"\(categoryRaw)\" → Other"))
                counts.flag += 1
            } else {
                outcomes.append(NativeRowOutcome(rowIndex: rowIndex, status: "ok", reason: nil))
                counts.ok += 1
            }
        }
        return NativeExpenseImportResult(expenses: expenses, outcomes: outcomes, counts: counts)
    }
}
