import Foundation

private var failures = 0

private func decimal(_ text: String) -> Decimal { FinancialDecimal.value(text) }

private func expect(
    _ actual: @autoclosure () -> Decimal,
    _ expected: Decimal,
    _ label: String
) {
    let value = actual()
    guard value == expected else {
        failures += 1
        print("FAIL: \(label) — expected \(expected), got \(value)")
        return
    }
}

private func expect(_ actual: @autoclosure () -> Bool, _ expected: Bool, _ label: String) {
    let value = actual()
    guard value == expected else {
        failures += 1
        print("FAIL: \(label) — expected \(expected), got \(value)")
        return
    }
}

private func expect<T: Equatable>(_ actual: @autoclosure () -> T, _ expected: T, _ label: String) {
    let value = actual()
    guard value == expected else {
        failures += 1
        print("FAIL: \(label) — expected \(expected), got \(value)")
        return
    }
}

private func invoice(
    id: String = "inv1",
    amount: Decimal = 1000,
    due: String = "2026-07-01",
    paid: Bool = false,
    paidAt: String? = nil,
    payments: [LedgerPayment]? = nil
) -> LedgerInvoice {
    LedgerInvoice(id: id, amount: amount, due: due, paid: paid, paidAt: paidAt, payments: payments)
}

private func payment(
    id: String,
    amount: Decimal,
    date: String = "2026-07-20",
    voidedAt: String? = nil
) -> LedgerPayment {
    LedgerPayment(id: id, amount: amount, date: date, voidedAt: voidedAt)
}

// Pricing vectors copied from the React Native Jest suite.
do {
    var input = PricingInput()
    input.laborHours = 2
    input.laborRate = 100
    input.minimumJobFee = 0
    let result = PricingEngine.calculate(input)
    expect(result.laborCost, 200, "labor cost")
    expect(result.overheadCost, 30, "labor overhead")
    expect(result.profit, decimal("57.5"), "true-margin profit")
    expect(result.total, decimal("287.5"), "labor-only total")
    expect(result.hitMinimum, false, "labor job does not hit minimum")
}

do {
    var input = PricingInput()
    input.laborHours = 2
    input.laborRate = 100
    input.materials = [PricingMaterial(name: "Part", quantity: 2, unitCost: 50)]
    input.materialMarkup = 25
    input.overheadPercent = 10
    input.marginPercent = 20
    input.isEmergency = true
    input.emergencyMultiplier = decimal("1.5")
    input.minimumJobFee = 50
    input.taxPercent = 8
    let result = PricingEngine.calculate(input)
    expect(result.laborCost, 300, "combined labor")
    expect(result.materialCost, 125, "combined materials")
    expect(result.subtotal, 425, "combined subtotal")
    expect(result.overheadCost, decimal("42.5"), "combined overhead")
    expect(result.profit, decimal("116.88"), "combined profit rounding")
    expect(result.preTaxTotal, decimal("584.38"), "combined pre-tax rounding")
    expect(result.taxAmount, decimal("46.75"), "combined tax")
    expect(result.total, decimal("631.13"), "combined total")
}

do {
    var input = PricingInput()
    input.laborHours = 2
    input.laborRate = 100
    input.overheadPercent = 0
    input.marginPercent = 20
    input.minimumJobFee = 0
    input.jobCosts = [PricingDirectCost(
        id: "permit",
        label: "City permit",
        category: .permit,
        quantity: 1,
        unitCost: 150,
        markupPercent: 0,
        markupPolicy: .passthrough,
        taxable: false,
        customerVisible: true
    )]
    let result = PricingEngine.calculate(input)
    expect(result.directCostPassthrough, 150, "permit passthrough")
    expect(result.totalBeforeTax, 400, "passthrough outside margin")
    expect(result.profit, 50, "passthrough earns no profit")
    expect(PricingEngine.breakEvenPrice(input), 350, "passthrough break-even")
}

do {
    var input = PricingInput()
    input.laborHours = decimal("0.05")
    input.laborRate = 100
    input.overheadPercent = 0
    input.marginPercent = 0
    input.minimumJobFee = 75
    input.taxPercent = 10
    input.jobCosts = [PricingDirectCost(
        id: "permit",
        label: "Permit",
        category: .permit,
        quantity: 1,
        unitCost: 150,
        markupPolicy: .passthrough,
        taxable: false
    )]
    let result = PricingEngine.calculate(input)
    expect(result.totalBeforeTax, 225, "minimum before passthrough")
    expect(result.taxAmount, decimal("7.5"), "tax excludes permit")
    expect(result.total, decimal("232.5"), "minimum, permit, and tax total")
}

