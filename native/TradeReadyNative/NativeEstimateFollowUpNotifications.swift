import Combine
import Foundation
import UserNotifications

enum NativeNotificationPermissionState: Equatable, Sendable {
    case unknown
    case notRequested
    case denied
    case authorized
}

/// Outcome of `NativeEstimateFollowUpNotificationCoordinator.promptForInvoiceRemindersIfNeeded()`
/// (task 10.05, N1) — informational only; every case is a legitimate no-repeat
/// outcome and none of them is surfaced as an error.
enum NativeInvoiceReminderPromptOutcome: Equatable, Sendable {
    /// No exact signed-in workspace; nothing was read or stamped.
    case noWorkspace
    /// The owner-bound flag was already set; silent, matching RN.
    case alreadyShown
    /// The flag was just stamped, but OS permission was already settled
    /// (`authorized`/`denied`); no request was made, matching RN's "silent
    /// when the OS status is already settled".
    case permissionAlreadySettled
    /// OS permission was undetermined: the flag was stamped and a soft-ask
    /// (RN's `Alert.alert('Invoice reminders', …)`) is now pending the
    /// caller's "Not now"/"Turn on" choice — see `pendingInvoiceReminderPrompt`,
    /// `confirmInvoiceReminderPrompt()`, `dismissInvoiceReminderPrompt()`. No
    /// OS permission dialog fires yet.
    case pendingUserChoice
    /// Final-review m2: the exact workspace changed (sign-out / account
    /// switch) during the permission-state await; nothing was stamped for
    /// either account and no soft-ask is pending.
    case ownerChanged
}

@MainActor
protocol NativeEstimateFollowUpNotificationCenter: AnyObject {
    func install(delegate: any UNUserNotificationCenterDelegate)
    func authorizationState() async -> NativeNotificationPermissionState
    func requestAuthorization() async throws
    func pendingNotificationIdentifiers() async -> [String]
    func removePendingNotificationRequests(withIdentifiers identifiers: [String])
    func schedule(_ notification: NativeEstimateFollowUpNotification, secondsFromNow: TimeInterval) async throws
    /// Registers the app's `UNNotificationCategory` set (task 10.05, N1). The
    /// default implementation below is a no-op so every pre-existing fake
    /// center keeps compiling unmodified; only the system center and a fake
    /// built to assert registration need to override it.
    func registerCategories(_ categories: Set<UNNotificationCategory>)
}

@MainActor
final class NativeSystemEstimateFollowUpNotificationCenter: NativeEstimateFollowUpNotificationCenter {
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func install(delegate: any UNUserNotificationCenterDelegate) {
        center.delegate = delegate
    }

    func authorizationState() async -> NativeNotificationPermissionState {
        switch await center.notificationSettings().authorizationStatus {
        case .notDetermined: .notRequested
        case .denied: .denied
        case .authorized, .provisional, .ephemeral: .authorized
        @unknown default: .unknown
        }
    }

    func requestAuthorization() async throws {
        _ = try await center.requestAuthorization(options: [.alert, .sound, .badge])
    }

    func pendingNotificationIdentifiers() async -> [String] {
        await center.pendingNotificationRequests().map(\.identifier)
    }

    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    func schedule(
        _ notification: NativeEstimateFollowUpNotification,
        secondsFromNow: TimeInterval
    ) async throws {
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        content.userInfo = [
            "type": "estimate_follow_up",
            "jobId": notification.jobID
        ]
        content.categoryIdentifier = NativeNotificationNamespace.estimateFollowUp.payloadType
        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: max(1, secondsFromNow),
            repeats: false
        )
        try await center.add(.init(
            identifier: notification.identifier,
            content: content,
            trigger: trigger
        ))
    }

    func schedule(
        _ item: NativeNotificationPlanItem,
        secondsFromNow: TimeInterval
    ) async throws {
        let content = UNMutableNotificationContent()
        content.title = item.title
        content.body = item.body
        content.userInfo = [
            "type": item.route.namespace.payloadType,
            "jobId": item.route.jobID
        ]
        content.categoryIdentifier = item.route.namespace.payloadType
        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: max(1, secondsFromNow),
            repeats: false
        )
        try await center.add(.init(
            identifier: item.identifier,
            content: content,
            trigger: trigger
        ))
    }

    func scheduleInvoiceItem(
        _ item: NativeNotificationPlanItem,
        secondsFromNow: TimeInterval
    ) async throws {
        let content = UNMutableNotificationContent()
        content.title = item.title
        content.body = item.body
        content.userInfo = item.route.payloadUserInfo
        content.categoryIdentifier = item.route.namespace.payloadType
        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: max(1, secondsFromNow),
            repeats: false
        )
        try await center.add(.init(
            identifier: item.identifier,
            content: content,
            trigger: trigger
        ))
    }

    /// Real, one-time-per-launch `UNUserNotificationCenter.setNotificationCategories`
    /// call (task 10.05, N1). See `NativeNotificationCategories` for the
    /// per-family set; none of their actions send anything to a customer.
    func registerCategories(_ categories: Set<UNNotificationCategory>) {
        center.setNotificationCategories(categories)
    }
}

