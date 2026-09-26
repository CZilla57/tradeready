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
//
// 12.00b.3 (G2) adds the sheet's state (`NativeTaxSettingsEditor`) for
// `N/NativeTaxSettingsView.swift`, and replaces the Foundation rate parser with
// ports of JS `trim`, `parseFloat` and `Number::toString`, so the rate the
// sheet accepts and stores is the one RN would.

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
    /// The sheet's 0…60 bound, inclusive, checked on the parsed JS double.
    static let rateBounds: ClosedRange<Double> = 0...60

    /// The sheet's rate field → draft value (TaxSettingsModal.tsx:66-77):
    /// `rate.trim()`; blank means "no change" (nil, no error); otherwise
    /// `parseFloat`, refused unless `Number.isFinite` and within 0…60. The bound
    /// applies to the rounded double, so "60.00000000000000001" is 60 and valid.
    static func parseRateInput(_ text: String) -> Result<Decimal?, NativeTaxSettingsError> {
        let trimmed = jsTrim(text)
        if trimmed.isEmpty { return .success(nil) }
        let parsed = jsParseFloat(trimmed)
        guard parsed.isFinite, rateBounds.contains(parsed) else { return .failure(.rateOutOfRange) }
        return .success(storedRate(parsed))
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

    // MARK: JS number parity (12.00b.3)
    //
    // The sheet trims and parses its rate text with JavaScript's own rules and
    // shows a stored rate with `String(n)`. A tax rate is a money input, so these
    // follow ECMAScript exactly rather than Foundation's number parsing.

    /// `String.prototype.trim`: strips ECMAScript WhiteSpace and LineTerminator
    /// code points (TAB, VT, FF, BOM, every Zs space, LF, CR, LS, PS) from both
    /// ends. NEL (U+0085) and the zero-width spaces are not whitespace to JS.
    static func jsTrim(_ text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        guard let first = scalars.firstIndex(where: { !isJSWhitespace($0) }),
              let last = scalars.lastIndex(where: { !isJSWhitespace($0) })
        else { return "" }
        var trimmed = String.UnicodeScalarView()
        trimmed.append(contentsOf: scalars[first...last])
        return String(trimmed)
    }

    /// `parseFloat`: the longest prefix that is a StrDecimalLiteral (an optional
    /// sign, then `Infinity` or ASCII digits with an optional fraction and an
    /// optional exponent), read as the nearest double. NaN when no prefix
    /// matches. Hex, numeric separators, commas and non-ASCII digits end the
    /// prefix, so "12,5" reads as 12 and "15%" as 15.
    static func jsParseFloat(_ text: String) -> Double {
        let scalars = Array(text.unicodeScalars.drop(while: isJSWhitespace))
        var index = 0
        func isDigit(_ at: Int) -> Bool { at < scalars.count && ("0"..."9").contains(scalars[at]) }
        func digitRun() -> String {
            var run = String.UnicodeScalarView()
            while isDigit(index) { run.append(scalars[index]); index += 1 }
            return String(run)
        }

        var sign = ""
        if index < scalars.count, scalars[index] == "+" || scalars[index] == "-" {
            sign = scalars[index] == "-" ? "-" : ""
            index += 1
        }
        let infinity = Array("Infinity".unicodeScalars)
        if scalars.count - index >= infinity.count, Array(scalars[index..<(index + infinity.count)]) == infinity {
            return sign == "-" ? -.infinity : .infinity
        }
        let whole = digitRun()
        var fraction = ""
        if index < scalars.count, scalars[index] == "." {
            index += 1
            fraction = digitRun()
        }
        guard !whole.isEmpty || !fraction.isEmpty else { return .nan }

        var exponent = ""
        if index < scalars.count, scalars[index] == "e" || scalars[index] == "E" {
            let mark = index
            index += 1
            var exponentSign = ""
            if index < scalars.count, scalars[index] == "+" || scalars[index] == "-" {
                exponentSign = scalars[index] == "-" ? "-" : ""
                index += 1
            }
            let exponentDigits = digitRun()
            if exponentDigits.isEmpty { index = mark } else { exponent = "e" + exponentSign + exponentDigits }
        }
        let literal = sign + (whole.isEmpty ? "0" : whole) + "." + (fraction.isEmpty ? "0" : fraction) + exponent
        return Double(literal) ?? .nan
    }

    /// `Number::toString` (what `String(n)` and JSON.stringify print): the
    /// shortest round-trip digits, plain notation for 1e-7 < |n| < 1e21 and
    /// `de±x` exponent notation outside it. -0 prints as "0".
    static func jsNumberString(_ value: Double) -> String {
        if value.isNaN { return "NaN" }
        if value.isInfinite { return value < 0 ? "-Infinity" : "Infinity" }
        if value == 0 { return "0" }
        // Swift's description is the shortest round-trip form; only the
        // notation differs from JS ("1e-07", "18.0"), so re-lay the digits.
        let text = "\(value.magnitude)"
        var mantissa = Substring(text)
        var exponent = 0
        if let marker = text.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            mantissa = text[..<marker]
            exponent = Int(text[text.index(after: marker)...]) ?? 0
        }
        let parts = mantissa.split(separator: ".", omittingEmptySubsequences: false)
        let wholePart = parts.first.map(String.init) ?? ""
        var digits = wholePart + (parts.count > 1 ? String(parts[1]) : "")
        var pointIndex = wholePart.count + exponent
        while digits.first == "0" { digits.removeFirst(); pointIndex -= 1 }
        while digits.last == "0" { digits.removeLast() }

        let k = digits.count
        let n = pointIndex
        let sign = value < 0 ? "-" : ""
        if k <= n, n <= 21 {
            return sign + digits + String(repeating: "0", count: n - k)
        }
        if 0 < n, n <= 21 {
            return sign + digits.prefix(n) + "." + digits.dropFirst(n)
        }
        if -6 < n, n <= 0 {
            return sign + "0." + String(repeating: "0", count: -n) + digits
        }
        let power = n - 1
        let exponentText = "e" + (power < 0 ? "-" : "+") + String(power.magnitude)
        if k == 1 { return sign + digits + exponentText }
        return sign + digits.prefix(1) + "." + digits.dropFirst(1) + exponentText
    }

    /// The field text for a stored rate: `String(settings.taxIncomeRate)`, or ''
    /// when unset (TaxSettingsModal.tsx:57-61).
    static func rateSeedText(_ rate: Decimal?) -> String {
        guard let rate else { return "" }
        return jsNumberString(Double(rate.description) ?? .nan)
    }

    /// An accepted rate as the canonical number: the text JSON.stringify writes
    /// for the JS double, so -0 is stored as 0. Under 1e-128 the canonical
    /// number cannot hold the value and 0 is stored; the income-tax figure is
    /// the same to the cent.
    static func storedRate(_ value: Double) -> Decimal {
        Decimal(string: jsNumberString(value), locale: Locale(identifier: "en_US_POSIX")) ?? 0
    }

    private static func isJSWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0xFEFF, 0x2028, 0x2029: return true
        default: return scalar.properties.generalCategory == .spaceSeparator
        }
    }
}

