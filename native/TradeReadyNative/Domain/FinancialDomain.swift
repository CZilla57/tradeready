import Foundation

// MARK: - Shared decimal rules

enum FinancialDecimal {
    static let paidEpsilon = Decimal(string: "0.005")!

    static func value(_ text: String, fallback: Decimal = 0) -> Decimal {
        Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")) ?? fallback
    }

    static func cents(_ value: Decimal) -> Decimal {
        var input = value
        var output = Decimal()
        NSDecimalRound(&output, &input, 2, .plain)
        return output
    }

    /// Mirrors JavaScript `Math.round(n * 100) / 100` for contracts whose
    /// behavioral oracle still calculates in IEEE-754 numbers.
    static func javascriptCents(_ value: Decimal) -> Decimal {
        let text = NSDecimalNumber(decimal: value).stringValue
        guard let source = Double(text), source.isFinite else { return 0 }
        let rounded = floor(source * 100 + 0.5) / 100
        return Decimal(string: String(rounded), locale: Locale(identifier: "en_US_POSIX")) ?? 0
    }

    static func maximum(_ lhs: Decimal, _ rhs: Decimal) -> Decimal {
        lhs > rhs ? lhs : rhs
    }

    static func minimum(_ lhs: Decimal, _ rhs: Decimal) -> Decimal {
        lhs < rhs ? lhs : rhs
    }
}

// MARK: - Pricing

enum PricingCostCategory: String, Codable, CaseIterable {
    case permit, disposal, rental, subcontractor, delivery, travel, other
}

enum PricingMarkupPolicy: String, Codable {
    case inMarginBase = "in_margin_base"
    case passthrough
}

struct PricingMaterial: Codable, Equatable {
    var name: String = ""
    var quantity: Decimal = 0
    var unitCost: Decimal = 0
}

struct PricingDirectCost: Codable, Equatable, Identifiable {
    /// Callers supply the production record identifier; the pricing engine must
    /// not invent a wire-incompatible UUID for persisted direct-cost records.
    var id: String
    var label: String = ""
    var category: PricingCostCategory = .other
    var quantity: Decimal = 0
    var unitCost: Decimal = 0
    var markupPercent: Decimal = 0
    var markupPolicy: PricingMarkupPolicy?
    var taxable = false
    var customerVisible = true
}

struct PricingDirectCostLine: Codable, Equatable, Identifiable {
    var id: String
    var label: String
    var category: PricingCostCategory
    var amount: Decimal
    var markupPolicy: PricingMarkupPolicy
    var taxable: Bool
    var customerVisible: Bool
}

struct PricingInput: Codable, Equatable {
    var laborHours: Decimal = 0
    var laborRate: Decimal = 85
    var materials: [PricingMaterial] = []
    var materialMarkup: Decimal = 20
    var jobCosts: [PricingDirectCost] = []
    var overheadPercent: Decimal = 15
    var marginPercent: Decimal = 20
    var travelMiles: Decimal = 0
    var travelFeePerMile: Decimal = 0
    var isEmergency = false
    var emergencyMultiplier: Decimal = Decimal(string: "1.5")!
    var minimumJobFee: Decimal = 75
    var taxPercent: Decimal = 0
}

struct PricingBreakdown: Codable, Equatable {
    var laborCost: Decimal
    var materialBaseCost: Decimal
    var materialMarkupAmount: Decimal
    var materialCost: Decimal
    var travelCost: Decimal
    var directCostMarginBase: Decimal
    var directCostPassthrough: Decimal
    var directCostLines: [PricingDirectCostLine]
    var subtotal: Decimal
    var overheadCost: Decimal
    var profit: Decimal
    var preTaxTotal: Decimal
    var totalBeforeTax: Decimal
    var taxAmount: Decimal
    var total: Decimal
    var effectiveHourlyRate: Decimal
    var hitMinimum: Bool
}

struct PricingRange: Equatable {
    var low: Decimal
    var recommended: Decimal
    var high: Decimal
    var breakdown: PricingBreakdown
}

enum PricingAdvisory: Equatable, Identifiable {
    case lowEffectiveHourlyRate(actual: Decimal, target: Decimal)
    case materialsDominant
    case minimumFeeApplied(Decimal)
    case veryShortLabor
    case driveTimeAndMileage
    case driveTimeAndTravelCost
    case mileageAndTravelCost