/// Owner-bound local-notification namespaces managed by
/// ``NativeEstimateFollowUpNotificationCoordinator``.
///
/// The coordinator owns at most these three identifier families. Every other
/// pending request (Expo `inv_`/`rinv_` reminders, system notifications, …)
/// is foreign: it is never removed, and it consumes shared-cap budget before
/// any owned namespace schedules. Within the owned set the scheduling
/// priority is fixed:
///
/// 1. `est_` — estimate follow-ups (pre-existing behavior, first claim).
/// 2. `appt_` — appointment confirmations (Batch 1 plugs a selector in).
/// 3. `review_` — review requests (Batch 2 plugs a selector in).
///
/// The ordering keeps the Batch 0 `est_`-first guarantee intact while giving
/// later batches a documented slot. Note the RN sweep
/// (`utils/notifications.ts`) orders differently (invoice dunning, then
/// appointments, then estimates, then reviews); the native coordinator only
/// arbitrates its own three namespaces and always leaves foreign families
/// untouched.
enum NativeNotificationNamespace: String, Sendable, CaseIterable {
    case estimateFollowUp
    case appointment
    case review
    case invoiceReminder
    case recurringInvoice

    /// Identifier prefix of the namespace (`est_`, `appt_`, `review_`,
    /// `inv_`, `rinv_`).
    var prefix: String {
        switch self {
        case .estimateFollowUp: "est_"
        case .appointment: "appt_"
        case .review: "review_"
        case .invoiceReminder: "inv_"
        case .recurringInvoice: "rinv_"
        }
    }

    /// `data.type` payload stored in the notification content, matching the RN
    /// producers (`estimate_follow_up`, `appointment_confirm`,
    /// `review_request`). Invoice reminders use `overdue_outreach` for the
    /// tap-to-send variant and `overdue_invoice` for the plain variant (see
    /// `NativeNotificationRoute.payloadType`); recurring plans use
    /// `recurring_invoice`.
    var payloadType: String {
        switch self {
        case .estimateFollowUp: "estimate_follow_up"
        case .appointment: "appointment_confirm"
        case .review: "review_request"
        case .invoiceReminder: "overdue_invoice"
        case .recurringInvoice: "recurring_invoice"
        }
    }

    /// Fixed scheduling priority inside the shared 60-request cap. Lower wins.
    /// Invoice families schedule after the pre-existing three so the
    /// established `est_`-first guarantee is unchanged.
    var schedulingPriority: Int {
        switch self {
        case .estimateFollowUp: 0
        case .appointment: 1
        case .review: 2
        case .invoiceReminder: 3
        case .recurringInvoice: 4
        }
    }
}

/// Typed tap-routing destination for every owned namespace.
enum NativeNotificationRoute: Equatable, Sendable {
    case estimateFollowUp(jobID: String)
    case appointmentConfirm(jobID: String)
    case reviewRequest(jobID: String)
    case invoiceReminder(invoiceID: String, daysPastDue: Int, opensOutreach: Bool)
    case recurringInvoiceReminder(ruleID: String)

    var namespace: NativeNotificationNamespace {
        switch self {
        case .estimateFollowUp: .estimateFollowUp
        case .appointmentConfirm: .appointment
        case .reviewRequest: .review
        case .invoiceReminder: .invoiceReminder
        case .recurringInvoiceReminder: .recurringInvoice
        }
    }

    var jobID: String {
        switch self {
        case let .estimateFollowUp(jobID): jobID
        case let .appointmentConfirm(jobID): jobID
        case let .reviewRequest(jobID): jobID
        case let .invoiceReminder(invoiceID, _, _): invoiceID
        case let .recurringInvoiceReminder(ruleID): ruleID
        }
    }

