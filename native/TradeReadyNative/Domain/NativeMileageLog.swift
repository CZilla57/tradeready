import Foundation

// MARK: - Mileage log presentation (task 9.11, requirements T1, T2 rates)
//
// The screen-level half of `screens/MileageLogScreen.tsx` and
// `screens/AddTripScreen.tsx`: the period row list, the summary card copy, the
// endpoint chips, the validation alerts, and the editor's live distance line.
// All mileage math stays in `NativeMileage` (9.03); this file only projects it
// for display and keeps the RN copy in one place.

/// One row of the log: route, date, optional purpose, and miles.
struct NativeTripLogRow: Equatable {
    var id: String
    /// "Home / Shop → Alice"
    var routeText: String
    /// The stored date string, verbatim — RN renders `item.date` as authored.
    var dateText: String
    var purpose: String
    /// "12.4 mi"
    var milesText: String
    var accessibilityLabel: String
}

/// The "Estimated deduction" card.
struct NativeMileageSummaryCard: Equatable {
    var label = "Estimated deduction"
    var deductionText: String
    /// "12.4 mi · 2 trips · $0.70/mi"
    var subtitle: String
}

enum NativeMileageLog {
    static let summaryLabel = "Estimated deduction"

    /// Rate row copy. Deliberately not RN's TaxSetAsideCard line ("not synced"):
    /// `trips` is a synced canonical collection in this app, so the honest
    /// statement is that the rate is a saved setting, not a device-local fact.
    static let rateDisclosure = "Applies to every logged trip in the deduction estimate. Saved with your settings."

    /// In-range trips, newest first. RN compares the date strings directly
    /// (`a.date < b.date ? 1 : -1`) rather than parsing them.
    static func rows(
        trips: [Canonical.Trip],
        start: Date,
        end: Date
    ) -> [NativeTripLogRow] {
        trips
            .filter { NativeCashBasis.isInRange($0.date, start: start, end: end) }
            .sorted { $0.date > $1.date }
            .map { trip in
                let milesText = NativeMileage.formatMiles(trip.miles)
                return NativeTripLogRow(
                    id: trip.id,
                    routeText: "\(trip.fromLabel) → \(trip.toLabel)",
                    dateText: trip.date,
                    purpose: trip.purpose,
                    milesText: milesText,
                    accessibilityLabel: "Trip \(trip.fromLabel) to \(trip.toLabel), \(trip.date), \(milesText)"
                )
            }
    }

    /// The summary card for the windowed trips at the effective rate.
    static func summaryCard(
        trips: [Canonical.Trip],
        start: Date,
        end: Date,
        rate: Decimal
    ) -> NativeMileageSummaryCard {
        let summary = NativeMileage.summary(trips: trips, start: start, end: end, rate: rate)
        let tripLabel = summary.tripCount == 1 ? "trip" : "trips"
        return NativeMileageSummaryCard(
            deductionText: NativeMoneyFormat.money(summary.deduction),
            subtitle: "\(NativeMileage.formatMiles(summary.totalMiles)) · \(summary.tripCount) \(tripLabel) · "
                + "\(NativeMoneyFormat.money(rate))/mi"
        )
    }

    /// Endpoint chips: the base first, then every job. RN maps `loadJobs()` in
    /// order and does not filter archived jobs out of this picker.
    static func endpointChips(_ jobs: [Canonical.Job]) -> [NativeTripEndpoint] {
        [.home] + jobs.map { NativeTripEndpoint(jobId: $0.id, label: NativeMileage.endpointLabel(for: $0)) }
    }

    /// `Alert.alert` copy from `AddTripScreen.handleSave`, in RN's order.
    static func validationAlert(_ error: NativeTripValidationError) -> (title: String, message: String) {
        switch error {
        case .invalidDate: ("Invalid date", "Enter the trip date as YYYY-MM-DD.")
        case .missingReadings: ("Missing readings", "Enter both start and end odometer readings.")
        case .endBeforeStart: ("Check readings", "End reading must be greater than or equal to the start reading.")
        }
    }

    /// The live line under the odometer fields.
    static func distanceText(_ draft: NativeTripDraft) -> String {
        NativeMileage.endBelowStart(draft)
            ? "End reading is less than start"
            : "Trip distance: \(NativeMileage.formatMiles(NativeMileage.previewMiles(draft)))"
    }

    /// Seeds the editor from an existing trip. RN writes
    /// `String(t.odometerStart || '')`, which blanks a genuine `0` reading and
    /// then forces the user to re-enter both readings to save; native keeps the
    /// value so a 0-reading trip round-trips unchanged (recorded difference).
    static func draft(from trip: Canonical.Trip) -> NativeTripDraft {
        NativeTripDraft(
            date: trip.date,
            odometerStartText: readingText(trip.odometerStart),
            odometerEndText: readingText(trip.odometerEnd),
            from: NativeTripEndpoint(jobId: trip.fromJobId, label: trip.fromLabel),
            to: NativeTripEndpoint(jobId: trip.toJobId, label: trip.toLabel),
            purpose: trip.purpose
        )
    }

    /// A new trip: today's local day, base → base, empty readings.
    static func newDraft(now: Date = Date(), calendar: Calendar = NativeCashBasis.localCalendar) -> NativeTripDraft {
        NativeTripDraft(
            date: NativeCashBasis.ymd(now),
            odometerStartText: "",
            odometerEndText: "",
            from: .home,
            to: .home,
            purpose: ""
        )
    }

    /// Trimmed numeric text for an odometer reading ("45210", "45240.5").
    static func readingText(_ value: Decimal) -> String {
        NSDecimalNumber(decimal: value).stringValue
    }
}