    var id: String {
        switch self {
        case .lowEffectiveHourlyRate: "low-effective-rate"
        case .materialsDominant: "materials-dominant"
        case .minimumFeeApplied: "minimum-fee"
        case .veryShortLabor: "short-labor"
        case .driveTimeAndMileage: "drive-and-mileage"
        case .driveTimeAndTravelCost: "drive-and-cost"
        case .mileageAndTravelCost: "mileage-and-cost"
        }
    }

    var message: String {
        switch self {
        case .lowEffectiveHourlyRate(let actual, let target):
            "Your effective hourly rate is \(Self.money(actual))/hr, below your \(Self.money(target))/hr target. Consider adjusting hours or price."
        case .materialsDominant:
            "Materials are over 60% of this job total. Double-check your markup."
        case .minimumFeeApplied(let minimum):
            "This job is below your \(Self.money(minimum)) minimum fee, so the minimum will be charged."
        case .veryShortLabor:
            "Less than 30 minutes of labor—remember setup, cleanup, and drive time."
        case .driveTimeAndMileage:
            "Drive time and a per-mile fee are both billed. Confirm you intend to charge both."
        case .driveTimeAndTravelCost:
            "Drive time and a travel or delivery cost are both billed. Check for double-charging."
        case .mileageAndTravelCost:
            "A per-mile fee and a travel or delivery cost are both billed. Check for double-charging."
        }
    }

    private static func money(_ value: Decimal) -> String {
        "$\(NSDecimalNumber(decimal: FinancialDecimal.cents(value)).stringValue)"
    }
}

enum PricingEngine {
    private static let hundred = Decimal(100)
    private static let marginCeiling = Decimal(99)

    static func defaultMarkupPolicy(for category: PricingCostCategory) -> PricingMarkupPolicy {
        category == .permit ? .passthrough : .inMarginBase
    }

    private struct DirectTotals {
        var marginBase: Decimal = 0
        var passthrough: Decimal = 0
        var nonTaxablePassthrough: Decimal = 0
        var lines: [PricingDirectCostLine] = []
    }

    private static func directTotals(_ costs: [PricingDirectCost]) -> DirectTotals {
        var result = DirectTotals()
        for cost in costs {
            let policy = cost.markupPolicy ?? defaultMarkupPolicy(for: cost.category)
            let base = cost.quantity * cost.unitCost
            let amount = policy == .inMarginBase
                ? base * (1 + cost.markupPercent / hundred)
                : base

            if policy == .inMarginBase {
                result.marginBase += amount
            } else {
                result.passthrough += amount
                if !cost.taxable { result.nonTaxablePassthrough += amount }
            }
            result.lines.append(PricingDirectCostLine(
                id: cost.id,
                label: cost.label,
                category: cost.category,
                amount: FinancialDecimal.cents(amount),
                markupPolicy: policy,
                taxable: cost.taxable,
                customerVisible: cost.customerVisible
            ))
        }
        return result
    }

    static func calculate(_ input: PricingInput) -> PricingBreakdown {
        let effectiveRate = input.isEmergency
            ? input.laborRate * input.emergencyMultiplier
            : input.laborRate
        let laborCost = input.laborHours * effectiveRate
        let materialBase = input.materials.reduce(Decimal.zero) {
            $0 + $1.quantity * $1.unitCost
        }
        let materialCost = materialBase * (1 + input.materialMarkup / hundred)
        let travelCost = input.travelMiles * input.travelFeePerMile
        let direct = directTotals(input.jobCosts)
        let subtotal = laborCost + materialCost + travelCost + direct.marginBase
        let overhead = subtotal * input.overheadPercent / hundred
        let profitBase = subtotal + overhead
        let safeMargin = FinancialDecimal.minimum(
            FinancialDecimal.maximum(input.marginPercent, 0),
            marginCeiling
        )
        let preTax = profitBase / (1 - safeMargin / hundred)
        let profit = preTax - profitBase
        let marginedFloored = FinancialDecimal.maximum(preTax, input.minimumJobFee)
        let totalBeforeTax = marginedFloored + direct.passthrough
        let taxBase = totalBeforeTax - direct.nonTaxablePassthrough
        let tax = taxBase * input.taxPercent / hundred
        let total = totalBeforeTax + tax
        let directTotal = direct.marginBase + direct.passthrough
        let effectiveHourly = input.laborHours > 0
            ? (total - materialCost - travelCost - directTotal) / input.laborHours
            : 0

        return PricingBreakdown(
            laborCost: FinancialDecimal.cents(laborCost),
            materialBaseCost: FinancialDecimal.cents(materialBase),
            materialMarkupAmount: FinancialDecimal.cents(materialCost - materialBase),
            materialCost: FinancialDecimal.cents(materialCost),
            travelCost: FinancialDecimal.cents(travelCost),
            directCostMarginBase: FinancialDecimal.cents(direct.marginBase),
            directCostPassthrough: FinancialDecimal.cents(direct.passthrough),
            directCostLines: direct.lines,
            subtotal: FinancialDecimal.cents(subtotal),
            overheadCost: FinancialDecimal.cents(overhead),
            profit: FinancialDecimal.cents(profit),
            preTaxTotal: FinancialDecimal.cents(preTax),
            totalBeforeTax: FinancialDecimal.cents(totalBeforeTax),
            taxAmount: FinancialDecimal.cents(tax),
            total: FinancialDecimal.cents(total),
            effectiveHourlyRate: FinancialDecimal.cents(effectiveHourly),
            hitMinimum: preTax < input.minimumJobFee
        )
    }

