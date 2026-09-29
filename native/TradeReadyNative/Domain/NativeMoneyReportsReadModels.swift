import Foundation

// MARK: - Money card read models (task 9.01, requirements M2)
//
// TopCustomersCard and ReceivablesCard derivations. Both are pure; the two
// "overdue" definitions in the app are deliberately different and both are
// frozen as-is (see docs/native-phase-9-money-exports-contract-decisions.md 2.4).

extension NativeMoneyReports {
    /// `TopCustomersCard` — revenue collected per customer in the window, sorted
    /// by amount descending (stable), top `limit`. Empty customers are grouped
    /// under the literal `""` key exactly like RN's `Record<string, number>`.
    static func topCustomers(
        _ invoices: [Canonical.Invoice],
        start: Date,
        end: Date,
        limit: Int = 5
    ) -> [NativeTopCustomerRow] {
        var revenueByCustomer: [String: Decimal] = [:]
        var order: [String] = []
        for invoice in invoices {
            let collected = NativeCashBasis.collected(invoices: [invoice], start: start, end: end)
            if collected == 0 { continue }
            if revenueByCustomer[invoice.customer] == nil { order.append(invoice.customer) }
            revenueByCustomer[invoice.customer, default: 0] += collected
        }
        let rows = order.map { NativeTopCustomerRow(name: $0, amount: revenueByCustomer[$0]!) }
        // `sort((a, b) => b.amount - a.amount)` — JS Array.sort is stable, so
        // equal amounts keep first-seen order.
        let sorted = rows.enumerated().sorted { lhs, rhs in
            lhs.element.amount == rhs.element.amount
                ? lhs.offset < rhs.offset
                : lhs.element.amount > rhs.element.amount
        }.map(\.element)
        return Array(sorted.prefix(limit))
    }

    /// `ReceivablesCard`. Its "overdue" test parses `due` as a UTC-midnight
    /// instant and compares it with local-midnight today — intentionally
    /// different from `isOverdue`, which uses the local `daysPastDue` rule.
    static func receivables(
        _ invoices: [Canonical.Invoice],
        jobs: [Canonical.Job],
        now: Date
    ) -> NativeReceivables {
        let calendar = NativeCashBasis.localCalendar
        let today = calendar.startOfDay(for: now)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!

        var unpaid: [Canonical.Invoice] = []
        var outstanding = Decimal.zero
        for invoice in invoices {
            let ledger = NativeCashBasis.ledgerInvoice(invoice)
            guard !PaymentLedger.isFullyPaid(ledger) else { continue }
            unpaid.append(invoice)
            outstanding += PaymentLedger.balanceDue(ledger)
        }

        var overdueCount = 0
        var totalOverdue = Decimal.zero
        for invoice in unpaid {
            guard !invoice.due.isEmpty else { continue }
            let parts = invoice.due.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 3,
                  let date = utc.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
            else { continue }
            if date < today {
                overdueCount += 1
                totalOverdue += PaymentLedger.balanceDue(NativeCashBasis.ledgerInvoice(invoice))
            }
        }

        let pipelineJobs = jobs.filter {
            pipelineStatuses.contains($0.status) && NativeChangeOrders.billableTotal(for: $0) > 0
        }
        let pipelineValue = pipelineJobs.reduce(Decimal.zero) {
            $0 + NativeChangeOrders.billableTotal(for: $1)
        }

        return NativeReceivables(
            outstanding: outstanding,
            unpaidCount: unpaid.count,
            overdue: totalOverdue,
            overdueCount: overdueCount,
            pipelineValue: pipelineValue,
            pipelineCount: pipelineJobs.count
        )
    }
}