do {
    var input = PricingInput()
    input.laborHours = 2
    input.laborRate = 100
    input.overheadPercent = 0
    input.marginPercent = 100
    input.minimumJobFee = 0
    let result = PricingEngine.calculate(input)
    expect(result.totalBeforeTax, 20000, "100 percent margin clamps to 99")
    expect(result.profit, 19800, "clamped profit")
}

// Payment parity vectors and mutation invariants.
do {
    let legacy = invoice(paid: true, paidAt: "2026-06-15")
    expect(PaymentLedger.amountPaid(legacy), 1000, "legacy paid amount")
    expect(PaymentLedger.materializeLegacyLedger(legacy).first?.date, "2026-06-15", "paidAt precedes due")

    let partial = invoice(paid: true, payments: [payment(id: "p1", amount: 400)])
    expect(PaymentLedger.amountPaid(partial), 400, "ledger overrides stale paid flag")
    expect(PaymentLedger.balanceDue(partial), 600, "partial balance")
    expect(PaymentLedger.isFullyPaid(partial), false, "partial is not paid")

    let epsilon = invoice(amount: 100, payments: [payment(id: "p1", amount: decimal("99.997"))])
    expect(PaymentLedger.balanceDue(epsilon), decimal("0.003"), "sub-cent balance retained")
    expect(PaymentLedger.isFullyPaid(epsilon), true, "sub-cent shortfall settles")

    let exactBoundary = invoice(amount: decimal("0.005"), paid: false)
    expect(PaymentLedger.isFullyPaid(exactBoundary), true, "epsilon boundary is inclusive")

    let allVoided = invoice(paid: true, payments: [payment(id: "p1", amount: 1000, voidedAt: "2026-07-22")])
    expect(PaymentLedger.amountPaid(allVoided), 0, "voided ledger does not use legacy fallback")
    expect(PaymentLedger.isFullyPaid(allVoided), false, "voided payment reopens invoice")
}

do {
    let base = invoice()
    let late = payment(id: "p1", amount: 400, date: "2026-07-20")
    let backdated = payment(id: "p2", amount: 600, date: "2026-07-01")
    let afterLate = PaymentLedger.apply(late, to: base)
    let settled = PaymentLedger.apply(backdated, to: afterLate)
    expect(settled.paid, true, "two payments settle")
    expect(settled.paidAt, "2026-07-20", "paidAt uses chronological closing payment")
    expect(PaymentLedger.apply(backdated, to: settled).payments?.count, 2, "payment id is idempotent")

    let reopened = PaymentLedger.voidPayment(id: "p2", on: settled, voidedAt: "2026-07-25")
    expect(reopened.paid, false, "void reopens invoice")
    expect(reopened.paidAt, nil, "void clears paidAt")
    let revoided = PaymentLedger.voidPayment(id: "p2", on: reopened, voidedAt: "2026-07-26")
    expect(revoided.payments?.first(where: { $0.id == "p2" })?.voidedAt, "2026-07-25", "revoid preserves first date")
}

do {
    let local = invoice(payments: [payment(id: "shared", amount: 500, voidedAt: "2026-07-24")])
    let remote = invoice(payments: [payment(id: "shared", amount: 500, voidedAt: "2026-07-22")])
    let merged = PaymentLedger.merge(local: local, remote: remote)
    expect(merged.payments?.first?.voidedAt, "2026-07-22", "merge keeps earliest void")

    let partlyPaid = invoice(amount: 1000, payments: [payment(id: "p1", amount: 600)])
    expect(PaymentLedger.resolveDepositAmount(for: partlyPaid, specification: .percent(50)), 400, "deposit clamps to balance")
    expect(PaymentLedger.resolveDepositAmount(for: partlyPaid, specification: .fixed(0)), 0, "invalid deposit is zero")
}