    static func priceRange(_ input: PricingInput) -> PricingRange {
        let recommended = calculate(input)
        var lowInput = input
        lowInput.marginPercent = FinancialDecimal.maximum(0, input.marginPercent - 5)
        var highInput = input
        highInput.marginPercent += 5
        return PricingRange(
            low: calculate(lowInput).total,
            recommended: recommended.total,
            high: calculate(highInput).total,
            breakdown: recommended
        )
    }

    static func breakEvenPrice(_ input: PricingInput) -> Decimal {
        var breakEvenInput = input
        breakEvenInput.marginPercent = 0
        return calculate(breakEvenInput).totalBeforeTax
    }

    static func laborBreakdownTotal(
        onSite: Decimal,
        drive: Decimal,
        supplyRun: Decimal,
        setupCleanup: Decimal
    ) -> Decimal {
        FinancialDecimal.cents(onSite + drive + supplyRun + setupCleanup)
    }

    static func advisories(_ input: PricingInput, driveHours: Decimal = 0) -> [PricingAdvisory] {
        let breakdown = calculate(input)
        var result: [PricingAdvisory] = []
        if breakdown.effectiveHourlyRate > 0,
           breakdown.effectiveHourlyRate < input.laborRate * Decimal(string: "0.8")! {
            result.append(.lowEffectiveHourlyRate(
                actual: breakdown.effectiveHourlyRate,
                target: input.laborRate
            ))
        }
        if breakdown.materialCost > breakdown.total * Decimal(string: "0.6")! {
            result.append(.materialsDominant)
        }
        if breakdown.hitMinimum { result.append(.minimumFeeApplied(input.minimumJobFee)) }
        if input.laborHours > 0 && input.laborHours < Decimal(string: "0.5")! {
            result.append(.veryShortLabor)
        }

        let hasTravelCost = input.jobCosts.contains {
            $0.category == .travel || $0.category == .delivery
        }
        if driveHours > 0 && input.travelMiles > 0 {
            result.append(.driveTimeAndMileage)
        }
        if driveHours > 0 && hasTravelCost {
            result.append(.driveTimeAndTravelCost)
        }
        if driveHours == 0 && input.travelMiles > 0 && hasTravelCost {
            result.append(.mileageAndTravelCost)
        }
        return result
    }
}

// MARK: - Payment ledger

enum LedgerPaymentMethod: String, Codable {
    case cash, check, card, stripe, bankTransfer = "bank_transfer", other
}

struct LedgerPayment: Codable, Equatable, Identifiable {
    var id: String
    var amount: Decimal
    /// Date-only ISO-8601 string (YYYY-MM-DD), matching the production contract.
    var date: String
    var method: LedgerPaymentMethod = .other
    var note: String?
    var voidedAt: String?
}

struct DepositRequest: Codable, Equatable {
    var amount: Decimal
}

struct LedgerInvoice: Codable, Equatable, Identifiable {
    var id: String
    var amount: Decimal
    var due: String
    var paid = false
    var paidAt: String?
    /// `nil` and `[]` both mean the pre-ledger legacy representation.
    var payments: [LedgerPayment]?
    var depositRequest: DepositRequest?
}

enum DepositSpecification: Equatable {
    case percent(Decimal)
    case fixed(Decimal)
}

enum PaymentLedger {
    static let paidEpsilon = FinancialDecimal.paidEpsilon

