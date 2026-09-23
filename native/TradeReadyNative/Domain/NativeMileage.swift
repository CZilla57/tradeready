import Foundation

// MARK: - Mileage and trip domain (task 9.03, requirements T1)
//
// Pure port of `utils/mileageUtils.ts` plus the trip-editor validation and the
// canonical record projection used by `screens/AddTripScreen.tsx`. No I/O and no
// canonical writes happen here — callers hand the projection to the store.
//
// Rate resolution: RN keeps a single user-set `settings.mileageRate` (labelled
// "per tax year" in Settings copy) with a default of 0.70; there is no per-year
// table. That contract is reproduced exactly (see the phase 9 contract doc §7).

struct NativeMileageSummary: Equatable {
    var tripCount: Int
    var totalMiles: Decimal
    var deduction: Decimal
}

/// One trip endpoint — `null` jobId means the base ("Home / Shop").
struct NativeTripEndpoint: Equatable {
    var jobId: String?
    var label: String

    static let home = NativeTripEndpoint(jobId: nil, label: NativeMileage.homeLabel)
}

/// A trip editor draft, mirroring the strings the RN form holds before save.
struct NativeTripDraft: Equatable {
    var date: String
    var odometerStartText: String
    var odometerEndText: String
    var from: NativeTripEndpoint
    var to: NativeTripEndpoint
    var purpose: String
}

enum NativeTripValidationError: Equatable {
    /// "Enter the trip date as YYYY-MM-DD."
    case invalidDate
    /// "Enter both start and end odometer readings."
    case missingReadings
    /// "End reading must be greater than or equal to the start reading."
    case endBeforeStart
}

enum NativeMileage {
    /// IRS standard mileage rate default ($/mile).
    static let defaultMileageRate = FinancialDecimal.value("0.70")

    /// Label used when a trip endpoint is the user's base rather than a job.
    static let homeLabel = "Home / Shop"

    /// `computeTripMiles`: end − start, never negative, rounded to 0.1.
    static func computeTripMiles(start: Decimal, end: Decimal) -> Decimal {
        let raw = end - start
        return roundTenths(FinancialDecimal.maximum(0, raw))
    }

    /// `Math.round(n * 10) / 10` over the same JS double semantics RN uses.
    private static func roundTenths(_ value: Decimal) -> Decimal {
        let double = NSDecimalNumber(decimal: value).doubleValue
        guard double.isFinite else { return 0 }
        let rounded = (double * 10).rounded(.toNearestOrAwayFromZero) / 10
        return Decimal(string: String(rounded), locale: Locale(identifier: "en_US_POSIX")) ?? 0
    }

    /// `mileageSummary`: in-range trips, 0.1-rounded miles, rate-based deduction.
    static func summary(
        trips: [Canonical.Trip],
        start: Date,
        end: Date,
        rate: Decimal
    ) -> NativeMileageSummary {
        let inRange = trips.filter { NativeCashBasis.isInRange($0.date, start: start, end: end) }
        let totalMiles = roundTenths(inRange.reduce(Decimal.zero) { $0 + $1.miles })
        let deduction = FinancialDecimal.javascriptCents(totalMiles * rate)
        return NativeMileageSummary(tripCount: inRange.count, totalMiles: totalMiles, deduction: deduction)
    }

    /// `formatMiles`: one decimal + " mi".
    static func formatMiles(_ miles: Decimal) -> String {
        String(format: "%.1f mi", NSDecimalNumber(decimal: miles).doubleValue)
    }

    /// `settings.mileageRate ?? DEFAULT_MILEAGE_RATE`.
    static func effectiveRate(_ settings: Canonical.Settings?) -> Decimal {
        settings?.mileageRate ?? defaultMileageRate
    }

