import Foundation

// MARK: - Accountant package builders (task 9.06, requirement X2)
//
// Pure port of `utils/accountingPackage.ts`. No I/O, no Settings, no secrets.
// Produces a deterministic stored ZIP whose entries are byte-comparable with the
// React Native export (see the phase 9 contract doc sections 4 and 5).

struct NativeExportWarning: Equatable {
    var code: String
    var severity: String
    var subject: String
    var detail: String
}

struct NativePackageInput {
    var invoices: [Canonical.Invoice] = []
    var expenses: [Canonical.Expense] = []
    var trips: [Canonical.Trip] = []
    var customers: [Canonical.Customer] = []
    var jobNameById: [String: String] = [:]
}

struct NativePackageSummary: Equatable {
    var rangeStart: String
    var rangeEnd: String
    var cashCollected: Decimal
    var voidedAmount: Decimal
    var expensesTotal: Decimal
    var netCash: Decimal
    var netCashBasis: String
    var invoicesCount: Int
    var customersCount: Int
    var mileageTripsCount: Int
    var mileageMilesTotal: Decimal
    var warningsCount: Int
}

enum NativeAccountingPackage {
    static func round2(_ value: Decimal) -> Decimal {
        FinancialDecimal.javascriptCents(value)
    }

    // MARK: scope + provenance