    static func amountPaid(_ invoice: LedgerInvoice) -> Decimal {
        guard let payments = invoice.payments, !payments.isEmpty else {
            return invoice.paid ? invoice.amount : 0
        }
        return payments.reduce(Decimal.zero) {
            $0 + ($1.voidedAt == nil ? $1.amount : 0)
        }
    }

    static func balanceDue(_ invoice: LedgerInvoice) -> Decimal {
        FinancialDecimal.maximum(0, invoice.amount - amountPaid(invoice))
    }

    static func isFullyPaid(_ invoice: LedgerInvoice) -> Bool {
        balanceDue(invoice) <= paidEpsilon
    }

    static func isPartlyPaid(_ invoice: LedgerInvoice) -> Bool {
        amountPaid(invoice) > paidEpsilon && !isFullyPaid(invoice)
    }

    static func overpaidAmount(_ invoice: LedgerInvoice) -> Decimal {
        FinancialDecimal.maximum(0, amountPaid(invoice) - invoice.amount)
    }

    static func materializeLegacyLedger(_ invoice: LedgerInvoice) -> [LedgerPayment] {
        if let payments = invoice.payments, !payments.isEmpty { return payments }
        guard invoice.paid else { return [] }
        return [LedgerPayment(
            id: "legacy_\(invoice.id)",
            amount: invoice.amount,
            date: invoice.paidAt ?? invoice.due,
            method: .other,
            note: "Recorded before payment history was itemised"
        )]
    }

    static func reconcilePaidFields(_ invoice: LedgerInvoice) -> LedgerInvoice {
        guard let payments = invoice.payments, !payments.isEmpty else { return invoice }
        return derivingPaidFields(invoice, payments: payments)
    }

    static func apply(_ payment: LedgerPayment, to invoice: LedgerInvoice) -> LedgerInvoice {
        var ledger = materializeLegacyLedger(invoice)
        if !ledger.contains(where: { $0.id == payment.id }) {
            ledger.append(payment)
        }
        return derivingPaidFields(invoice, payments: ledger)
    }

    static func voidPayment(
        id: String,
        on invoice: LedgerInvoice,
        voidedAt: String
    ) -> LedgerInvoice {
        let ledger = materializeLegacyLedger(invoice).map { payment -> LedgerPayment in
            guard payment.id == id, payment.voidedAt == nil else { return payment }
            var voided = payment
            voided.voidedAt = voidedAt
            return voided
        }
        return derivingPaidFields(invoice, payments: ledger)
    }

    static func resolveDepositAmount(
        for invoice: LedgerInvoice,
        specification: DepositSpecification
    ) -> Decimal {
        let requested: Decimal
        switch specification {
        case .percent(let percent): requested = invoice.amount * percent / 100
        case .fixed(let amount): requested = amount
        }
        guard requested > 0 else { return 0 }
        return FinancialDecimal.cents(FinancialDecimal.minimum(requested, balanceDue(invoice)))
    }

    static func isDepositSatisfied(_ invoice: LedgerInvoice) -> Bool {
        guard let request = invoice.depositRequest else { return false }
        return amountPaid(invoice) >= request.amount - paidEpsilon
    }

    /// Inclusive date-only window. Voided entries remain visible to callers.
    static func payments(
        for invoice: LedgerInvoice,
        from start: String,
        through end: String
    ) -> [LedgerPayment] {
        materializeLegacyLedger(invoice).filter { $0.date >= start && $0.date <= end }
    }

    static func collected(
        from invoices: [LedgerInvoice],
        from start: String,
        through end: String
    ) -> Decimal {
        invoices.reduce(Decimal.zero) { invoiceTotal, invoice in
            invoiceTotal + payments(for: invoice, from: start, through: end).reduce(Decimal.zero) {
                $0 + ($1.voidedAt == nil ? $1.amount : 0)
            }
        }
    }

    /// Records exactly the remaining balance. Already-settled invoices are unchanged.
    static func settleRemaining(
        _ invoice: LedgerInvoice,
        on date: String,
        paymentID: String
    ) -> LedgerInvoice {
        guard !isFullyPaid(invoice) else { return invoice }
        return apply(LedgerPayment(
            id: paymentID,
            amount: balanceDue(invoice),
            date: date,
            method: .other
        ), to: invoice)
    }

