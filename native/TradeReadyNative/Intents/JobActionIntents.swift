import AppIntents
import Foundation
import WidgetKit

// Task 11.04 (A1–A3): the Siri-only intents. App target only (`N/Intents/`),
// registered by `TradeReadyShortcuts` in `N/NativeAppIntents.swift`.
//
// Contract: docs/native-phase-11-platform-hardening-contract-decisions.md §5.
// Every intent is a thin shell: the policy lives in `WidgetIntentEngine`
// (`N/Widgets/Shared/WidgetActionQueue.swift`) and the spoken text in
// `SiriIntentDialogs`. None of these writes canonical data:
// - writers append one action to `widgetActions` under the shared lock, with
//   the snapshot's `ownerTag` read in the same lock hold (§4.5); the app
//   replays the queue on its next foreground/launch (§4.6);
// - Start Trip writes only the private `activeTrip` key; Stop Trip turns it
//   into one `trip_log` action and clears it (§4.4);
// - Next Job and Outstanding read only the projected snapshot fields and
//   mutate nothing.
// Single availability floor: iOS 17.0 (§5.4).

@available(iOS 17.0, *)
struct NextJobIntent: AppIntent {
    static let title: LocalizedStringResource = "Next Job"

    init() {}

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let outcome = WidgetIntentEngine().nextJob()
        return .result(dialog: "\(SiriIntentDialogs.nextJob(outcome, now: Date()))")
    }
}

@available(iOS 17.0, *)
struct StartTripIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Mileage Trip"

    @Parameter(title: "Starting odometer")
    var odometerStart: Double

    init() {}

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let outcome = WidgetIntentEngine().startTrip(odometerStart: odometerStart)
        return .result(dialog: "\(SiriIntentDialogs.startTrip(outcome, odometerStart: odometerStart))")
    }
}

@available(iOS 17.0, *)
struct StopTripIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop Mileage Trip"

    @Parameter(title: "Ending odometer")
    var odometerEnd: Double

    init() {}

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let outcome = WidgetIntentEngine().stopTrip(odometerEnd: odometerEnd)
        WidgetIntentTimelines.reloadIfNeeded(wroteQueue: outcome.wroteQueue)
        return .result(dialog: "\(SiriIntentDialogs.stopTrip(outcome))")
    }
}

@available(iOS 17.0, *)
struct ClockInIntent: AppIntent {
    static let title: LocalizedStringResource = "Clock In"

    init() {}

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let outcome = WidgetIntentEngine().clockIn()
        WidgetIntentTimelines.reloadIfNeeded(wroteQueue: outcome.wroteQueue)
        return .result(dialog: "\(SiriIntentDialogs.clockIn(outcome))")
    }
}

@available(iOS 17.0, *)
struct ClockOutIntent: AppIntent {
    static let title: LocalizedStringResource = "Clock Out"

    init() {}

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let outcome = WidgetIntentEngine().clockOut()
        WidgetIntentTimelines.reloadIfNeeded(wroteQueue: outcome.wroteQueue)
        return .result(dialog: "\(SiriIntentDialogs.clockOut(outcome))")
    }
}

/// Contract §5.3. Raw values equal RN `ExpenseCategoryId` and
/// `WidgetExpenseCategory`; the display labels must stay literals (App Intents
/// metadata extraction reads them at build time). The host test checks these
/// literals against `WidgetExpenseCategory.label`.
@available(iOS 17.0, *)
enum SiriExpenseCategory: String, AppEnum {
    case materials
    case tools
    case fuel
    case labor
    case insurance
    case software
    case marketing
    case other

    static var typeDisplayRepresentation: TypeDisplayRepresentation =
        TypeDisplayRepresentation(name: "Expense Category")

    static var caseDisplayRepresentations: [SiriExpenseCategory: DisplayRepresentation] = [
        .materials: DisplayRepresentation(title: "Materials"),
        .tools: DisplayRepresentation(title: "Tools & Equipment"),
        .fuel: DisplayRepresentation(title: "Fuel & Transport"),
        .labor: DisplayRepresentation(title: "Subcontractors"),
        .insurance: DisplayRepresentation(title: "Insurance"),
        .software: DisplayRepresentation(title: "Software & Apps"),
        .marketing: DisplayRepresentation(title: "Marketing"),
        .other: DisplayRepresentation(title: "Other"),
    ]

    var queueCategory: WidgetExpenseCategory {
        switch self {
        case .materials: return .materials
        case .tools: return .tools
        case .fuel: return .fuel
        case .labor: return .labor
        case .insurance: return .insurance
        case .software: return .software
        case .marketing: return .marketing
        case .other: return .other
        }
    }
}

@available(iOS 17.0, *)
struct LogExpenseIntent: AppIntent {
    static let title: LocalizedStringResource = "Log Expense"

    @Parameter(title: "Amount in dollars")
    var amount: Double

    @Parameter(title: "Category")
    var category: SiriExpenseCategory

    /// Optional (native choice, contract §5.1 row 7): Siri may skip it; empty
    /// or absent is filed as "Logged via Siri" by replay.
    @Parameter(title: "What was it for?")
    var expenseDescription: String?

    init() {}

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let outcome = WidgetIntentEngine().logExpense(
            amount: amount,
            category: category.queueCategory,
            description: expenseDescription
        )
        WidgetIntentTimelines.reloadIfNeeded(wroteQueue: outcome.wroteQueue)
        return .result(dialog: "\(SiriIntentDialogs.logExpense(outcome))")
    }
}

@available(iOS 17.0, *)
struct OutstandingIntent: AppIntent {
    static let title: LocalizedStringResource = "Outstanding Invoices"

    init() {}

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let outcome = WidgetIntentEngine().outstanding()
        return .result(dialog: "\(SiriIntentDialogs.outstanding(outcome))")
    }
}
