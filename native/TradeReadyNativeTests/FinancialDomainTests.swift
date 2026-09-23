import XCTest
@testable import TradeReadyNative

final class FinancialDomainTests: XCTestCase {
    func testPricingCombinesEmergencyLaborMarkupMarginAndTax() {
        var input = PricingInput()
        input.laborHours = 2
        input.laborRate = 100
        input.materials = [PricingMaterial(name: "Part", quantity: 2, unitCost: 50)]
        input.materialMarkup = 25
        input.overheadPercent = 10
        input.marginPercent = 20
        input.isEmergency = true
        input.emergencyMultiplier = TestSupport.decimal("1.5")
        input.minimumJobFee = 50
        input.taxPercent = 8

        let result = PricingEngine.calculate(input)

        XCTAssertEqual(result.laborCost, 300)
        XCTAssertEqual(result.materialCost, 125)
        XCTAssertEqual(result.profit, TestSupport.decimal("116.88"))
        XCTAssertEqual(result.taxAmount, TestSupport.decimal("46.75"))
        XCTAssertEqual(result.total, TestSupport.decimal("631.13"))
    }

    func testPaymentLedgerSettlementIsIdempotentAndUsesClosingPaymentDate() {
        let invoice = LedgerInvoice(id: "inv1", amount: 1_000, due: "2026-07-01")
        let late = LedgerPayment(id: "p1", amount: 400, date: "2026-07-20")
        let backdated = LedgerPayment(id: "p2", amount: 600, date: "2026-07-01")

        let settled = PaymentLedger.apply(backdated, to: PaymentLedger.apply(late, to: invoice))

        XCTAssertTrue(settled.paid)
        XCTAssertEqual(settled.paidAt, "2026-07-20")
        XCTAssertEqual(PaymentLedger.apply(backdated, to: settled).payments?.count, 2)
    }

    func testVoidingPaymentReopensInvoice() {
        let payment = LedgerPayment(id: "p1", amount: 1_000, date: "2026-07-20")
        let settled = PaymentLedger.apply(
            payment,
            to: LedgerInvoice(id: "inv1", amount: 1_000, due: "2026-07-01")
        )

        let reopened = PaymentLedger.voidPayment(id: "p1", on: settled, voidedAt: "2026-07-25")

        XCTAssertFalse(reopened.paid)
        XCTAssertNil(reopened.paidAt)
        XCTAssertEqual(PaymentLedger.amountPaid(reopened), 0)
    }
}