    /// Walks the ledger once. Overlapping windows intentionally count a payment in each window.
    static func collectedByPeriod(
        _ invoices: [LedgerInvoice],
        ranges: [(start: String, end: String)]
    ) -> [Decimal] {
        var totals = Array(repeating: Decimal.zero, count: ranges.count)
        for invoice in invoices {
            for payment in materializeLegacyLedger(invoice) where payment.voidedAt == nil {
                for index in ranges.indices
                    where payment.date >= ranges[index].start && payment.date <= ranges[index].end {
                    totals[index] += payment.amount
                }
            }
        }
        return totals
    }

    static func merge(local: LedgerInvoice, remote: LedgerInvoice) -> LedgerInvoice {
        var byID: [String: LedgerPayment] = [:]
        for payment in materializeLegacyLedger(local) { byID[payment.id] = payment }
        for incoming in materializeLegacyLedger(remote) {
            byID[incoming.id] = survivingPayment(existing: byID[incoming.id], incoming: incoming)
        }
        let merged = byID.values.sorted(by: paymentComesBefore)
        return derivingPaidFields(remote, payments: merged)
    }

    private static func derivingPaidFields(
        _ invoice: LedgerInvoice,
        payments: [LedgerPayment]
    ) -> LedgerInvoice {
        let collected = payments.reduce(Decimal.zero) {
            $0 + ($1.voidedAt == nil ? $1.amount : 0)
        }
        let settled = !payments.isEmpty && invoice.amount - collected <= paidEpsilon
        var result = invoice
        result.payments = payments
        result.paid = settled
        guard settled else {
            result.paidAt = nil
            return result
        }

        let chronological = payments.sorted(by: paymentComesBefore)
        var running: Decimal = 0
        var closingDate = chronological.last?.date ?? invoice.due
        for payment in chronological where payment.voidedAt == nil {
            running += payment.amount
            if running >= invoice.amount - paidEpsilon {
                closingDate = payment.date
                break
            }
        }
        result.paidAt = closingDate
        return result
    }

    private static func paymentComesBefore(_ lhs: LedgerPayment, _ rhs: LedgerPayment) -> Bool {
        lhs.date == rhs.date ? lhs.id < rhs.id : lhs.date < rhs.date
    }

    private static func survivingPayment(
        existing: LedgerPayment?,
        incoming: LedgerPayment
    ) -> LedgerPayment {
        guard let existing else { return incoming }
        if let existingVoid = existing.voidedAt, let incomingVoid = incoming.voidedAt {
            return existingVoid < incomingVoid ? existing : incoming
        }
        if existing.voidedAt != nil { return existing }
        return incoming
    }
}

// MARK: - Tax set-aside estimate

enum VehicleDeductionMethod: String, Codable {
    case mileage, actual
}

struct TaxExpense: Equatable {
    var amount: Decimal
    var category: String
    /// Date-only ISO-8601 string.
    var date: String
}

struct TaxExpenseSplit: Equatable {
    var nonVehicle: Decimal
    var fuel: Decimal
}

struct VehicleDeductionResult: Equatable {
    var deduction: Decimal
    var needsChoice: Bool
}

struct TaxEstimateInput: Equatable {
    var collectedIncome: Decimal
    var deductibleExpenses: Decimal
    var vehicleDeduction: Decimal
    var incomeRatePercent: Decimal
    var year: Int
}

struct TaxEstimate: Equatable {
    var netProfit: Decimal
    var selfEmploymentTax: Decimal
    var incomeTax: Decimal
    var reserve: Decimal
    var ratesKnown: Bool
}

struct TaxPeriod: Equatable {
    var quarter: Int
    var year: Int
    var start: String
    var end: String
    var due: String
}

struct TaxTrip: Equatable {
    var date: String
    var miles: Decimal
}

struct TaxWindowSettings: Equatable {
    var mileageRate: Decimal = FinancialDecimal.value("0.70")
    var incomeRatePercent: Decimal?
    var vehicleDeductionMethod: VehicleDeductionMethod?
}

struct TaxWindowSummary: Equatable {
    var period: TaxPeriod
    var current: TaxEstimate
    var yearToDate: TaxEstimate
    var needsVehicleChoice: Bool
    var incomeRateSet: Bool
    var yearToDateTripCount: Int
}

enum TaxEstimateEngine {
    static let selfEmploymentNetEarningsFactor = FinancialDecimal.value("0.9235")
    static let socialSecurityRate = FinancialDecimal.value("0.124")
    static let medicareRate = FinancialDecimal.value("0.029")
    static let socialSecurityWageBase: [Int: Decimal] = [
        2025: 176_100,
        2026: 184_500,
    ]