// Pricing edge vectors not covered by the first native slice.
do {
    var input = PricingInput()
    input.minimumJobFee = 0
    input.overheadPercent = 10
    input.marginPercent = 20
    input.jobCosts = [PricingDirectCost(
        id: "sub",
        label: "Licensed subcontractor",
        category: .subcontractor,
        quantity: 1,
        unitCost: 500,
        markupPercent: 10,
        markupPolicy: .inMarginBase,
        taxable: false,
        customerVisible: false
    )]
    let result = PricingEngine.calculate(input)
    expect(result.directCostMarginBase, 550, "marked-up direct cost enters margin base")
    expect(result.overheadCost, 55, "direct cost earns overhead")
    expect(result.totalBeforeTax, decimal("756.25"), "direct cost earns true margin")
    expect(result.directCostLines.first?.customerVisible, false, "hidden direct line retained")
}

do {
    for category in PricingCostCategory.allCases {
        let expected: PricingMarkupPolicy = category == .permit ? .passthrough : .inMarginBase
        expect(PricingEngine.defaultMarkupPolicy(for: category), expected, "default direct-cost policy \(category.rawValue)")
    }

    var taxable = PricingInput()
    taxable.laborHours = 1
    taxable.laborRate = 100
    taxable.overheadPercent = 0
    taxable.marginPercent = 0
    taxable.minimumJobFee = 0
    taxable.taxPercent = 10
    taxable.jobCosts = [PricingDirectCost(
        id: "permit",
        label: "Permit",
        category: .permit,
        quantity: 1,
        unitCost: 200,
        markupPolicy: .passthrough,
        taxable: true
    )]
    expect(PricingEngine.calculate(taxable).taxAmount, 30, "taxable passthrough stays in tax base")

    taxable.marginPercent = -20
    taxable.taxPercent = 0
    taxable.jobCosts = []
    expect(PricingEngine.calculate(taxable).total, 100, "negative margin clamps to zero")
}

// Labor-time detail remains one canonical billable-hours total, while pricing
// sanity and travel checks are deterministic advisories rather than save gates.
do {
    expect(PricingEngine.laborBreakdownTotal(
        onSite: 2,
        drive: decimal("0.5"),
        supplyRun: decimal("0.25"),
        setupCleanup: decimal("0.5")
    ), decimal("3.25"), "labor breakdown sums all four billable buckets")

    var ordinary = PricingInput()
    ordinary.laborHours = 2
    ordinary.laborRate = 100
    ordinary.minimumJobFee = 0
    expect(PricingEngine.advisories(ordinary), [], "ordinary estimate has no advisories")

    var driveAndMiles = ordinary
    driveAndMiles.travelMiles = 20
    expect(PricingEngine.advisories(driveAndMiles, driveHours: 1).contains(.driveTimeAndMileage),
           true,
           "drive hours plus mileage produces the matching advisory")

    var driveAndTravelCost = ordinary
    driveAndTravelCost.jobCosts = [PricingDirectCost(
        id: "travel",
        label: "Travel",
        category: .travel,
        quantity: 1,
        unitCost: 25
    )]
    expect(PricingEngine.advisories(driveAndTravelCost, driveHours: 1).contains(.driveTimeAndTravelCost),
           true,
           "drive hours plus a travel cost produces the matching advisory")

    var milesAndDelivery = driveAndTravelCost
    milesAndDelivery.travelMiles = 15
    milesAndDelivery.jobCosts[0].category = .delivery
    expect(PricingEngine.advisories(milesAndDelivery).contains(.mileageAndTravelCost),
           true,
           "mileage plus a delivery cost produces the matching advisory")

    var driveAndPermit = ordinary
    driveAndPermit.jobCosts = [PricingDirectCost(
        id: "permit",
        label: "Permit",
        category: .permit,
        quantity: 1,
        unitCost: 25
    )]
    expect(PricingEngine.advisories(driveAndPermit, driveHours: 1).contains(.driveTimeAndTravelCost),
           false,
           "non-travel direct costs do not produce travel advisories")

    var minimumAndShort = PricingInput()
    minimumAndShort.laborHours = decimal("0.25")
    minimumAndShort.laborRate = 100
    minimumAndShort.minimumJobFee = 75
    let minimumAndShortAdvisories = PricingEngine.advisories(minimumAndShort)
    expect(minimumAndShortAdvisories.contains(.minimumFeeApplied(75)), true, "minimum fee advisory")
    expect(minimumAndShortAdvisories.contains(.veryShortLabor), true, "very short labor advisory")
}

