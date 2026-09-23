import Foundation

// MARK: - Tax settings mapping (task 9.02, requirement T2)
//
// The pure half of the tax set-aside feature: the canonical wire fields
// `taxIncomeRate` (optional percent) and `vehicleDeductionMethod`
// ("mileage" | "actual", optional), plus the settings-sheet draft rules from
// `components/money/TaxSettingsModal.tsx`.
//
// Optional semantics are load-bearing and preserved exactly: an ABSENT field
// means "unset" and must never be coerced to a value or to an explicit null. The
// RN sheet merges `{ ...full, ...draft }`, so a field the user did not touch
// keeps whatever it had (including staying absent).
//
// The UI `BusinessSettings` model gains these two stored fields in the
// integration lane (9.08) because Swift cannot add stored properties in an
// extension; this module does not depend on that change.

enum NativeTaxSettingsError: Error, Equatable {
    /// "Enter your effective income-tax rate as a percentage between 0 and 60 —
    /// most solo trades land between 10 and 25."
    case rateOutOfRange
}

/// The two canonical tax settings, read as a value object.
struct NativeTaxSettingsValues: Equatable {
    /// nil = absent/unset (distinct from an explicit 0).
    var taxIncomeRate: Decimal?
    /// nil = no election made.
    var vehicleDeductionMethod: VehicleDeductionMethod?

    init(taxIncomeRate: Decimal? = nil, vehicleDeductionMethod: VehicleDeductionMethod? = nil) {
        self.taxIncomeRate = taxIncomeRate
        self.vehicleDeductionMethod = vehicleDeductionMethod
    }

    /// Read from the canonical settings record.
    init(from settings: Canonical.Settings) {
        taxIncomeRate = settings.taxIncomeRate
        vehicleDeductionMethod = settings.vehicleDeductionMethod
            .flatMap { VehicleDeductionMethod(rawValue: $0) }
    }

    /// The inputs the shared engine takes.
    var taxWindowSettings: TaxWindowSettings {
        TaxWindowSettings(incomeRatePercent: taxIncomeRate, vehicleDeductionMethod: vehicleDeductionMethod)
    }
}

/// What the settings sheet produced. A nil field means "leave unchanged".
struct NativeTaxSettingsDraft: Equatable {
    var taxIncomeRate: Decimal?
    var vehicleDeductionMethod: VehicleDeductionMethod?
}

enum NativeTaxSettings {
    /// `parseFloat` bound, inclusive, mirroring the sheet's 0…60 validation.
    static let rateMinimum = Decimal.zero
    static let rateMaximum = Decimal(60)

    /// The sheet's rate field → draft value. Empty/whitespace means "no change"
    /// (nil, no error). Anything non-finite or outside 0…60 is a refusal.
    static func parseRateInput(_ text: String) -> Result<Decimal?, NativeTaxSettingsError> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .success(nil) }
        guard let value = Decimal(string: trimmed, locale: Locale(identifier: "en_US_POSIX")),
              NSDecimalNumber(decimal: value).doubleValue.isFinite,
              value >= rateMinimum, value <= rateMaximum
        else { return .failure(.rateOutOfRange) }
        return .success(value)
    }

    /// The whole draft from the sheet's two inputs.
    static func draft(
        rateText: String,
        method: VehicleDeductionMethod?
    ) -> Result<NativeTaxSettingsDraft, NativeTaxSettingsError> {
        switch parseRateInput(rateText) {
        case .failure(let error): return .failure(error)
        case .success(let rate): return .success(NativeTaxSettingsDraft(taxIncomeRate: rate, vehicleDeductionMethod: method))
        }
    }

    /// Apply a draft onto the existing canonical field bag. Only provided fields
    /// are written; an unset draft field leaves the existing key untouched (which
    /// may be absent). Never emits an explicit null for these two fields.
    static func applying(
        _ draft: NativeTaxSettingsDraft,
        to fields: [String: Canonical.JSONValue]
    ) -> [String: Canonical.JSONValue] {
        var result = fields
        if let rate = draft.taxIncomeRate {
            result["taxIncomeRate"] = .number(rate)
        }
        if let method = draft.vehicleDeductionMethod {
            result["vehicleDeductionMethod"] = .string(method.rawValue)
        }
        return result
    }

    /// The canonical values a full settings write should carry (used when there
    /// is no baseline record to edit, e.g. a brand-new settings blob). Absent
    /// stays absent: no key is emitted for an unset field.
    static func canonicalFields(_ values: NativeTaxSettingsValues) -> [String: Canonical.JSONValue] {
        var fields: [String: Canonical.JSONValue] = [:]
        if let rate = values.taxIncomeRate { fields["taxIncomeRate"] = .number(rate) }
        if let method = values.vehicleDeductionMethod { fields["vehicleDeductionMethod"] = .string(method.rawValue) }
        return fields
    }

    /// Whether the summary should render the "choose a method" prompt.
    static func needsVehicleChoice(_ summary: TaxWindowSummary) -> Bool { summary.needsVehicleChoice }

    /// Whether the user has set an income-tax rate (0 still counts as set).
    static func incomeRateSet(_ values: NativeTaxSettingsValues) -> Bool { values.taxIncomeRate != nil }
}