    private static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private static func shiftedDeadline(year: Int, month: Int, day: Int) -> String {
        let calendar = utcCalendar
        var date = calendar.date(from: DateComponents(year: year, month: month, day: day))!
        let weekday = calendar.component(.weekday, from: date)
        if weekday == 7 { date = calendar.date(byAdding: .day, value: 2, to: date)! }
        if weekday == 1 { date = calendar.date(byAdding: .day, value: 1, to: date)! }
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }

    /// IRS estimated-payment periods are intentionally uneven: 3/2/3/4 months.
    static func periods(for year: Int) -> [TaxPeriod] {
        [
            TaxPeriod(quarter: 1, year: year, start: "\(year)-01-01", end: "\(year)-03-31", due: shiftedDeadline(year: year, month: 4, day: 15)),
            TaxPeriod(quarter: 2, year: year, start: "\(year)-04-01", end: "\(year)-05-31", due: shiftedDeadline(year: year, month: 6, day: 15)),
            TaxPeriod(quarter: 3, year: year, start: "\(year)-06-01", end: "\(year)-08-31", due: shiftedDeadline(year: year, month: 9, day: 15)),
            TaxPeriod(quarter: 4, year: year, start: "\(year)-09-01", end: "\(year)-12-31", due: shiftedDeadline(year: year + 1, month: 1, day: 15)),
        ]
    }

    static func currentPeriod(on date: String) -> TaxPeriod {
        let year = Int(date.prefix(4)) ?? 0
        return periods(for: year).first { date >= $0.start && date <= $0.end }
            ?? periods(for: year)[3]
    }

    static func splitDeductibleExpenses(
        _ expenses: [TaxExpense],
        from start: String,
        through end: String
    ) -> TaxExpenseSplit {
        var split = TaxExpenseSplit(nonVehicle: 0, fuel: 0)
        for expense in expenses where expense.date >= start && expense.date <= end {
            if expense.category == "fuel" { split.fuel += expense.amount }
            else { split.nonVehicle += expense.amount }
        }
        return split
    }

    static func resolveVehicleDeduction(
        method: VehicleDeductionMethod?,
        miles: Decimal,
        mileageRate: Decimal,
        fuelExpenses: Decimal
    ) -> VehicleDeductionResult {
        switch method {
        case .mileage:
            return VehicleDeductionResult(
                deduction: FinancialDecimal.cents(miles * mileageRate),
                needsChoice: false
            )
        case .actual:
            return VehicleDeductionResult(deduction: fuelExpenses, needsChoice: false)
        case nil:
            return VehicleDeductionResult(
                deduction: 0,
                needsChoice: miles > 0 || fuelExpenses > 0
            )
        }
    }

    static func estimate(_ input: TaxEstimateInput) -> TaxEstimate {
        let latestYear = socialSecurityWageBase.keys.max()!
        let ratesKnown = socialSecurityWageBase[input.year] != nil
        let wageBase = socialSecurityWageBase[input.year] ?? socialSecurityWageBase[latestYear]!
        let netProfit = input.collectedIncome - input.deductibleExpenses - input.vehicleDeduction
        let selfEmploymentBase = FinancialDecimal.maximum(
            0,
            netProfit * selfEmploymentNetEarningsFactor
        )
        let selfEmploymentTax =
            FinancialDecimal.minimum(selfEmploymentBase, wageBase) * socialSecurityRate
            + selfEmploymentBase * medicareRate
        let incomeRate = FinancialDecimal.maximum(0, input.incomeRatePercent)
        let incomeTax = FinancialDecimal.maximum(0, netProfit - selfEmploymentTax / 2)
            * incomeRate / 100

        return TaxEstimate(
            netProfit: FinancialDecimal.cents(netProfit),
            selfEmploymentTax: FinancialDecimal.cents(selfEmploymentTax),
            incomeTax: FinancialDecimal.cents(incomeTax),
            reserve: FinancialDecimal.cents(selfEmploymentTax + incomeTax),
            ratesKnown: ratesKnown
        )
    }