    /// Payload type for this route. The invoice reminder distinguishes its
    /// tap-to-send variant (`overdue_outreach`, matching the RN producer)
    /// from the plain variant.
    var payloadType: String {
        switch self {
        case .invoiceReminder(_, _, let opensOutreach):
            return opensOutreach ? "overdue_outreach" : namespace.payloadType
        default:
            return namespace.payloadType
        }
    }

    /// Full `userInfo` payload for this route. Invoice payloads carry
    /// `invoiceId`/`ruleId` keys (matching the RN producers) rather than the
    /// generic `jobId` key.
    var payloadUserInfo: [String: Any] {
        var info: [String: Any] = ["type": payloadType]
        switch self {
        case .invoiceReminder(let invoiceID, let daysPastDue, _):
            info["invoiceId"] = invoiceID
            info["daysPastDue"] = daysPastDue
        case .recurringInvoiceReminder(let ruleID):
            info["ruleId"] = ruleID
        default:
            info["jobId"] = jobID
        }
        return info
    }

    /// `est_<jobId>` / `appt_<jobId>` / `review_<jobId>`, matching the RN
    /// identifier schemes (`utils/notifications.ts`, `utils/reviewRequest.ts`).
    /// Invoice reminders use `inv_<invoiceId>_<days>d` and recurring plans
    /// use `rinv_<ruleId>`.
    var identifier: String {
        switch self {
        case .invoiceReminder(let invoiceID, let daysPastDue, _):
            return "inv_\(invoiceID)_\(daysPastDue)d"
        case .recurringInvoiceReminder(let ruleID):
            return "rinv_\(ruleID)"
        default:
            return namespace.prefix + jobID
        }
    }

    /// Decodes a delivered notification's `userInfo`. The estimate branch
    /// delegates to the pre-existing helper so its trimming/256-character
    /// contract cannot drift; the appointment/review branches apply the same
    /// rule. Invoice branches accept the RN `invoiceId`/`ruleId` keys (and
    /// the generic `jobId` key for forward compatibility); a missing or
    /// blank record id fails closed. This also claims foreign Expo
    /// `inv_`/`rinv_` requests still pending from before migration — taps
    /// validate the workspace binding plus current record state before
    /// routing, so stale payloads fail closed.
    static func decode(userInfo: [AnyHashable: Any]) -> Self? {
        guard let type = userInfo["type"] as? String else { return nil }
        switch type {
        case NativeNotificationNamespace.estimateFollowUp.payloadType:
            guard let jobID = NativeEstimateFollowUp.notificationJobID(userInfo: userInfo) else {
                return nil
            }
            return .estimateFollowUp(jobID: jobID)
        case NativeNotificationNamespace.appointment.payloadType:
            guard let jobID = trimmedJobID(userInfo["jobId"]) else { return nil }
            return .appointmentConfirm(jobID: jobID)
        case NativeNotificationNamespace.review.payloadType:
            guard let jobID = trimmedJobID(userInfo["jobId"]) else { return nil }
            return .reviewRequest(jobID: jobID)
        case "overdue_outreach", "overdue_invoice":
            guard let invoiceID = trimmedRecordID(userInfo["invoiceId"] ?? userInfo["jobId"]) else {
                return nil
            }
            let days = (userInfo["daysPastDue"] as? Int) ?? 0
            return .invoiceReminder(invoiceID: invoiceID, daysPastDue: days, opensOutreach: type == "overdue_outreach")
        case NativeNotificationNamespace.recurringInvoice.payloadType:
            guard let ruleID = trimmedRecordID(userInfo["ruleId"] ?? userInfo["jobId"]) else {
                return nil
            }
            return .recurringInvoiceReminder(ruleID: ruleID)
        default:
            return nil
        }
    }

    private static func trimmedRecordID(_ raw: Any?) -> String? {
        guard let raw = raw as? String else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 256 else { return nil }
        return value
    }

    private static func trimmedJobID(_ raw: Any?) -> String? {
        guard let raw = raw as? String else { return nil }
        let jobID = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !jobID.isEmpty, jobID.utf8.count <= 256 else { return nil }
        return jobID
    }
}