    /// Recover the `YYYY-MM-DD` issue date from an invoice id's ms timestamp, or
    /// nil when the id is not a plausible timestamp. NEVER falls back to the wall
    /// clock — an accounting export must be deterministic.
    static func recoverIssueDate(_ id: String) -> String? {
        let raw = id.hasPrefix("inv") ? String(id.dropFirst(3)) : id
        guard !raw.isEmpty, raw.allSatisfy({ $0.isASCII && $0.isNumber }), let ms = Double(raw) else { return nil }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = Date(timeIntervalSince1970: ms / 1000)
        let parts = utc.dateComponents([.year, .month, .day], from: date)
        guard let year = parts.year, let month = parts.month, let day = parts.day,
              year >= 2000, year <= 2100 else { return nil }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    /// In scope when the recovered issue date falls in range OR there is at least
    /// one non-voided in-range payment.
    static func isInvoiceInScope(_ invoice: Canonical.Invoice, start: Date, end: Date) -> Bool {
        if let issue = recoverIssueDate(invoice.id), NativeCashBasis.isInRange(issue, start: start, end: end) {
            return true
        }
        return NativeCashBasis.paymentsInRange(invoice, start: start, end: end).contains { $0.voidedAt == nil }
    }

    static func paymentSource(_ id: String) -> String {
        if id.hasPrefix("stripe_") { return "stripe" }
        if id.hasPrefix("legacy_") { return "legacy" }
        return "device"
    }

    private static func invoiceStatus(_ invoice: Canonical.Invoice) -> String {
        let ledger = NativeCashBasis.ledgerInvoice(invoice)
        if PaymentLedger.isFullyPaid(ledger) { return "paid" }
        if PaymentLedger.isPartlyPaid(ledger) { return "partly_paid" }
        return "unpaid"
    }

    // MARK: builders

    static let invoicesHeader = [
        "Invoice #", "Issue Date", "Customer", "Email", "Phone",
        "Description", "Amount", "Amount Paid", "Balance Due", "Status", "Due Date", "Paid At", "Job ID",
    ]

    static func buildInvoicesCsv(_ invoices: [Canonical.Invoice], start: Date, end: Date) -> String {
        let rows = NativeCSVExport.stableSorted(
            invoices.map { (invoice: $0, issue: recoverIssueDate($0.id)) }
                .filter { isInvoiceInScope($0.invoice, start: start, end: end) }
        ) { lhs, rhs in
            if lhs.issue == rhs.issue {
                if NativeCSVExport.byCode(lhs.invoice.number, rhs.invoice.number) { return true }
                if NativeCSVExport.byCode(rhs.invoice.number, lhs.invoice.number) { return false }
                return NativeCSVExport.byCode(lhs.invoice.id, rhs.invoice.id)
            }
            if lhs.issue == nil { return false }
            if rhs.issue == nil { return true }
            return NativeCSVExport.byCode(lhs.issue!, rhs.issue!)
        }.map { row -> [String] in
            let invoice = row.invoice
            let ledger = NativeCashBasis.ledgerInvoice(invoice)
            return [
                invoice.number, row.issue ?? "", invoice.customer, invoice.email, invoice.phone,
                invoice.desc, NativeCSVExport.money(invoice.amount),
                NativeCSVExport.money(PaymentLedger.amountPaid(ledger)),
                NativeCSVExport.money(PaymentLedger.balanceDue(ledger)),
                invoiceStatus(invoice), invoice.due, invoice.paidAt ?? "", invoice.jobId ?? "",
            ]
        }
        return NativeCSVExport.toCsv(invoicesHeader, rows)
    }

    static let lineItemsHeader = ["Invoice #", "Description", "Category", "Amount"]

    static func buildLineItemsCsv(_ invoices: [Canonical.Invoice], start: Date, end: Date) -> String {
        let inScope = NativeCSVExport.stableSorted(invoices.filter { isInvoiceInScope($0, start: start, end: end) }) {
            NativeCSVExport.byCodeThenCode($0.number, $0.id, $1.number, $1.id)
        }
        var rows: [[String]] = []
        for invoice in inScope {
            for item in invoice.lineItems ?? [] {
                rows.append([invoice.number, item.description, item.category, NativeCSVExport.money(item.amount)])
            }
        }
        return NativeCSVExport.toCsv(lineItemsHeader, rows)
    }

    static let activityHeader = [
        "Date", "Customer", "Invoice #", "Method", "Note", "Amount", "Voided", "Voided At", "Source",
    ]

    static func buildPaymentActivityCsv(_ invoices: [Canonical.Invoice], start: Date, end: Date) -> String {
        var rows: [(date: String, id: String, fields: [String])] = []
        for invoice in invoices {
            for payment in NativeCashBasis.paymentsInRange(invoice, start: start, end: end) {
                let isLegacy = payment.id.hasPrefix("legacy_")
                rows.append((payment.date, payment.id, [
                    payment.date, invoice.customer, invoice.number,
                    isLegacy ? "" : payment.method.rawValue, payment.note ?? "",
                    NativeCSVExport.money(payment.amount),
                    payment.voidedAt != nil ? "Yes" : "No", payment.voidedAt ?? "",
                    paymentSource(payment.id),
                ]))
            }
        }
        let sorted = NativeCSVExport.stableSorted(rows) {
            $0.date == $1.date ? NativeCSVExport.byCode($0.id, $1.id) : $0.date < $1.date
        }
        return NativeCSVExport.toCsv(activityHeader, sorted.map(\.fields))
    }

    static let expenses2Header = ["Date", "Description", "Category", "Amount", "Notes", "Job", "Has Receipt"]

    static func buildExpensesCsv2(
        _ expenses: [Canonical.Expense],
        start: Date,
        end: Date,
        jobNameById: [String: String]
    ) -> String {
        let rows = NativeCSVExport.stableSorted(expenses.filter { NativeCashBasis.isInRange($0.date, start: start, end: end) }) {
            $0.date == $1.date ? NativeCSVExport.byCode($0.id, $1.id) : $0.date < $1.date
        }.map { expense -> [String] in
            let job = expense.jobId.flatMap { jobNameById[$0] } ?? ""
            return [
                expense.date, expense.description,
                NativeExpenseCategories.label(for: expense.category),
                NativeCSVExport.money(expense.amount), expense.notes, job,
                expense.receiptUri != nil ? "Yes" : "No",
            ]
        }
        return NativeCSVExport.toCsv(expenses2Header, rows)
    }

    static let customersHeader = ["Name", "Email", "Phone", "Address", "Notes", "Created", "Archived"]

    static func buildCustomersCsv(_ customers: [Canonical.Customer]) -> String {
        let rows = NativeCSVExport.stableSorted(customers) {
            NativeCSVExport.byCodeThenCode($0.name, $0.id, $1.name, $1.id)
        }.map { customer in
            [
                customer.name, customer.email, customer.phone, customer.address,
                customer.notes, customer.createdAt ?? "", customer.archivedAt ?? "",
            ]
        }
        return NativeCSVExport.toCsv(customersHeader, rows)
    }

    static let categoryHeader = ["Category ID", "Label"]

    static func buildCategoryMappingCsv() -> String {
        NativeCSVExport.toCsv(categoryHeader, NativeExpenseCategories.all.map { [$0.id, $0.label] })
    }

    // MARK: warnings

    static func collectWarnings(_ input: NativePackageInput, start: Date, end: Date) -> [NativeExportWarning] {
        var warnings: [NativeExportWarning] = []
        func push(_ code: String, _ severity: String, _ subject: String, _ detail: String) {
            warnings.append(NativeExportWarning(code: code, severity: severity, subject: subject, detail: detail))
        }

        let inScopeInvoices = input.invoices.filter { isInvoiceInScope($0, start: start, end: end) }
        let activeRows = NativeCSVExport.csvRowCount(NativeCSVExport.buildIncomeCsv(invoices: input.invoices, start: start, end: end))
        let expenseRows = input.expenses.filter { NativeCashBasis.isInRange($0.date, start: start, end: end) }.count
        let tripRows = input.trips.filter { NativeCashBasis.isInRange($0.date, start: start, end: end) }.count
        let hasPaymentActivity = input.invoices.contains {
            !NativeCashBasis.paymentsInRange($0, start: start, end: end).isEmpty
        }

        for invoice in inScopeInvoices {
            let subject = invoice.number.isEmpty ? invoice.id : invoice.number
            if recoverIssueDate(invoice.id) == nil {
                push("missing_issue_date", "warn", subject, "Issue date could not be recovered; left blank.")
            }
            if (invoice.lineItems ?? []).isEmpty {
                push("missing_line_items", "info", subject, "Invoice has no itemised breakdown.")
            }
            if (invoice.payments ?? []).isEmpty && invoice.paid {
                push("legacy_invoice_no_ledger", "info", subject, "Paid before payment history existed; derived from the paid flag.")
            }
            let overpaid = PaymentLedger.overpaidAmount(NativeCashBasis.ledgerInvoice(invoice))
            if overpaid > 0 {
                push("overpayment_present", "warn", subject, "Overpaid by \(NativeCSVExport.money(overpaid)).")
            }
        }

        for invoice in input.invoices {
            if NativeCashBasis.paymentsInRange(invoice, start: start, end: end).contains(where: { $0.voidedAt != nil }) {
                push("voided_payments_present", "info", invoice.number.isEmpty ? invoice.id : invoice.number,
                     "Contains voided payments (see payment-activity.csv).")
            }
        }

        for expense in input.expenses where NativeCashBasis.isInRange(expense.date, start: start, end: end) {
            if !NativeExpenseCategories.all.contains(where: { $0.id == expense.category }) {
                push("unknown_expense_category", "warn", expense.description.isEmpty ? expense.id : expense.description,
                     "Unknown category \"\(expense.category)\"; mapped to Other.")
            }
        }

        if tripRows > 0 {
            push("mileage_is_device_local", "info", "mileage.csv", "Trips are stored on this device only; another device may hold others.")
        }

        if activeRows == 0 && expenseRows == 0 && tripRows == 0 && inScopeInvoices.isEmpty
            && input.customers.isEmpty && !hasPaymentActivity {
            push("no_records_in_range", "info", "range", "No records fell in the selected date range.")
        }

        return warnings
    }

    static let warningsHeader = ["Code", "Severity", "Subject", "Detail"]

    static func buildWarningsCsv(_ warnings: [NativeExportWarning]) -> String {
        NativeCSVExport.toCsv(warningsHeader, warnings.map { [$0.code, $0.severity, $0.subject, $0.detail] })
    }

    // MARK: summary + README

    static func buildSummary(_ input: NativePackageInput, start: Date, end: Date) -> NativePackageSummary {
        let cash = NativeCashBasis.collected(invoices: input.invoices, start: start, end: end)
        var voided = Decimal.zero
        for invoice in input.invoices {
            for payment in NativeCashBasis.paymentsInRange(invoice, start: start, end: end) where payment.voidedAt != nil {
                voided += payment.amount
            }
        }
        let expensesTotal = input.expenses
            .filter { NativeCashBasis.isInRange($0.date, start: start, end: end) }
            .reduce(Decimal.zero) { $0 + $1.amount }
        let inScopeCount = input.invoices.filter { isInvoiceInScope($0, start: start, end: end) }.count
        let trips = input.trips.filter { NativeCashBasis.isInRange($0.date, start: start, end: end) }
        let cashCollected = round2(cash)
        let expensesRounded = round2(expensesTotal)

        return NativePackageSummary(
            rangeStart: NativeCashBasis.ymd(start),
            rangeEnd: NativeCashBasis.ymd(end),
            cashCollected: cashCollected,
            voidedAmount: round2(voided),
            expensesTotal: expensesRounded,
            netCash: round2(cashCollected - expensesRounded),
            netCashBasis: "cash basis; before owner labor",
            invoicesCount: inScopeCount,
            customersCount: input.customers.count,
            mileageTripsCount: trips.count,
            mileageMilesTotal: round2(trips.reduce(Decimal.zero) { $0 + $1.miles }),
            warningsCount: collectWarnings(input, start: start, end: end).count
        )
    }

    /// `JSON.stringify(summary, null, 2)` — fixed key order, no trailing newline,
    /// two-space indent, JS number formatting.
    static func buildSummaryJson(_ summary: NativePackageSummary) -> String {
        let lines: [String] = [
            "{",
            "  \"range_start\": \(quoted(summary.rangeStart)),",
            "  \"range_end\": \(quoted(summary.rangeEnd)),",
            "  \"cash_collected\": \(number(summary.cashCollected)),",
            "  \"voided_amount\": \(number(summary.voidedAmount)),",
            "  \"expenses_total\": \(number(summary.expensesTotal)),",
            "  \"net_cash\": \(number(summary.netCash)),",
            "  \"net_cash_basis\": \(quoted(summary.netCashBasis)),",
            "  \"invoices_count\": \(summary.invoicesCount),",
            "  \"customers_count\": \(summary.customersCount),",
            "  \"mileage_trips_count\": \(summary.mileageTripsCount),",
            "  \"mileage_miles_total\": \(number(summary.mileageMilesTotal)),",
            "  \"warnings_count\": \(summary.warningsCount)",
            "}",
        ]
        return lines.joined(separator: "\n")
    }

    private static func quoted(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private static func number(_ value: Decimal) -> String {
        NSDecimalNumber(decimal: value).stringValue
    }

    static func buildReadme(_ summary: NativePackageSummary) -> String {
        [
            "TradeReady accounting export",
            "Date range: \(summary.rangeStart) to \(summary.rangeEnd)",
            "",
            "Income is reported on a cash basis: a payment appears on the date the money",
            "was actually received, so deposits and partial payments land in the right period.",
            "",
            "Files:",
            "  invoices.csv            One row per invoice (issue date, amount, paid, balance, status).",
            "  invoice-line-items.csv  Itemised breakdown; absent for manually-created invoices.",
            "  active-payments.csv     Money received (voided payments excluded). Cash-basis income.",
            "  payment-activity.csv    Every payment including voided ones, with void dates.",
            "  expenses.csv            Business expenses; Job column links to a job when set.",
            "  mileage.csv             Logged drives (raw miles; apply your own rate).",
            "  customers.csv           Customer contact details.",
            "  category-mapping.csv    Expense category id -> label reference.",
            "  export-warnings.csv     Anything the export could not fully determine.",
            "  summary.json            Control totals for reconciliation.",
            "",
            "Notes:",
            "  - No values are inferred. Unknown fields are left blank and flagged in export-warnings.csv.",
            "  - There is no refund concept in the app; only voids are recorded.",
            "  - Mileage and receipts are stored on the device only and may differ between devices.",
            "  - net_cash in summary.json is cash collected minus expenses (before paying yourself).",
            "",
        ].joined(separator: "\n")
    }

    static func packageFilename(start: Date, end: Date, allTime: Bool) -> String {
        if allTime { return "TradeReady-Accounting_all-time.zip" }
        return "TradeReady-Accounting_\(NativeCashBasis.ymd(start))_\(NativeCashBasis.ymd(end)).zip"
    }

    /// Fixed entry order; CSV entries carry a UTF-8 BOM, `summary.json` and
    /// `README.txt` do not.
    static func buildAccountingPackage(
        _ input: NativePackageInput,
        start: Date,
        end: Date
    ) -> (filename: String, bytes: [UInt8]) {
        let summary = buildSummary(input, start: start, end: end)
        let warnings = collectWarnings(input, start: start, end: end)

        func csv(_ name: String, _ body: String) -> NativeZipEntry {
            NativeZipEntry(name: name, bytes: NativeZipArchive.utf8Encode("\u{FEFF}" + body))
        }
        func text(_ name: String, _ body: String) -> NativeZipEntry {
            NativeZipEntry(name: name, bytes: NativeZipArchive.utf8Encode(body))
        }

        let entries: [NativeZipEntry] = [
            csv("invoices.csv", buildInvoicesCsv(input.invoices, start: start, end: end)),
            csv("invoice-line-items.csv", buildLineItemsCsv(input.invoices, start: start, end: end)),
            csv("active-payments.csv", NativeCSVExport.buildIncomeCsv(invoices: input.invoices, start: start, end: end)),
            csv("payment-activity.csv", buildPaymentActivityCsv(input.invoices, start: start, end: end)),
            csv("expenses.csv", buildExpensesCsv2(input.expenses, start: start, end: end, jobNameById: input.jobNameById)),
            csv("mileage.csv", NativeCSVExport.buildTripsCsv(trips: input.trips, start: start, end: end)),
            csv("customers.csv", buildCustomersCsv(input.customers)),
            csv("category-mapping.csv", buildCategoryMappingCsv()),
            csv("export-warnings.csv", buildWarningsCsv(warnings)),
            text("summary.json", buildSummaryJson(summary)),
            text("README.txt", buildReadme(summary)),
        ]

        let allTime = start.timeIntervalSince1970 == 0
        return (packageFilename(start: start, end: end, allTime: allTime), NativeZipArchive.buildZip(entries))
    }
}