    static func summarize(
        invoices: [LedgerInvoice],
        expenses: [TaxExpense],
        trips: [TaxTrip],
        settings: TaxWindowSettings,
        on today: String
    ) -> TaxWindowSummary {
        let period = currentPeriod(on: today)
        let year = period.year
        let yearStart = "\(year)-01-01"

        func estimateWindow(from start: String, through end: String)
            -> (TaxEstimate, VehicleDeductionResult, Int) {
            let split = splitDeductibleExpenses(expenses, from: start, through: end)
            let windowTrips = trips.filter { $0.date >= start && $0.date <= end }
            let miles = windowTrips.reduce(Decimal.zero) { $0 + $1.miles }
            let vehicle = resolveVehicleDeduction(
                method: settings.vehicleDeductionMethod,
                miles: miles,
                mileageRate: settings.mileageRate,
                fuelExpenses: split.fuel
            )
            let tax = estimate(TaxEstimateInput(
                collectedIncome: PaymentLedger.collected(
                    from: invoices,
                    from: start,
                    through: end
                ),
                deductibleExpenses: split.nonVehicle,
                vehicleDeduction: vehicle.deduction,
                incomeRatePercent: settings.incomeRatePercent ?? 0,
                year: year
            ))
            return (tax, vehicle, windowTrips.count)
        }

        let current = estimateWindow(from: period.start, through: period.end)
        let ytd = estimateWindow(from: yearStart, through: today)
        return TaxWindowSummary(
            period: period,
            current: current.0,
            yearToDate: ytd.0,
            needsVehicleChoice: ytd.1.needsChoice,
            incomeRateSet: settings.incomeRatePercent != nil,
            yearToDateTripCount: ytd.2
        )
    }
}

// MARK: - Per-job profitability

enum ProfitabilityWarning: String, Equatable, CaseIterable {
    case hoursUntracked = "hours_untracked"
    case expensesUnlinked = "expenses_unlinked"
    case invoiceUnlinked = "invoice_unlinked"
    case feesUnknown = "fees_unknown"
    case laborCostRateUnset = "labor_cost_rate_unset"
    case legacyInvoiceDates = "legacy_invoice_dates"
}

struct ProfitabilityExpense: Equatable {
    var amount: Decimal
    var category: String
}

struct ProfitabilityInput: Equatable {
    var estimatedRevenue: Decimal
    var approvedChangeOrderRevenue: Decimal = 0
    var estimatedLaborHours: Decimal = 0
    var billableLaborRate: Decimal = 0
    /// `nil` means no time data; zero means tracked data exists but totals zero.
    var actualLaborHours: Decimal?
    var ownerLaborCostRate: Decimal?
    var estimatedMaterialCost: Decimal = 0
    var estimatedDirectCost: Decimal = 0
    /// `nil` means no linked-expense data; an empty array means known zero actual costs.
    var linkedExpenses: [ProfitabilityExpense]?
    var linkedInvoices: [LedgerInvoice] = []
    var expectsInvoice = false
}

struct JobProfitability: Equatable {
    var estimatedRevenue: Decimal
    var changeOrderRevenue: Decimal
    var finalBillable: Decimal
    var invoicedAmount: Decimal
    var cashCollected: Decimal
    var outstandingReceivable: Decimal
    var overpaidAmount: Decimal
    var processingFees: Decimal?
    var estimatedLaborHours: Decimal
    var billableLaborRate: Decimal
    var actualLaborHours: Decimal?
    var laborHoursVariance: Decimal?
    var estimatedOwnerLaborCost: Decimal?
    var actualOwnerLaborCost: Decimal?
    var estimatedMaterialCost: Decimal
    var actualMaterialExpense: Decimal?
    var otherDirectExpenses: Decimal?
    var materialsVariance: Decimal?
    var estimatedDirectCost: Decimal
    var directCostVariance: Decimal?
    var estimatedGrossProfit: Decimal
    var actualGrossProfitBilled: Decimal
    var actualGrossProfitCash: Decimal
    var effectiveHourlyActual: Decimal?
    var warnings: [ProfitabilityWarning]
}

