import Foundation

// MARK: - Tax set-aside card copy (task 9.02, requirement T2)
//
// The presentation half: period/deadline labels and the exact user-facing copy
// from `components/money/TaxSetAsideCard.tsx` and `TaxSettingsModal.tsx`. All
// arithmetic stays in `TaxEstimateEngine`; this type only formats it.

struct NativeTaxBreakdown: Equatable {
    var currentReserve: Decimal
    var yearToDateReserve: Decimal
    /// "Jun 1 – Aug 31"
    var periodRangeText: String
    /// "Sep 15", or "Jan 15, 2027" when the deadline falls in the next year.
    var deadlineText: String
    /// "Sep 15" line: "<range> · set aside by <deadline>".
    var periodSummaryText: String
    /// "<amount> for the year so far"
    var yearToDateText: String
    var needsVehicleChoice: Bool
    var incomeRateSet: Bool
    var ratesKnown: Bool
    var yearToDateTripCount: Int
    /// Present only when vehicle inputs exist and no method is chosen.
    var vehiclePrompt: String?
    /// Present only when no income-tax rate is set.
    var incomeRatePrompt: String?
    /// Present only when the tax year is not in the versioned wage-base table.
    var staleRatesNote: String?
    var mileageDisclosure: String
    var disclaimer: String
}

enum NativeTaxBreakdownCopy {
    static let vehiclePrompt =
        "⚠ Choose standard mileage or actual fuel costs — until then neither is deducted"
    static let incomeRatePrompt =
        "Set your income-tax rate for a fuller estimate (currently self-employment tax only)"
    static let staleRatesNote =
        "Using the latest built-in IRS rates — this year's aren't loaded yet"
    static let disclaimer =
        "Estimate only — not tax advice. Assumes net profit under $200k."
    static let settingsHelp =
        "Your effective federal + state income-tax rate. Self-employment tax is "
        + "estimated separately."
    static let settingsDisclaimer =
        "Estimates only — not tax advice. Talk to a tax professional about which "
        + "method suits your situation."
    static let rateValidationMessage =
        "Enter your effective income-tax rate as a percentage between 0 and 60 — "
        + "most solo trades land between 10 and 25."
    static let methodUnsetNote = "No method chosen yet."
    static let standardMileageLabel = "Standard mileage"
    static let actualFuelLabel = "Actual fuel costs"

    /// "Mileage from this device's trip log (N trips this year) — not synced."
    static func mileageDisclosure(tripCount: Int) -> String {
        let noun = tripCount == 1 ? "trip" : "trips"
        return "Mileage from this device's trip log (\(tripCount) \(noun) this year) — not synced."
    }
}

extension NativeTaxBreakdown {
    /// Build the card model from the shared engine summary.
    static func make(
        summary: TaxWindowSummary,
        values: NativeTaxSettingsValues,
        calendar: Calendar = NativeCashBasis.localCalendar
    ) -> NativeTaxBreakdown {
        let rangeText = periodRange(summary.period, calendar: calendar)
        let deadline = deadlineText(summary.period, calendar: calendar)
        let incomeRateSet = values.taxIncomeRate != nil
        return NativeTaxBreakdown(
            currentReserve: summary.current.reserve,
            yearToDateReserve: summary.yearToDate.reserve,
            periodRangeText: rangeText,
            deadlineText: deadline,
            periodSummaryText: "\(rangeText) · set aside by \(deadline)",
            yearToDateText: money(summary.yearToDate.reserve) + " for the year so far",
            needsVehicleChoice: summary.needsVehicleChoice,
            incomeRateSet: incomeRateSet,
            ratesKnown: summary.current.ratesKnown,
            yearToDateTripCount: summary.yearToDateTripCount,
            vehiclePrompt: summary.needsVehicleChoice ? NativeTaxBreakdownCopy.vehiclePrompt : nil,
            incomeRatePrompt: incomeRateSet ? nil : NativeTaxBreakdownCopy.incomeRatePrompt,
            staleRatesNote: summary.current.ratesKnown ? nil : NativeTaxBreakdownCopy.staleRatesNote,
            mileageDisclosure: NativeTaxBreakdownCopy.mileageDisclosure(tripCount: summary.yearToDateTripCount),
            disclaimer: NativeTaxBreakdownCopy.disclaimer
        )
    }

    /// "Jun 1 – Aug 31" (en dash, `toLocaleDateString("en-US", {month,day})`).
    static func periodRange(_ period: TaxPeriod, calendar: Calendar = NativeCashBasis.localCalendar) -> String {
        guard let start = NativeCashBasis.parseLocalDate(period.start),
              let end = NativeCashBasis.parseLocalDate(period.end)
        else { return "" }
        return "\(monthDay(start, calendar: calendar)) – \(monthDay(end, calendar: calendar))"
    }

    /// "Sep 15", with the year appended when it differs from the period's year.
    static func deadlineText(_ period: TaxPeriod, calendar: Calendar = NativeCashBasis.localCalendar) -> String {
        guard let due = NativeCashBasis.parseLocalDate(period.due) else { return "" }
        let (year, _, _) = NativeCashBasis.localComponents(due)
        return year == period.year
            ? monthDay(due, calendar: calendar)
            : monthDayYear(due, calendar: calendar)
    }

    private static func monthDay(_ date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.calendar = calendar
        formatter.dateFormat = "MMM d"
        return formatter.string(from: date)
    }

    private static func monthDayYear(_ date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.calendar = calendar
        formatter.dateFormat = "MMM d, yyyy"
        return formatter.string(from: date)
    }

    private static func money(_ value: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        return formatter.string(from: NSDecimalNumber(decimal: value)) ?? "$0.00"
    }
}
