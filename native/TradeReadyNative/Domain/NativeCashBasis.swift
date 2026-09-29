import Foundation

// MARK: - Cash-basis date windows (task 9.01, requirements M1)
//
// Ported from `utils/moneyUtils.ts` (getDateRange / getPreviousRange /
// parseLocalDate / isInRange / getLast6MonthLabels) and the export presets in
// `utils/csvExport.ts` (exportDateRange). Every window is built in the LOCAL
// calendar so a date-only "YYYY-MM-DD" record never shifts a day under a
// timezone offset — see docs/native-phase-9-money-exports-contract-decisions.md
// §1.1. Nothing here reads the wall clock implicitly; callers inject `now`.

/// A closed date window `[start, end]`, matching `DateRange` in `moneyUtils.ts`.
struct NativeDateRange: Equatable {
    var start: Date
    var end: Date
}

/// `getLast6MonthLabels` entry.
struct NativeMonthLabel: Equatable {
    var label: String
    var year: Int
    /// Zero-based local month, matching `Date.getMonth()`.
    var month: Int
}

enum NativeCashBasis {
    /// The local calendar. `moneyUtils.ts` uses the JS `Date` local-frame
    /// constructor, so the mirror must use the current timezone.
    static var localCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        return calendar
    }

    private static let monthNames = [
        "Jan", "Feb", "Mar", "Apr", "May", "Jun",
        "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
    ]

    /// `new Date(year, month, day, hour, minute, second)` — zero-based month and
    /// JS out-of-range normalization (`day 0` → previous month's last day).
    static func localDate(
        year: Int,
        month: Int,
        day: Int,
        hour: Int = 0,
        minute: Int = 0,
        second: Int = 0
    ) -> Date {
        localCalendar.date(from: DateComponents(
            year: year,
            month: month + 1,
            day: day,
            hour: hour,
            minute: minute,
            second: second
        ))!
    }

    static func localComponents(_ date: Date) -> (year: Int, month: Int, day: Int) {
        let parts = localCalendar.dateComponents([.year, .month, .day], from: date)
        return (parts.year ?? 1970, (parts.month ?? 1) - 1, parts.day ?? 1)
    }

    /// Local `"YYYY-MM-DD"` for a Date — never `toISOString()` (the same
    /// west-of-UTC trap `parseLocalDate` exists to avoid).
    static func ymd(_ date: Date) -> String {
        let (year, month, day) = localComponents(date)
        return String(format: "%04d-%02d-%02d", year, month + 1, day)
    }

    private static let dateOnlyPattern = try! NSRegularExpression(pattern: "^\\d{4}-\\d{2}-\\d{2}$")
    private static let localDateTimePattern = try! NSRegularExpression(
        pattern: "^(\\d{4})-(\\d{2})-(\\d{2})[T ](\\d{2}):(\\d{2})(?::(\\d{2})(?:\\.(\\d+))?)?$"
    )

    private static func matches(_ regex: NSRegularExpression, _ value: String) -> Bool {
        regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
    }

    /// `parseLocalDate`: a bare `YYYY-MM-DD` (or a timezone-less local datetime)
    /// becomes a local-frame Date; anything carrying an explicit offset falls
    /// back to the ISO-8601 parser. Unparseable input is `nil`, which behaves
    /// like JS `Invalid Date` (every comparison is false).
    static func parseLocalDate(_ dateString: String) -> Date? {
        if matches(dateOnlyPattern, dateString) {
            let parts = dateString.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 3 else { return nil }
            return localDate(year: parts[0], month: parts[1] - 1, day: parts[2])
        }
        if let match = localDateTimePattern.firstMatch(
            in: dateString,
            range: NSRange(dateString.startIndex..., in: dateString)
        ) {
            func group(_ index: Int) -> String? {
                guard let range = Range(match.range(at: index), in: dateString) else { return nil }
                return String(dateString[range])
            }
            let year = Int(group(1) ?? "")
            let month = Int(group(2) ?? "")
            let day = Int(group(3) ?? "")
            let hour = Int(group(4) ?? "")
            let minute = Int(group(5) ?? "")
            let second = Int(group(6) ?? "") ?? 0
            if let year, let month, let day, let hour, let minute {
                return localDate(year: year, month: month - 1, day: day, hour: hour, minute: minute, second: second)
            }
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let parsed = formatter.date(from: dateString) { return parsed }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: dateString)
    }

    /// Inclusive membership test mirroring `isInRange`.
    static func isInRange(_ dateString: String, start: Date, end: Date) -> Bool {
        guard let date = parseLocalDate(dateString) else { return false }
        return date >= start && date <= end
    }

    /// `getDateRange`. Unknown ids fall back to `all_time`.
    static func range(for filterID: String, now: Date) -> NativeDateRange {
        let (year, month, _) = localComponents(now)
        switch filterID {
        case "this_month":
            return NativeDateRange(
                start: localDate(year: year, month: month, day: 1),
                end: localDate(year: year, month: month + 1, day: 0, hour: 23, minute: 59, second: 59)
            )
        case "last_month":
            return NativeDateRange(
                start: localDate(year: year, month: month - 1, day: 1),
                end: localDate(year: year, month: month, day: 0, hour: 23, minute: 59, second: 59)
            )
        case "this_year":
            return NativeDateRange(
                start: localDate(year: year, month: 0, day: 1),
                end: localDate(year: year, month: 11, day: 31, hour: 23, minute: 59, second: 59)
            )
        default:
            return NativeDateRange(
                start: Date(timeIntervalSince1970: 0),
                end: localDate(year: 9999, month: 11, day: 31)
            )
        }
    }

    /// `getPreviousRange`. `all_time`/unknown have no meaningful previous window.
    static func previousRange(for filterID: String, now: Date) -> NativeDateRange? {
        let (year, month, _) = localComponents(now)
        switch filterID {
        case "this_month":
            return NativeDateRange(
                start: localDate(year: year, month: month - 1, day: 1),
                end: localDate(year: year, month: month, day: 0, hour: 23, minute: 59, second: 59)
            )
        case "last_month":
            return NativeDateRange(
                start: localDate(year: year, month: month - 2, day: 1),
                end: localDate(year: year, month: month - 1, day: 0, hour: 23, minute: 59, second: 59)
            )
        case "this_year":
            return NativeDateRange(
                start: localDate(year: year - 1, month: 0, day: 1),
                end: localDate(year: year - 1, month: 11, day: 31, hour: 23, minute: 59, second: 59)
            )
        default:
            return nil
        }
    }

    /// `exportDateRange` — same local construction as `range(for:)` plus the two
    /// export-only presets (`this_quarter`, `last_year`).
    static func exportRange(for rangeID: String, now: Date) -> NativeDateRange {
        let (year, month, _) = localComponents(now)
        switch rangeID {
        case "this_month":
            return NativeDateRange(
                start: localDate(year: year, month: month, day: 1),
                end: localDate(year: year, month: month + 1, day: 0, hour: 23, minute: 59, second: 59)
            )
        case "this_quarter":
            let quarter = (month / 3) * 3
            return NativeDateRange(
                start: localDate(year: year, month: quarter, day: 1),
                end: localDate(year: year, month: quarter + 3, day: 0, hour: 23, minute: 59, second: 59)
            )
        case "this_year":
            return NativeDateRange(
                start: localDate(year: year, month: 0, day: 1),
                end: localDate(year: year, month: 11, day: 31, hour: 23, minute: 59, second: 59)
            )
        case "last_year":
            return NativeDateRange(
                start: localDate(year: year - 1, month: 0, day: 1),
                end: localDate(year: year - 1, month: 11, day: 31, hour: 23, minute: 59, second: 59)
            )
        default:
            return NativeDateRange(
                start: Date(timeIntervalSince1970: 0),
                end: localDate(year: 9999, month: 11, day: 31)
            )
        }
    }

    /// `getLast6MonthLabels` — six entries, oldest first, last = current month.
    static func last6MonthLabels(now: Date) -> [NativeMonthLabel] {
        let (year, month, _) = localComponents(now)
        return (0..<6).reversed().map { offset in
            let date = localDate(year: year, month: month - offset, day: 1)
            let parts = localComponents(date)
            return NativeMonthLabel(label: monthNames[parts.month], year: parts.year, month: parts.month)
        }
    }

    // MARK: - Payment ledger bridge

    /// Maps one canonical invoice onto the ledger mirror the shared engine reads.
    /// Unknown method strings fall back to `.other`; the ledger only
    /// special-cases `.stripe` (fees) and voided entries (contribute nothing),
    /// so the fallback is safe. Matches `NativeJobProfitability.ledgerInvoice`
    /// and `AppStore.ledgerInvoice`.
    static func ledgerInvoice(_ invoice: Canonical.Invoice) -> LedgerInvoice {
        LedgerInvoice(
            id: invoice.id,
            amount: invoice.amount,
            due: invoice.due,
            paid: invoice.paid,
            paidAt: invoice.paidAt,
            payments: invoice.payments?.map { payment in
                LedgerPayment(
                    id: payment.id,
                    amount: payment.amount,
                    date: payment.date,
                    method: LedgerPaymentMethod(rawValue: payment.method) ?? .other,
                    note: payment.note,
                    voidedAt: payment.voidedAt
                )
            },
            depositRequest: invoice.depositRequest.map { DepositRequest(amount: $0.amount) }
        )
    }

    /// `paymentsInRange` — voided entries are KEPT (callers that sum filter them).
    static func paymentsInRange(
        _ invoice: Canonical.Invoice,
        start: Date,
        end: Date
    ) -> [LedgerPayment] {
        PaymentLedger.materializeLegacyLedger(ledgerInvoice(invoice))
            .filter { isInRange($0.date, start: start, end: end) }
    }

    /// `collectedInRange` — non-voided payments dated inside the window. Legacy
    /// paid invoices bucket on `paidAt ?? due` via the materialized ledger.
    static func collected(invoices: [Canonical.Invoice], start: Date, end: Date) -> Decimal {
        invoices.reduce(Decimal.zero) { total, invoice in
            total + paymentsInRange(invoice, start: start, end: end).reduce(Decimal.zero) {
                $0 + ($1.voidedAt == nil ? $1.amount : 0)
            }
        }
    }

    /// `collectedByPeriod` — walks each ledger once; a payment inside two
    /// overlapping windows counts in both.
    static func collectedByPeriod(
        invoices: [Canonical.Invoice],
        ranges: [NativeDateRange]
    ) -> [Decimal] {
        var totals = Array(repeating: Decimal.zero, count: ranges.count)
        for invoice in invoices {
            for payment in PaymentLedger.materializeLegacyLedger(ledgerInvoice(invoice))
            where payment.voidedAt == nil {
                for index in ranges.indices
                where isInRange(payment.date, start: ranges[index].start, end: ranges[index].end) {
                    totals[index] += payment.amount
                }
            }
        }
        return totals
    }
}