enum JobProfitabilityEngine {
    static func calculate(_ input: ProfitabilityInput) -> JobProfitability {
        var warnings = Set<ProfitabilityWarning>()
        let estimatedRevenue = FinancialDecimal.cents(input.estimatedRevenue)
        let changeOrders = FinancialDecimal.cents(input.approvedChangeOrderRevenue)
        let finalBillable = FinancialDecimal.cents(estimatedRevenue + changeOrders)

        var invoiced: Decimal = 0
        var collected: Decimal = 0
        var outstanding: Decimal = 0
        var overpaid: Decimal = 0
        for invoice in input.linkedInvoices {
            invoiced += invoice.amount
            collected += PaymentLedger.amountPaid(invoice)
            outstanding += PaymentLedger.balanceDue(invoice)
            overpaid += PaymentLedger.overpaidAmount(invoice)
            if (invoice.payments?.isEmpty != false) && PaymentLedger.amountPaid(invoice) > 0 {
                warnings.insert(.legacyInvoiceDates)
            }
            if invoice.payments?.contains(where: {
                $0.voidedAt == nil && $0.method == .stripe && $0.amount > 0
            }) == true {
                warnings.insert(.feesUnknown)
            }
        }
        if input.linkedInvoices.isEmpty && input.expectsInvoice { warnings.insert(.invoiceUnlinked) }

        let actualHours = input.actualLaborHours.map(FinancialDecimal.cents)
        if actualHours == nil { warnings.insert(.hoursUntracked) }
        let hoursVariance = actualHours.flatMap { hours in
            input.estimatedLaborHours > 0
                ? FinancialDecimal.cents(hours - input.estimatedLaborHours)
                : nil
        }
        let ownerRate = input.ownerLaborCostRate.flatMap { $0 >= 0 ? $0 : nil }
        if ownerRate == nil { warnings.insert(.laborCostRateUnset) }
        let estimatedOwnerCost = ownerRate.map {
            FinancialDecimal.cents(input.estimatedLaborHours * $0)
        }
        let actualOwnerCost = ownerRate.flatMap { rate in
            actualHours.map { FinancialDecimal.cents($0 * rate) }
        }

        var actualMaterials: Decimal?
        var otherExpenses: Decimal?
        if let expenses = input.linkedExpenses {
            actualMaterials = FinancialDecimal.cents(expenses.reduce(Decimal.zero) {
                $0 + ($1.category == "materials" ? $1.amount : 0)
            })
            otherExpenses = FinancialDecimal.cents(expenses.reduce(Decimal.zero) {
                $0 + ($1.category == "materials" ? 0 : $1.amount)
            })
        } else {
            warnings.insert(.expensesUnlinked)
        }
        let materialsVariance = actualMaterials.map {
            FinancialDecimal.cents($0 - input.estimatedMaterialCost)
        }
        let directVariance = otherExpenses.map {
            FinancialDecimal.cents($0 - input.estimatedDirectCost)
        }
        let estimatedProfit = FinancialDecimal.cents(
            estimatedRevenue - input.estimatedMaterialCost - input.estimatedDirectCost
                - (estimatedOwnerCost ?? 0)
        )
        let knownActualCosts = (actualMaterials ?? 0) + (otherExpenses ?? 0) + (actualOwnerCost ?? 0)
        let billedProfit = FinancialDecimal.cents(finalBillable - knownActualCosts)
        let cashProfit = FinancialDecimal.cents(FinancialDecimal.cents(collected) - knownActualCosts)
        let effectiveHourly = actualHours.flatMap { hours -> Decimal? in
            guard hours > 0 else { return nil }
            return FinancialDecimal.cents((billedProfit + (actualOwnerCost ?? 0)) / hours)
        }

        return JobProfitability(
            estimatedRevenue: estimatedRevenue,
            changeOrderRevenue: changeOrders,
            finalBillable: finalBillable,
            invoicedAmount: FinancialDecimal.cents(invoiced),
            cashCollected: FinancialDecimal.cents(collected),
            outstandingReceivable: FinancialDecimal.cents(outstanding),
            overpaidAmount: FinancialDecimal.cents(overpaid),
            processingFees: nil,
            estimatedLaborHours: input.estimatedLaborHours,
            billableLaborRate: FinancialDecimal.cents(input.billableLaborRate),
            actualLaborHours: actualHours,
            laborHoursVariance: hoursVariance,
            estimatedOwnerLaborCost: estimatedOwnerCost,
            actualOwnerLaborCost: actualOwnerCost,
            estimatedMaterialCost: FinancialDecimal.cents(input.estimatedMaterialCost),
            actualMaterialExpense: actualMaterials,
            otherDirectExpenses: otherExpenses,
            materialsVariance: materialsVariance,
            estimatedDirectCost: FinancialDecimal.cents(input.estimatedDirectCost),
            directCostVariance: directVariance,
            estimatedGrossProfit: estimatedProfit,
            actualGrossProfitBilled: billedProfit,
            actualGrossProfitCash: cashProfit,
            effectiveHourlyActual: effectiveHourly,
            warnings: ProfitabilityWarning.allCases.filter(warnings.contains)
        )
    }
}
