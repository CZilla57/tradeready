import Foundation

// MARK: - Setup checklist (task 10.03, requirements D4, D5)
//
// Pure port of `utils/setupChecklist.ts`. Completion is DERIVED from settings
// wherever possible (contact, logo, notifications) and recorded only where no
// honest derivation exists (`rate` = the user saved the Pricing settings page,
// `stripe` = connect-status came back connected). The stored state is
// device-local and deliberately NOT synced.

enum NativeSetupTaskID: String, CaseIterable, Codable, Identifiable {
    case contact, logo, rate, stripe, notifications

    var id: String { rawValue }

    var title: String {
        switch self {
        case .contact: "Add your contact details"
        case .logo: "Add your logo"
        case .rate: "Review your pricing defaults"
        case .stripe: "Connect a payment processor"
        case .notifications: "Turn on invoice reminders"
        }
    }

    var subtitle: String {
        switch self {
        case .contact: "Phone and address appear on invoices and estimates."
        case .logo: "Shown on estimates, invoices and PDFs."
        case .rate: "Labor rate, markup and margin power every estimate."
        case .stripe: "Send payment links so customers can pay you online."
        case .notifications: "Get notified before invoices go overdue."
        }
    }
}

/// `SetupChecklistState` — the only stored part of the checklist.
struct NativeSetupChecklistState: Codable, Equatable {
    var dismissed: Bool?
    /// Recorded completions for tasks with no honest derivation.
    var done: [String: Bool]?
    /// Sample-data users: the Today hero was used once and should hide.
    var sampleTourDone: Bool?

    init(dismissed: Bool? = nil, done: [String: Bool]? = nil, sampleTourDone: Bool? = nil) {
        self.dismissed = dismissed
        self.done = done
        self.sampleTourDone = sampleTourDone
    }

    func isDone(_ task: NativeSetupTaskID) -> Bool {
        done?[task.rawValue] == true
    }
}

/// A rendered task row.
struct NativeSetupTask: Equatable, Identifiable {
    var id: NativeSetupTaskID
    var title: String
    var subtitle: String
    var done: Bool
}

/// The settings subpage a task deep-links to. The notifications task never
/// reaches this map (it is handled in-card), but the enum stays total so a new
/// task cannot silently navigate nowhere.
enum NativeSetupRoute: Equatable {
    case settings
    case business
    case pricing
    case payments
}

/// The settings fields the derivation reads (canonical values only).
struct NativeSetupChecklistInput: Equatable {
    var phone: String
    var address: String
    var logoPhoto: String?
    var provider: String
    var providerKeys: [String: String]

    init(
        phone: String,
        address: String,
        logoPhoto: String?,
        provider: String,
        providerKeys: [String: String]
    ) {
        self.phone = phone
        self.address = address
        self.logoPhoto = logoPhoto
        self.provider = provider
        self.providerKeys = providerKeys
    }

    init(settings: Canonical.Settings) {
        self.init(
            phone: settings.phone,
            address: settings.address,
            logoPhoto: settings.logoPhoto,
            provider: settings.provider,
            providerKeys: settings.providerKeys
        )
    }

    /// A non-Stripe provider with a configured key satisfies the processor task.
    var hasAlternativeProcessor: Bool {
        guard provider != "stripe" else { return false }
        return !(providerKeys[provider] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var hasContactDetails: Bool {
        !phone.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var hasLogo: Bool {
        !(logoPhoto ?? "").isEmpty
    }

    /// `deriveSetupTasks` — exactly five tasks, in this order.
    func tasks(state: NativeSetupChecklistState, notificationsGranted: Bool) -> [NativeSetupTask] {
        NativeSetupTaskID.allCases.map { id in
            NativeSetupTask(
                id: id,
                title: id.title,
                subtitle: id.subtitle,
                done: isDone(id, state: state, notificationsGranted: notificationsGranted)
            )
        }
    }

    private func isDone(
        _ id: NativeSetupTaskID,
        state: NativeSetupChecklistState,
        notificationsGranted: Bool
    ) -> Bool {
        switch id {
        case .contact: hasContactDetails
        case .logo: hasLogo
        case .rate: state.isDone(.rate)
        case .stripe: state.isDone(.stripe) || hasAlternativeProcessor
        case .notifications: notificationsGranted
        }
    }

    /// The single shared definition of "the Finish-setting-up card is off the
    /// screen" — the insights card reads the same gate so the two cannot disagree.
    func isSetupComplete(state: NativeSetupChecklistState, notificationsGranted: Bool) -> Bool {
        if state.dismissed == true { return true }
        return tasks(state: state, notificationsGranted: notificationsGranted).allSatisfy(\.done)
    }
}

enum NativeSetupChecklist {
    /// The AsyncStorage key the React Native build used.
    static let storageKey = "setupChecklistState"

    static func route(for task: NativeSetupTaskID) -> NativeSetupRoute {
        switch task {
        case .contact, .logo: .business
        case .rate: .pricing
        case .stripe: .payments
        case .notifications: .settings
        }
    }

    /// `markSetupTaskDone` — idempotent: an already-recorded task keeps the state
    /// value untouched (so callers can skip the write).
    static func markingDone(
        _ task: NativeSetupTaskID,
        in state: NativeSetupChecklistState
    ) -> NativeSetupChecklistState {
        var updated = state
        var done = state.done ?? [:]
        done[task.rawValue] = true
        updated.done = done
        return updated
    }

    static func dismissing(_ state: NativeSetupChecklistState) -> NativeSetupChecklistState {
        var updated = state
        updated.dismissed = true
        return updated
    }

    static func markingSampleTourDone(
        _ state: NativeSetupChecklistState
    ) -> NativeSetupChecklistState {
        var updated = state
        updated.sampleTourDone = true
        return updated
    }

    /// The seed merge used once at activation: the stored owner state wins
    /// field-by-field (dismissal, sample tour, and each recorded task), and the
    /// migrated seed only fills what this device has never recorded.
    static func mergingSeed(
        _ seed: NativeSetupChecklistState,
        into stored: NativeSetupChecklistState
    ) -> NativeSetupChecklistState {
        var done = seed.done ?? [:]
        for (key, value) in stored.done ?? [:] { done[key] = value }
        return NativeSetupChecklistState(
            dismissed: stored.dismissed ?? seed.dismissed,
            done: done.isEmpty ? nil : done,
            sampleTourDone: stored.sampleTourDone ?? seed.sampleTourDone
        )
    }
}
