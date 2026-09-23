import Foundation

// MARK: - CSV export builders (task 9.06, requirement X1)
//
// Pure port of `utils/csvExport.ts`. Builders are string-in/string-out and do no
// I/O; the share tail (cache write + share sheet) is a separate thin layer that
// mirrors RN's `shareCsv`/`shareZip` ownership of its own alerts.

/// The eight expense categories in their canonical order. Index 7 is the
/// "Other" fallback for an unknown persisted id, matching ExpenseRow and the
/// export builders.
enum NativeExpenseCategories {
    static let all: [(id: String, label: String)] = [
        ("materials", "Materials"),
        ("tools", "Tools & Equipment"),
        ("fuel", "Fuel & Transport"),
        ("labor", "Subcontractors"),
        ("insurance", "Insurance"),
        ("software", "Software & Apps"),
        ("marketing", "Marketing"),
        ("other", "Other"),
    ]

    static func label(for id: String) -> String {
        all.first { $0.id == id }?.label ?? all[7].label
    }
}

enum NativeCSVExport {
    // MARK: primitives

    /// RFC-4180 escaping: quote when the value contains a comma, quote, or line
    /// break; double embedded quotes. Everything else passes through.
    static func escapeCsvField(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\r") || value.contains("\n") {
            return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return value
    }

    /// Header + rows, CRLF line endings, trailing CRLF, no totals row.
    static func toCsv(_ header: [String], _ rows: [[String]]) -> String {
        ([header] + rows)
            .map { $0.map(escapeCsvField).joined(separator: ",") }
            .joined(separator: "\r\n") + "\r\n"
    }

    /// JS `toFixed(2)` over the RN `toAmount` coercion (a JS number, i.e. a
    /// double). Half-away-from-zero rounding at scale 2, no grouping separators.
    static func money(_ value: Decimal) -> String {
        toFixed2(NSDecimalNumber(decimal: value).doubleValue)
    }

    static func toFixed2(_ value: Double) -> String {
        guard value.isFinite else { return "0.00" }
        var input = Decimal(value)
        var rounded = Decimal()
        NSDecimalRound(&rounded, &input, 2, .plain)
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSDecimalNumber(decimal: rounded)) ?? "0.00"
    }

    /// JS `Array.prototype.sort` is stable; Swift's is not. Sorting ties keep
    /// their original relative order so exports are byte-reproducible.
    static func stableSorted<T>(_ items: [T], by areInIncreasingOrder: (T, T) -> Bool) -> [T] {
        items.enumerated().sorted { lhs, rhs in
            if areInIncreasingOrder(lhs.element, rhs.element) { return true }
            if areInIncreasingOrder(rhs.element, lhs.element) { return false }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    /// Code-unit comparison — never `localeCompare` (Hermes ICU variance).
    static func byCode(_ lhs: String, _ rhs: String) -> Bool { lhs < rhs }

    /// Lexicographic `byCode(a1,b1) || byCode(a2,b2)` as a strict ordering.
    static func byCodeThenCode(_ a1: String, _ a2: String, _ b1: String, _ b2: String) -> Bool {
        a1 == b1 ? a2 < b2 : a1 < b1
    }

    static func dateAscending(_ lhs: String, _ rhs: String) -> Bool { lhs < rhs }

    // MARK: income

    static let incomeHeader = [
        "Date", "Customer", "Invoice #", "Invoice Description", "Method", "Note", "Amount",
    ]

    /// Income rows are PAYMENTS. Semantics match `collectedInRange`: voided
    /// entries excluded, legacy paid invoices contribute their one implicit
    /// entry (dated `paidAt ?? due`) with the method blanked.
    static func buildIncomeCsv(invoices: [Canonical.Invoice], start: Date, end: Date) -> String {
        var rows: [(date: String, fields: [String])] = []
        for invoice in invoices {
            for payment in NativeCashBasis.paymentsInRange(invoice, start: start, end: end) {
                if payment.voidedAt != nil { continue }
                let isLegacy = payment.id.hasPrefix("legacy_")
                rows.append((payment.date, [
                    payment.date,
                    invoice.customer,
                    invoice.number,
                    invoice.desc,
                    isLegacy ? "" : payment.method.rawValue,
                    payment.note ?? "",
                    money(payment.amount),
                ]))
            }
        }
        let sorted = stableSorted(rows) { dateAscending($0.date, $1.date) }
        return toCsv(incomeHeader, sorted.map(\.fields))
    }

    // MARK: expenses

    static let expenseHeader = ["Date", "Description", "Category", "Amount", "Notes", "Has Receipt"]

    /// Category exports the LABEL; unknown ids fall back to Other.
    static func buildExpensesCsv(expenses: [Canonical.Expense], start: Date, end: Date) -> String {
        let rows = stableSorted(expenses.filter { NativeCashBasis.isInRange($0.date, start: start, end: end) }) {
            dateAscending($0.date, $1.date)
        }.map { expense in
            [
                expense.date,
                expense.description,
                NativeExpenseCategories.label(for: expense.category),
                money(expense.amount),
                expense.notes,
                expense.receiptUri != nil ? "Yes" : "No",
            ]
        }
        return toCsv(expenseHeader, rows)
    }

    // MARK: mileage

    static let tripHeader = ["Date", "From", "To", "Purpose", "Odometer Start", "Odometer End", "Miles"]

    /// Raw trip data; miles are not money, so no decimal padding.
    static func buildTripsCsv(trips: [Canonical.Trip], start: Date, end: Date) -> String {
        let rows = stableSorted(trips.filter { NativeCashBasis.isInRange($0.date, start: start, end: end) }) {
            dateAscending($0.date, $1.date)
        }.map { trip in
            [
                trip.date,
                trip.fromLabel,
                trip.toLabel,
                trip.purpose,
                decimalString(trip.odometerStart),
                decimalString(trip.odometerEnd),
                decimalString(trip.miles),
            ]
        }
        return toCsv(tripHeader, rows)
    }

    /// `String(number)` for a canonical Decimal field.
    static func decimalString(_ value: Decimal) -> String {
        NSDecimalNumber(decimal: value).stringValue
    }

    // MARK: filenames + row counts

    /// `tradeready-<dataset>_all-time.csv`, else
    /// `tradeready-<dataset>_<start>_<end>.csv` with LOCAL dates.
    static func csvFilename(dataset: String, range: NativeDateRange, rangeID: String) -> String {
        if rangeID == "all_time" { return "tradeready-\(dataset)_all-time.csv" }
        return "tradeready-\(dataset)_\(NativeCashBasis.ymd(range.start))_\(NativeCashBasis.ymd(range.end)).csv"
    }

    /// Data rows in a built CSV (excludes the header).
    static func csvRowCount(_ csv: String) -> Int {
        csv.components(separatedBy: "\r\n").filter { !$0.isEmpty }.count - 1
    }

    // MARK: share tail (thin, mirrors shareCsv/shareZip ownership of alerts)

    enum ShareOutcome: Equatable {
        case shared
        case unavailable
        case failed
    }

    /// Companion to RN's `shareCsv`: the caller receives a typed outcome and
    /// owns the user-facing message. The BOM makes Excel read UTF-8.
    static func sharePayload(csv: String) -> Data {
        Data(("\u{FEFF}" + csv).utf8)
    }

    static func sharePayload(zipBytes: [UInt8]) -> Data {
        Data(zipBytes)
    }
}
