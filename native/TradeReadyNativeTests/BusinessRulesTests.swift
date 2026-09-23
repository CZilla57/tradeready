import Foundation
import XCTest
@testable import TradeReadyNative

final class BusinessRulesTests: XCTestCase {
    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    func testRecurrenceMatchesJavaScriptOverflowSemantics() {
        XCTAssertEqual(
            RecurrenceRules.nextDate(after: "2026-01-31", cadence: .monthly, calendar: utcCalendar),
            "2026-03-03"
        )
        XCTAssertEqual(
            RecurrenceRules.nextDate(after: "2024-02-29", cadence: .annually, calendar: utcCalendar),
            "2025-03-01"
        )
    }

    func testInvoiceNumberingPreservesSequenceAcrossPrefixes() {
        XCTAssertEqual(
            InvoiceNumberRules.nextNumber(
                existingNumbers: ["INV-0007"],
                options: .init(prefix: "2026")
            ),
            "2026-0008"
        )
        XCTAssertEqual(
            InvoiceNumberRules.nextNumber(existingNumbers: ["A1B2"]),
            "INV-0013"
        )
    }

    func testLifecycleDoesNotRegressAndPaidInvoiceAdvancesEligibleJob() {
        XCTAssertEqual(
            JobLifecycleRules.statusAfterEstimateDecision(.scheduled, decision: .declined),
            .scheduled
        )
        let invoice = LedgerInvoice(id: "inv1", amount: 500, due: "2026-01-01", paid: true)
        let jobs = [
            LifecycleJob(id: "j1", status: .invoiced, invoiceID: "inv1"),
            LifecycleJob(id: "j2", status: .scheduled, invoiceID: "inv1"),
        ]

        XCTAssertEqual(
            JobLifecycleRules.advancePaidInvoiceJobs(jobs, invoices: [invoice]).map(\.status),
            [.paid, .scheduled]
        )
    }
}