// Remaining payment-ledger helpers and edge cases.
do {
    let july = invoice(payments: [
        payment(id: "p1", amount: 100, date: "2026-06-30"),
        payment(id: "p2", amount: 200, date: "2026-07-01"),
        payment(id: "p3", amount: 300, date: "2026-07-31", voidedAt: "2026-08-01"),
        payment(id: "p4", amount: 400, date: "2026-08-01"),
    ])
    expect(PaymentLedger.payments(for: july, from: "2026-07-01", through: "2026-07-31").count, 2, "payment range is inclusive and retains voids")
    expect(PaymentLedger.collected(from: [july], from: "2026-07-01", through: "2026-07-31"), 200, "range collection excludes voids")
    let buckets = PaymentLedger.collectedByPeriod([july], ranges: [
        ("2026-06-01", "2026-07-01"),
        ("2026-07-01", "2026-08-31"),
    ])
    expect(buckets, [300, 600], "one-pass overlapping collection buckets")

    let partial = invoice(payments: [payment(id: "p1", amount: 400)])
    let settled = PaymentLedger.settleRemaining(partial, on: "2026-07-21", paymentID: "settle")
    expect(PaymentLedger.amountPaid(settled), 1000, "settle remaining records exact balance")
    expect(settled.paidAt, "2026-07-21", "settle remaining sets closing date")
    expect(PaymentLedger.settleRemaining(settled, on: "2026-07-22", paymentID: "unused").payments?.count, 2, "settling paid invoice is no-op")

    let deposit = LedgerInvoice(
        id: "deposit",
        amount: 1000,
        due: "2026-08-01",
        payments: [payment(id: "p1", amount: decimal("499.996"))],
        depositRequest: DepositRequest(amount: 500)
    )
    expect(PaymentLedger.isDepositSatisfied(deposit), true, "deposit satisfaction uses paid epsilon")
    expect(PaymentLedger.overpaidAmount(invoice(amount: 1000, payments: [payment(id: "p1", amount: 1200)])), 200, "overpayment is explicit")
}

// Tax set-aside golden vectors from taxEstimate.test.js.
do {
    expect(TaxEstimateEngine.selfEmploymentNetEarningsFactor, decimal("0.9235"), "SE net-earnings factor")
    expect(TaxEstimateEngine.socialSecurityRate + TaxEstimateEngine.medicareRate, decimal("0.153"), "combined SE rate")
    expect(TaxEstimateEngine.socialSecurityWageBase[2026], 184500, "2026 Social Security wage base")

    let split = TaxEstimateEngine.splitDeductibleExpenses([
        TaxExpense(amount: 300, category: "materials", date: "2026-07-01"),
        TaxExpense(amount: 200, category: "fuel", date: "2026-07-02"),
        TaxExpense(amount: 50, category: "tools", date: "2026-07-03"),
        TaxExpense(amount: 999, category: "tools", date: "2026-01-15"),
    ], from: "2026-06-01", through: "2026-08-31")
    expect(split.nonVehicle, 350, "tax expenses exclude fuel and out-of-window rows")
    expect(split.fuel, 200, "tax fuel held apart")

    expect(TaxEstimateEngine.resolveVehicleDeduction(method: .mileage, miles: 100, mileageRate: decimal("0.7"), fuelExpenses: 500), VehicleDeductionResult(deduction: 70, needsChoice: false), "mileage election")
    expect(TaxEstimateEngine.resolveVehicleDeduction(method: .actual, miles: 100, mileageRate: decimal("0.7"), fuelExpenses: 500), VehicleDeductionResult(deduction: 500, needsChoice: false), "actual vehicle-cost election")
    expect(TaxEstimateEngine.resolveVehicleDeduction(method: nil, miles: 100, mileageRate: decimal("0.7"), fuelExpenses: 500), VehicleDeductionResult(deduction: 0, needsChoice: true), "unset vehicle election deducts neither")

    let worked = TaxEstimateEngine.estimate(TaxEstimateInput(
        collectedIncome: 10000,
        deductibleExpenses: 2000,
        vehicleDeduction: 500,
        incomeRatePercent: 12,
        year: 2026
    ))
    expect(worked.netProfit, 7500, "tax worked net profit")
    expect(worked.selfEmploymentTax, decimal("1059.72"), "tax worked SE tax")
    expect(worked.incomeTax, decimal("836.42"), "tax worked income tax")
    expect(worked.reserve, decimal("1896.13"), "tax worked reserve")
    expect(worked.ratesKnown, true, "known tax-year rate")

    let capped = TaxEstimateEngine.estimate(TaxEstimateInput(collectedIncome: 250000, deductibleExpenses: 0, vehicleDeduction: 0, incomeRatePercent: 0, year: 2026))
    expect(capped.selfEmploymentTax, decimal("29573.38"), "Social Security caps but Medicare does not")
    let loss = TaxEstimateEngine.estimate(TaxEstimateInput(collectedIncome: 1000, deductibleExpenses: 5000, vehicleDeduction: 0, incomeRatePercent: 20, year: 2026))
    expect(loss.netProfit, -4000, "tax loss retained")
    expect(loss.reserve, 0, "tax loss never creates negative reserve")
    let unknown = TaxEstimateEngine.estimate(TaxEstimateInput(collectedIncome: 10000, deductibleExpenses: 0, vehicleDeduction: 0, incomeRatePercent: 10, year: 2030))
    expect(unknown.ratesKnown, false, "unknown tax year flagged")
}

