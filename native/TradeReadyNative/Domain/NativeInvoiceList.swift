import Foundation

/// Pure invoice-list projections mirroring `utils/invoiceStats.ts`,
/// `utils/invoiceHelpers.ts` (`daysPastDue`/`getStatus`) and the
/// `screens/InvoicesScreen.tsx` filter semantics.
///
/// Standalone-compilable (Foundation only) so the `swiftc` focused harness
/// can compile it without the financial-domain file. Amount math duplicates
/// the `PAID_EPSILON` ledger rule deliberately — see Phase 6 half-cent note:
/// these files compile without `FinancialDomain.swift`.
struct NativeInvoiceListItem: Equatable {
    var id: String
    var customer: String
    var number: String
    var amount: Double
    var amountPaid: Double
    /// "YYYY-MM-DD" due date (free-text in RN; may be malformed).
    var due: String
}

enum NativeInvoiceFilter: String, CaseIterable {
    case all, unpaid, overdue, paid
}

enum NativeInvoiceStatus: Equatable {
    case paid
    case partlyPaid
    case dueToday
    case dueSoon
    case overdue(days: Int)

    var label: String {
        switch self {
        case .paid: return "Paid"
        case .partlyPaid: return "Partly paid"
        case .dueToday: return "Due today"
        case .dueSoon: return "Due soon"
        case .overdue(let days): return "\(days)d overdue"
        }
    }
}

struct NativeInvoiceSummary: Equatable {
    var outstanding: Double
    var overdueCount: Int
    var collected: Double
}

enum NativeInvoiceList {
    static let paidEpsilon = 0.005

    static func balanceDue(amount: Double, amountPaid: Double) -> Double {
        max(0, amount - amountPaid)
    }

    static func isFullyPaid(amount: Double, amountPaid: Double) -> Bool {
        balanceDue(amount: amount, amountPaid: amountPaid) <= paidEpsilon
    }

    static func isPartlyPaid(amount: Double, amountPaid: Double) -> Bool {
        amountPaid > paidEpsilon && !isFullyPaid(amount: amount, amountPaid: amountPaid)
    }

    /// Local-midnight day count, mirroring `daysPastDue`: both sides at local
    /// midnight, `round` (not floor) so a DST hour never loses a day.
    static func daysPastDue(due: String, now: Date = Date(), calendar inputCalendar: Calendar = .current    ) -> Int? {
        let calendar = inputCalendar
        guard let dueDay = localMidnight(due, calendar: calendar) else { return nil }
        let today = calendar.startOfDay(for: now)
        let seconds = dueDay.timeIntervalSince(today)
        // today - due, in whole days.
        return Int(round(-seconds / 86_400))
    }

    /// RN `getStatus` precedence: paid flag first, then overdue (any days > 0),
    /// then partly-paid only while NOT past due, then due-today / due-soon.
    /// A malformed due date fails closed to due-soon (never overdue).
    static func status(
        amount: Double,
        amountPaid: Double,
        due: String,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> NativeInvoiceStatus {
        if isFullyPaid(amount: amount, amountPaid: amountPaid) { return .paid }
        guard let days = daysPastDue(due: due, now: now, calendar: calendar) else { return .dueSoon }
        if days > 0 { return .overdue(days: days) }
        if isPartlyPaid(amount: amount, amountPaid: amountPaid) { return .partlyPaid }
        return days == 0 ? .dueToday : .dueSoon
    }

    static func isOverdue(
        amount: Double,
        amountPaid: Double,
        due: String,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Bool {
        guard let days = daysPastDue(due: due, now: now, calendar: calendar) else { return false }
        return !isFullyPaid(amount: amount, amountPaid: amountPaid) && days > 0
    }

    static func summarize(
        _ invoices: [NativeInvoiceListItem],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> NativeInvoiceSummary {
        var outstanding = 0.0
        var collected = 0.0
        var overdueCount = 0
        for inv in invoices {
            collected += inv.amountPaid
            outstanding += balanceDue(amount: inv.amount, amountPaid: inv.amountPaid)
            if isOverdue(amount: inv.amount, amountPaid: inv.amountPaid, due: inv.due, now: now, calendar: calendar) {
                overdueCount += 1
            }
        }
        return NativeInvoiceSummary(outstanding: outstanding, overdueCount: overdueCount, collected: collected)
    }

    /// Case-insensitive customer-or-number match (`filterInvoices` parity).
    /// Empty query returns input order.
    static func filter(_ invoices: [NativeInvoiceListItem], query: String) -> [NativeInvoiceListItem] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return invoices }
        return invoices.filter {
            $0.customer.localizedCaseInsensitiveContains(q) || $0.number.localizedCaseInsensitiveContains(q)
        }
    }

    /// Status-chip semantics matching `InvoicesView`: unpaid = not fully paid,
    /// overdue = unpaid AND past due, paid = fully paid.
    static func matches(
        _ invoice: NativeInvoiceListItem,
        filter: NativeInvoiceFilter,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Bool {
        switch filter {
        case .all: return true
        case .unpaid: return !isFullyPaid(amount: invoice.amount, amountPaid: invoice.amountPaid)
        case .paid: return isFullyPaid(amount: invoice.amount, amountPaid: invoice.amountPaid)
        case .overdue:
            return isOverdue(amount: invoice.amount, amountPaid: invoice.amountPaid, due: invoice.due, now: now, calendar: calendar)
        }
    }

    static func counts(
        _ invoices: [NativeInvoiceListItem],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [NativeInvoiceFilter: Int] {
        var result: [NativeInvoiceFilter: Int] = [:]
        for f in NativeInvoiceFilter.allCases {
            result[f] = invoices.filter { matches($0, filter: f, now: now, calendar: calendar) }.count
        }
        return result
    }

    /// Native list order is due-ascending; malformed dates sort last, ties by id.
    static func sortedByDue(
        _ invoices: [NativeInvoiceListItem],
        calendar: Calendar = .current
    ) -> [NativeInvoiceListItem] {
        invoices.sorted {
            let a = localMidnight($0.due, calendar: calendar)
            let b = localMidnight($1.due, calendar: calendar)
            switch (a, b) {
            case let (x?, y?): return x == y ? $0.id < $1.id : x < y
            case (.some, .none): return true
            case (.none, .some): return false
            case (.none, .none): return $0.id < $1.id
            }
        }
    }

    // MARK: - Private

    /// Strict "YYYY-MM-DD" → local midnight. Anything else fails closed
    /// (nil) rather than throwing — the RN due field is free-text.
    private static func localMidnight(_ raw: String, calendar: Calendar) -> Date? {
        let parts = raw.split(separator: "-")
        guard parts.count == 3,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              (1...12).contains(m), (1...31).contains(d)
        else { return nil }
        return calendar.date(from: DateComponents(year: y, month: m, day: d))
    }
}