    /// `generateTripId`: `Date.now()` + a short base-36 suffix. The suffix is
    /// injected so tests are deterministic; production passes a fresh value.
    static func generateTripId(nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000), suffix: String) -> String {
        String(nowMs) + suffix
    }

    // MARK: Editor validation + projection

    /// Parsed readings, mirroring `parseFloat(text) || 0`.
    static func reading(_ text: String) -> Decimal {
        Decimal(string: text.trimmingCharacters(in: .whitespaces), locale: Locale(identifier: "en_US_POSIX")) ?? 0
    }

    /// True when the end reading is strictly below the start (the form's
    /// `invalid` flag; equal readings are allowed).
    static func endBelowStart(_ draft: NativeTripDraft) -> Bool {
        guard !draft.odometerEndText.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        return reading(draft.odometerEndText) < reading(draft.odometerStartText)
    }

    /// Live distance preview for the editor.
    static func previewMiles(_ draft: NativeTripDraft) -> Decimal {
        computeTripMiles(start: reading(draft.odometerStartText), end: reading(draft.odometerEndText))
    }

    /// Strict real-calendar `YYYY-MM-DD` check. RN accepts any `Date`-parseable
    /// string and stores it verbatim; native refuses to persist a non-ISO date
    /// (documented tightening — a stored "03/10/2026" would corrupt every
    /// downstream window comparison).
    static func isValidDate(_ dateString: String) -> Bool {
        // `parseLocalDate` already enforces the strict `\d{4}-\d{2}-\d{2}` shape;
        // the component round-trip then rejects rollovers like 2026-02-31.
        let parts = dateString.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return false }
        guard let date = NativeCashBasis.parseLocalDate(dateString) else { return false }
        let (year, month, day) = NativeCashBasis.localComponents(date)
        return year == parts[0] && month == parts[1] - 1 && day == parts[2]
    }

    /// Whether the draft can be saved, and why not when it cannot.
    static func validationError(_ draft: NativeTripDraft) -> NativeTripValidationError? {
        if draft.date.isEmpty || !isValidDate(draft.date) { return .invalidDate }
        if draft.odometerStartText.trimmingCharacters(in: .whitespaces).isEmpty
            || draft.odometerEndText.trimmingCharacters(in: .whitespaces).isEmpty {
            return .missingReadings
        }
        if endBelowStart(draft) { return .endBeforeStart }
        return nil
    }

    /// Create/edit projection. `existing` is the canonical record being edited,
    /// or `nil` for a create. Unknown/forward-compatible fields survive an edit
    /// because the projection is expressed as canonical field updates over the
    /// existing record (RN replaces the whole record and would drop them — that
    /// lossiness is deliberately not reproduced).
    static func projectedFields(
        draft: NativeTripDraft,
        existing: Canonical.Trip?,
        tripID: String,
        createdAt: String
    ) -> [String: Canonical.JSONValue] {
        let startReading = reading(draft.odometerStartText)
        let endReading = reading(draft.odometerEndText)
        return [
            "id": .string(tripID),
            "date": .string(draft.date),
            "odometerStart": .number(startReading),
            "odometerEnd": .number(endReading),
            "miles": .number(computeTripMiles(start: startReading, end: endReading)),
            "fromJobId": draft.from.jobId.map { Canonical.JSONValue.string($0) } ?? .null,
            "fromLabel": .string(draft.from.label),
            "toJobId": draft.to.jobId.map { Canonical.JSONValue.string($0) } ?? .null,
            "toLabel": .string(draft.to.label),
            "purpose": .string(draft.purpose.trimmingCharacters(in: .whitespaces)),
            // Editing preserves the original createdAt ("existing?.createdAt || now").
            "createdAt": .string(existing?.createdAt ?? createdAt),
        ]
    }

    /// Job chips for the endpoint picker: `customerName || title || 'Job'`.
    static func endpointLabel(for job: Canonical.Job) -> String {
        if !job.customerName.isEmpty { return job.customerName }
        if !job.title.isEmpty { return job.title }
        return "Job"
    }
}