do {
    let periods = TaxEstimateEngine.periods(for: 2026)
    expect(periods.map(\.start), ["2026-01-01", "2026-04-01", "2026-06-01", "2026-09-01"], "uneven tax-period starts")
    expect(periods.map(\.end), ["2026-03-31", "2026-05-31", "2026-08-31", "2026-12-31"], "uneven tax-period ends")
    expect(periods.map(\.due), ["2026-04-15", "2026-06-15", "2026-09-15", "2027-01-15"], "2026 estimated-tax deadlines")
    expect(TaxEstimateEngine.periods(for: 2027)[3].due, "2028-01-17", "Saturday deadline shifts to Monday")
    expect(TaxEstimateEngine.periods(for: 2029)[0].due, "2029-04-16", "Sunday deadline shifts to Monday")
    expect(TaxEstimateEngine.currentPeriod(on: "2026-06-01").quarter, 3, "June income belongs to tax period three")

    let invoices = [
        invoice(id: "i1", amount: 1500, payments: [
            payment(id: "p1", amount: 1000, date: "2026-06-15"),
            payment(id: "p2", amount: 500, date: "2026-02-10"),
        ]),
        invoice(id: "i2", amount: 800, due: "2026-05-01", paid: true, paidAt: "2026-04-20"),
    ]
    let expenses = [
        TaxExpense(amount: 300, category: "materials", date: "2026-07-02"),
        TaxExpense(amount: 200, category: "fuel", date: "2026-07-01"),
        TaxExpense(amount: 100, category: "tools", date: "2026-03-01"),
    ]
    let trips = [
        TaxTrip(date: "2026-06-20", miles: 100),
        TaxTrip(date: "2026-01-15", miles: 50),
    ]
    let mileage = TaxEstimateEngine.summarize(
        invoices: invoices,
        expenses: expenses,
        trips: trips,
        settings: TaxWindowSettings(
            mileageRate: decimal("0.7"),
            incomeRatePercent: 10,
            vehicleDeductionMethod: .mileage
        ),
        on: "2026-07-18"
    )
    expect(mileage.period.quarter, 3, "tax summary current period")
    expect(mileage.current.netProfit, 630, "tax summary period uses ledger income and mileage")
    expect(mileage.yearToDate.netProfit, 1795, "tax summary YTD window")
    expect(mileage.yearToDateTripCount, 2, "tax summary trip count")
    expect(mileage.needsVehicleChoice, false, "chosen mileage method")

    let unset = TaxEstimateEngine.summarize(
        invoices: invoices,
        expenses: expenses,
        trips: trips,
        settings: TaxWindowSettings(mileageRate: decimal("0.7")),
        on: "2026-07-18"
    )
    expect(unset.current.netProfit, 700, "unset vehicle method deducts neither")
    expect(unset.needsVehicleChoice, true, "tax summary requests vehicle election")
    expect(unset.incomeRateSet, false, "tax summary distinguishes unset income rate")
}