/// One schedulable owned-namespace notification. Batch 1/2 selectors return
/// these; the coordinator's sync loop schedules them with no modification.
struct NativeNotificationPlanItem: Equatable, Sendable {
    let identifier: String
    let jobID: String
    let title: String
    let body: String
    let route: NativeNotificationRoute
    let fireDate: Date
}

extension NativeNotificationPlanItem {
    init(estimate notification: NativeEstimateFollowUpNotification) {
        self.init(
            identifier: notification.identifier,
            jobID: notification.jobID,
            title: notification.title,
            body: notification.body,
            route: .estimateFollowUp(jobID: notification.jobID),
            fireDate: notification.fireDate
        )
    }
}

/// One injectable owned-namespace planner. Batch 1 passes an `.appointment`
/// entry, Batch 2 adds a `.review` entry; the core sync loop iterates this
/// array in canonical priority order without modification. Do not include
/// `.estimateFollowUp` here — the legacy `notificationPlan` owns `est_` and
/// such entries are ignored defensively.
struct NativeNotificationNamespacePlan {
    let namespace: NativeNotificationNamespace
    let items: @MainActor (Date) -> [NativeNotificationPlanItem]

    init(
        namespace: NativeNotificationNamespace,
        items: @escaping @MainActor (Date) -> [NativeNotificationPlanItem]
    ) {
        self.namespace = namespace
        self.items = items
    }
}

extension NativeEstimateFollowUpNotificationCenter {
    /// Default no-op so every pre-existing fake center (none of which cares
    /// about category registration) keeps conforming unmodified; the system
    /// center and any fake built to assert registration override this.
    func registerCategories(_ categories: Set<UNNotificationCategory>) {}

    /// Generic owned-namespace scheduling. The default implementation bridges
    /// through the pre-existing estimate primitive so existing fakes keep
    /// working; the system center overrides it to stamp the per-namespace
    /// payload type.
    func schedule(
        _ item: NativeNotificationPlanItem,
        secondsFromNow: TimeInterval
    ) async throws {
        try await schedule(
            NativeEstimateFollowUpNotification(
                identifier: item.identifier,
                jobID: item.jobID,
                title: item.title,
                body: item.body,
                fireDate: item.fireDate
            ),
            secondsFromNow: secondsFromNow
        )
    }

    /// Invoice-family scheduling with RN-compatible payload keys
    /// (`invoiceId`/`ruleId`, per-route `type`). The default bridges through
    /// the generic path so fakes keep recording; the system center stamps
    /// the exact producer payload.
    func scheduleInvoiceItem(
        _ item: NativeNotificationPlanItem,
        secondsFromNow: TimeInterval
    ) async throws {
        try await schedule(item, secondsFromNow: secondsFromNow)
    }
}