// MARK: - Settings sheet state (12.00b.3, requirement G2)

/// The tax set-aside sheet's state, ported from RN
/// `components/money/TaxSettingsModal.tsx`. Seeded from the live settings each
/// time the sheet opens (:55-63); `save()` is `handleSave` (:65-81).
struct NativeTaxSettingsEditor: Equatable {
    /// The rate field: `String(settings.taxIncomeRate)`, or '' when unset.
    var rateText: String
    /// RN's `method` state: the stored string as-is, so a value outside the
    /// union still counts as chosen for the unset note, as `!method` does.
    private(set) var storedMethod: String?
    /// `settings.mileageRate ?? DEFAULT_MILEAGE_RATE` (:83), for the help copy.
    let mileageRate: Decimal

    init(settings: Canonical.Settings?) {
        rateText = NativeTaxSettings.rateSeedText(settings?.taxIncomeRate)
        storedMethod = settings?.vehicleDeductionMethod
        mileageRate = settings?.mileageRate ?? TaxWindowSettings().mileageRate
    }

    /// The chip shown as selected: nil when unset or outside the union.
    var selectedMethod: VehicleDeductionMethod? {
        storedMethod.flatMap(VehicleDeductionMethod.init(rawValue:))
    }

    /// A chip tap. There is deliberately no way back to "not chosen" (:6-9).
    mutating func select(_ method: VehicleDeductionMethod) {
        storedMethod = method.rawValue
    }

    /// `{!method && <Text>No method chosen yet.</Text>}` (:153-155).
    var showsMethodUnsetNote: Bool { (storedMethod ?? "").isEmpty }

    /// The rate check first, then `if (method) draft.vehicleDeductionMethod =
    /// method` — so the seeded method is re-sent. A stored method outside the
    /// union cannot be expressed in the draft and is left unchanged, which is
    /// the value RN writes back.
    func save() -> Result<NativeTaxSettingsDraft, NativeTaxSettingsError> {
        NativeTaxSettings.draft(rateText: rateText, method: selectedMethod)
    }
}