// Profitability vectors from jobProfitability.test.ts and direct-cost coverage.
do {
    let invoices = [LedgerInvoice(
        id: "inv1",
        amount: 1166,
        due: "2026-08-10",
        paid: true,
        paidAt: "2026-08-05",
        payments: [
            LedgerPayment(id: "p1", amount: 300, date: "2026-08-01", method: .check),
            LedgerPayment(id: "stripe_cs_1", amount: 866, date: "2026-08-05", method: .stripe),
        ]
    )]
    let result = JobProfitabilityEngine.calculate(ProfitabilityInput(
        estimatedRevenue: 966,
        approvedChangeOrderRevenue: 200,
        estimatedLaborHours: 4,
        billableLaborRate: 85,
        actualLaborHours: decimal("5.5"),
        ownerLaborCostRate: nil,
        estimatedMaterialCost: 300,
        estimatedDirectCost: 0,
        linkedExpenses: [
            ProfitabilityExpense(amount: 340, category: "materials"),
            ProfitabilityExpense(amount: 25, category: "fuel"),
        ],
        linkedInvoices: invoices
    ))
    expect(result.finalBillable, 1166, "profitability final billable")
    expect(result.cashCollected, 1166, "profitability ledger cash")
    expect(result.actualLaborHours, decimal("5.5"), "profitability actual hours")
    expect(result.materialsVariance, 40, "profitability materials variance")
    expect(result.estimatedGrossProfit, 666, "profitability estimated gross profit")
    expect(result.actualGrossProfitBilled, 801, "profitability billed gross profit")
    expect(result.effectiveHourlyActual, decimal("145.64"), "profitability effective hourly")
    expect(result.warnings, [.feesUnknown, .laborCostRateUnset], "profitability warning order")
}

do {
    let unknown = JobProfitabilityEngine.calculate(ProfitabilityInput(
        estimatedRevenue: 600,
        estimatedLaborHours: 3,
        actualLaborHours: nil,
        ownerLaborCostRate: nil,
        linkedExpenses: nil,
        linkedInvoices: [invoice(id: "legacy", amount: 600, paid: true)]
    ))
    expect(unknown.actualLaborHours, nil, "unknown hours stay nil")
    expect(unknown.actualMaterialExpense, nil, "unknown expenses stay nil")
    expect(unknown.actualGrossProfitBilled, 600, "known-component profitability")
    expect(unknown.warnings, [.hoursUntracked, .expensesUnlinked, .laborCostRateUnset, .legacyInvoiceDates], "legacy profitability warnings")

    let direct = JobProfitabilityEngine.calculate(ProfitabilityInput(
        estimatedRevenue: 700,
        actualLaborHours: 0,
        ownerLaborCostRate: 0,
        estimatedDirectCost: 650,
        linkedExpenses: [ProfitabilityExpense(amount: 520, category: "labor")]
    ))
    expect(direct.estimatedGrossProfit, 50, "estimated direct basis prevents fabricated profit")
    expect(direct.directCostVariance, -130, "actual direct-cost variance")
}

do {
    let costed = JobProfitabilityEngine.calculate(ProfitabilityInput(
        estimatedRevenue: 966,
        approvedChangeOrderRevenue: 200,
        estimatedLaborHours: 4,
        billableLaborRate: 85,
        actualLaborHours: decimal("5.5"),
        ownerLaborCostRate: 40,
        estimatedMaterialCost: 300,
        linkedExpenses: [
            ProfitabilityExpense(amount: 340, category: "materials"),
            ProfitabilityExpense(amount: 25, category: "fuel"),
        ],
        linkedInvoices: [invoice(amount: 1166, payments: [
            LedgerPayment(id: "stripe_1", amount: 1166, date: "2026-08-05", method: .stripe),
        ])]
    ))
    expect(costed.estimatedOwnerLaborCost, 160, "owner labor estimated cost")
    expect(costed.actualOwnerLaborCost, 220, "owner labor actual cost")
    expect(costed.estimatedGrossProfit, 506, "owner labor reduces estimated profit")
    expect(costed.actualGrossProfitBilled, 581, "owner labor reduces actual profit")
    expect(costed.effectiveHourlyActual, decimal("145.64"), "effective hourly is labor-cost-rate independent")
    expect(costed.warnings, [.feesUnknown], "set labor rate removes unset warning")
}

if failures == 0 {
    print("PASS: native financial domain golden tests")
} else {
    print("FAILED: \(failures) native financial domain test(s)")
    exit(1)
}