/// Owns only the `est_` local-notification namespace. Other notification
/// families remain untouched, and the shared 60-request ceiling accounts for
/// their already-pending requests before adding estimate follow-ups.
///
/// Batch 0.2 generalization: the same coordinator can additionally own the
/// `appt_` and `review_` namespaces via `namespacePlans`, without modifying
/// the core sync loop. Namespace management is opt-in per planner — a
/// coordinator built with the legacy inits manages `est_` only, so its
/// behavior is exactly the pre-Batch-0.2 behavior (an `appt_`-prefixed
/// pending request is foreign there and preserved). Passing an
/// `.appointment`/`.review` plan activates that namespace: its stale pending
/// requests are removed on every sweep (including sign-out, account change,
/// toggle-off, and denied permission), and its items schedule after `est_`
/// under the shared 60-request cap.
///
/// Per-namespace cleanup runs before the authorized guard on every pass, so
/// toggle-off (plan returns `[]`), sign-out/account-change (binding `nil` or
/// changed), and denied permission all converge to "no owned-namespace
/// requests pending" while foreign families are never touched.
@MainActor
final class NativeEstimateFollowUpNotificationCoordinator: NSObject, ObservableObject,
    UNUserNotificationCenterDelegate {
    @Published private(set) var permissionState: NativeNotificationPermissionState = .unknown
    /// Task 10.05 fix round 1 (N1): true while RN's pre-permission rationale
    /// ("Invoice reminders — Not now / Turn on") is awaiting the user's
    /// choice. The owner-bound flag has ALREADY been stamped by the time this
    /// becomes true, so a dismissed/ignored soft-ask never repeats. A
    /// SwiftUI `.alert` bound to this presents the exact RN copy; no OS
    /// permission dialog fires until `confirmInvoiceReminderPrompt()` runs.
    @Published private(set) var pendingInvoiceReminderPrompt = false

    private let center: any NativeEstimateFollowUpNotificationCenter
    private let exactWorkspaceBinding: @MainActor () -> String?
    private let notificationPlan: @MainActor (Date) -> [NativeEstimateFollowUpNotification]
    private let namespacePlans: [NativeNotificationNamespacePlan]
    private let openFollowUp: @MainActor (String) -> Void
    private let openOwnedRoute: (@MainActor (NativeNotificationRoute) -> Void)?
    /// Task 10.05 (N1): reads/stamps the owner-bound one-shot contextual
    /// prompt flag (`NativeReminderPromptStore`, keyed by the exact workspace
    /// binding). Defaults are fail-safe (`wasReminderPromptShown` defaults to
    /// `true`, i.e. "treat as already shown") so a caller that never injects
    /// the real store closures (a legacy convenience init, or a test that
    /// does not care about this feature) can never trigger the soft-ask or
    /// re-request indefinitely.
    private let wasReminderPromptShown: @MainActor () -> Bool
    private let markReminderPromptShown: @MainActor () -> Void
    /// The exact workspace binding the pending soft-ask was raised for.
    /// Cleared (along with `pendingInvoiceReminderPrompt`) the moment a
    /// `synchronize()` pass observes a different (or absent) binding — i.e.
    /// sign-out or account switch dismisses any pending alert.
    private var pendingInvoiceReminderPromptBinding: String?
    private var isSynchronizing = false
    private var needsResynchronization = false
    private var didRegisterCategories = false
    private static let identifierPrefix = "est_"
    private static let maximumScheduledCount = 60

    /// Prefixes this coordinator manages. `est_` is always owned; `appt_` and
    /// `review_` are owned only when a planner was injected for them.
    private static func ownedPrefixes(
        namespacePlans: [NativeNotificationNamespacePlan]
    ) -> [String] {
        [identifierPrefix] + namespacePlans.map(\.namespace.prefix)
    }

    convenience init(
        exactWorkspaceBinding: @escaping @MainActor () -> String?,
        notificationPlan: @escaping @MainActor (Date) -> [NativeEstimateFollowUpNotification],
        openFollowUp: @escaping @MainActor (String) -> Void
    ) {
        self.init(
            center: NativeSystemEstimateFollowUpNotificationCenter(),
            exactWorkspaceBinding: exactWorkspaceBinding,
            notificationPlan: notificationPlan,
            openFollowUp: openFollowUp
        )
    }

    convenience init(
        center: any NativeEstimateFollowUpNotificationCenter,
        exactWorkspaceBinding: @escaping @MainActor () -> String?,
        notificationPlan: @escaping @MainActor (Date) -> [NativeEstimateFollowUpNotification],
        openFollowUp: @escaping @MainActor (String) -> Void
    ) {
        self.init(
            center: center,
            exactWorkspaceBinding: exactWorkspaceBinding,
            notificationPlan: notificationPlan,
            namespacePlans: [],
            openFollowUp: openFollowUp,
            openOwnedRoute: nil
        )
    }

    /// Generalized designated init for Batch 1/2. `namespacePlans` carries at
    /// most one entry per non-estimate namespace (`.appointment` for Batch 1,
    /// `.review` for Batch 2); entries schedule in canonical priority order
    /// regardless of array order. `openOwnedRoute` receives taps for the
    /// non-estimate namespaces; `est_` taps always go to `openFollowUp`.
    init(
        center: any NativeEstimateFollowUpNotificationCenter,
        exactWorkspaceBinding: @escaping @MainActor () -> String?,
        notificationPlan: @escaping @MainActor (Date) -> [NativeEstimateFollowUpNotification],
        namespacePlans: [NativeNotificationNamespacePlan],
        openFollowUp: @escaping @MainActor (String) -> Void,
        openOwnedRoute: (@MainActor (NativeNotificationRoute) -> Void)? = nil,
        wasReminderPromptShown: @escaping @MainActor () -> Bool = { true },
        markReminderPromptShown: @escaping @MainActor () -> Void = {}
    ) {
        self.center = center
        self.exactWorkspaceBinding = exactWorkspaceBinding
        self.notificationPlan = notificationPlan
        // The legacy plan owns `est_`; ignore defensive duplicates.
        self.namespacePlans = namespacePlans.filter { $0.namespace != .estimateFollowUp }
        self.openFollowUp = openFollowUp
        self.openOwnedRoute = openOwnedRoute
        self.wasReminderPromptShown = wasReminderPromptShown
        self.markReminderPromptShown = markReminderPromptShown
        super.init()
        center.install(delegate: self)
    }

    func refreshPermissionState() async {
        permissionState = await center.authorizationState()
    }

    /// Registers the five per-family `UNNotificationCategory` entries exactly
    /// once per coordinator lifetime — the coordinator is constructed once at
    /// app launch and lives for the process, so this is "once per launch"
    /// (task 10.05, N1). A second call is a no-op and never re-invokes the
    /// underlying center.
    func registerCategoriesIfNeeded() {
        guard !didRegisterCategories else { return }
        didRegisterCategories = true
        center.registerCategories(NativeNotificationCategories.makeAll())
    }

    /// One-shot contextual invoice-reminder prompt (task 10.05, N1), mirroring
    /// RN's `promptForInvoiceReminders` (`utils/notifications.ts`): the flag is
    /// stamped BEFORE any permission request so a dismissed/undecided OS
    /// dialog never re-fires, the ask happens at most once, it is silent when
    /// the OS permission is already settled either way. When OS permission is
    /// undetermined, RN shows a custom rationale `Alert.alert('Invoice
    /// reminders', …)` BEFORE the real OS dialog fires — that alert is
    /// surfaced here via `pendingInvoiceReminderPrompt` rather than by calling
    /// `requestAuthorization()` directly; the caller (a root-level SwiftUI
    /// `.alert`) resolves it via `confirmInvoiceReminderPrompt()` ("Turn on")
    /// or `dismissInvoiceReminderPrompt()` ("Not now"). No-ops (no read, no
    /// stamp) without an exact signed-in workspace, matching every other
    /// owner-bound operation in this coordinator.
    @discardableResult
    func promptForInvoiceRemindersIfNeeded() async -> NativeInvoiceReminderPromptOutcome {
        guard let binding = exactWorkspaceBinding() else { return .noWorkspace }
        guard !wasReminderPromptShown() else { return .alreadyShown }
        await refreshPermissionState()
        // Final-review m2: `markReminderPromptShown` stamps through the
        // store's CURRENT binding, so an account switch during the await
        // above would otherwise stamp (and pend the alert for) the NEW
        // account. Re-check the exact owner captured before the await.
        guard exactWorkspaceBinding() == binding else { return .ownerChanged }
        // Stamp before any request/alert, regardless of the outcome below —
        // an already-settled permission is marked shown too, exactly like RN.
        markReminderPromptShown()
        guard permissionState == .notRequested else { return .permissionAlreadySettled }
        pendingInvoiceReminderPromptBinding = binding
        pendingInvoiceReminderPrompt = true
        return .pendingUserChoice
    }

    /// RN's "Turn on": resolves a pending soft-ask by firing the real OS
    /// permission request, and — on grant — running `synchronize()` exactly
    /// once. Safe to call even if the pending state was already cleared (by
    /// `dismissInvoiceReminderPrompt()` or a sign-out); it simply requests
    /// authorization and reports the result.
    @discardableResult
    func confirmInvoiceReminderPrompt() async -> Bool {
        pendingInvoiceReminderPrompt = false
        pendingInvoiceReminderPromptBinding = nil
        let granted = await requestAuthorization()
        if granted { await synchronize() }
        return granted
    }

    /// RN's "Not now": clears the pending soft-ask without requesting OS
    /// permission. The owner-bound flag was already stamped before the alert
    /// appeared, so it stays stamped — the prompt never repeats, matching RN.
    func dismissInvoiceReminderPrompt() {
        pendingInvoiceReminderPrompt = false
        pendingInvoiceReminderPromptBinding = nil
    }

    func requestAuthorization() async -> Bool {
        guard exactWorkspaceBinding() != nil else {
            await refreshPermissionState()
            return false
        }
        do {
            try await center.requestAuthorization()
        } catch {
            await refreshPermissionState()
            return false
        }
        await refreshPermissionState()
        return permissionState == .authorized
    }

    func synchronize(now: Date = .now) async {
        if isSynchronizing {
            needsResynchronization = true
            return
        }

        isSynchronizing = true
        var passNow = now
        repeat {
            needsResynchronization = false
            await synchronizeOnce(now: passNow)
            passNow = .now
        } while needsResynchronization
        isSynchronizing = false
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let data = response.notification.request.content.userInfo
        guard let route = NativeNotificationRoute.decode(userInfo: data) else {
            completionHandler()
            return
        }
        switch route {
        case .estimateFollowUp(let jobID):
            Task { @MainActor [weak self] in self?.openFollowUp(jobID) }
        case .appointmentConfirm, .reviewRequest, .invoiceReminder, .recurringInvoiceReminder:
            Task { @MainActor [weak self] in self?.openOwnedRoute?(route) }
        }
        completionHandler()
    }

    /// Ordered owned-namespace schedule: `est_` first (pre-existing priority),
    /// then injected namespaces in canonical priority order (`appt_`,
    /// `review_`, `inv_`, `rinv_`). With no injected plans this is exactly
    /// the legacy plan.
    private func notificationItems(now: Date) -> [NativeNotificationPlanItem] {
        var items = notificationPlan(now).map(NativeNotificationPlanItem.init(estimate:))
        for plan in namespacePlans.sorted(by: {
            $0.namespace.schedulingPriority < $1.namespace.schedulingPriority
        }) {
            items.append(contentsOf: plan.items(now))
        }
        return items
    }

    private func synchronizeOnce(now: Date) async {
        let expectedBinding = exactWorkspaceBinding()

        // Task 10.05 fix round 1 (N1): a pending soft-ask belongs to the exact
        // workspace it was raised for. Sign-out or account-change (the
        // binding no longer matches, or is gone entirely) dismisses it — the
        // user should never see "Turn on"/"Not now" for an account they've
        // left.
        if let promptBinding = pendingInvoiceReminderPromptBinding,
           promptBinding != expectedBinding {
            pendingInvoiceReminderPrompt = false
            pendingInvoiceReminderPromptBinding = nil
        }

        permissionState = await center.authorizationState()

        let pending = await center.pendingNotificationIdentifiers()
        let ownedPrefixes = Self.ownedPrefixes(namespacePlans: namespacePlans)
        let ownedIDs = pending.filter { identifier in
            ownedPrefixes.contains(where: identifier.hasPrefix)
        }
        if !ownedIDs.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: ownedIDs)
        }

        guard let expectedBinding,
              exactWorkspaceBinding() == expectedBinding,
              permissionState == .authorized
        else {
            if exactWorkspaceBinding() != expectedBinding { needsResynchronization = true }
            return
        }

        let otherCount = pending.count - ownedIDs.count
        let available = max(0, Self.maximumScheduledCount - otherCount)
        for item in notificationItems(now: now).prefix(available) {
            guard exactWorkspaceBinding() == expectedBinding else {
                needsResynchronization = true
                return
            }
            let seconds = floor(item.fireDate.timeIntervalSince(now))
            guard seconds > 0 else { continue }
            do {
                switch item.route.namespace {
                case .invoiceReminder, .recurringInvoice:
                    try await center.scheduleInvoiceItem(item, secondsFromNow: seconds)
                default:
                    try await center.schedule(item, secondsFromNow: seconds)
                }
            } catch {
                if exactWorkspaceBinding() != expectedBinding {
                    needsResynchronization = true
                    return
                }
                continue
            }
            guard exactWorkspaceBinding() == expectedBinding else {
                center.removePendingNotificationRequests(withIdentifiers: [item.identifier])
                needsResynchronization = true
                return
            }
        }
    }
}

/// Generalized alias for the owner-bound namespace-safe coordinator.
///
/// Batch 1/2 integration (feature wiring is a later batch; the shared
/// instance in `TradeReadyNativeApp.swift` stays `est_`-only until then):
/// - Construct with `namespacePlans: [.appointment]` (Batch 1) and add
///   `.review` (Batch 2), each entry's `items` closure calling the batch's
///   pure selector.
/// - Pass `openOwnedRoute` to route `appt_`/`review_` taps into the store
///   (gated on the exact workspace binding, like `requestEstimateFollowUpReview`).
/// - Extend `estimateFollowUpNotificationScheduleKey` with the new plans'
///   inputs so schedule changes re-trigger `synchronize()`.
typealias NativeNotificationCoordinator = NativeEstimateFollowUpNotificationCoordinator
