import Foundation
import UserNotifications

// Task 10.05 (N1): host tests proving —
//  1. Categories register exactly once per launch (via `registerCategoriesIfNeeded()`),
//     one category per family, no destructive/customer-sending actions.
//  2. The contextual invoice-reminder prompt fires at most once and only when
//     authorization is `.notRequested` (RN's "undetermined").
//  3. The flag is stamped BEFORE the prompt/request, so a dismissed/undecided
//     prompt never repeats.
//  4. A grant triggers exactly one `synchronize()`.
//  5. Sign-out (simulated: the reminder-prompt flag store is cleared) lets the
//     prompt fire again for the next owner.
//
// Device permission dialogs and "survives relaunch" are Phase 12 evidence —
// not claimed here. This runner only proves the coordinator's decision logic
// against an injected fake center.

private var failures = 0

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        failures += 1
        fputs("FAIL: \(message)\n", stderr)
    }
}

@MainActor
private final class FakeNotificationCenter: NativeEstimateFollowUpNotificationCenter {
    var permission: NativeNotificationPermissionState
    var pendingIdentifiers: [String] = []
    var scheduled: [String] = []
    var removals: [[String]] = []
    var delegateInstalled = false
    var requestAuthorizationCallCount = 0
    var registerCategoriesCallCount = 0
    var lastRegisteredCategories: Set<UNNotificationCategory> = []
    /// What `requestAuthorization()` resolves the OS status to. Mirrors the
    /// real system center: after a request the status becomes settled either
    /// way, never staying `.notRequested`.
    var requestOutcome: NativeNotificationPermissionState = .authorized

    init(permission: NativeNotificationPermissionState) {
        self.permission = permission
    }

    func install(delegate: any UNUserNotificationCenterDelegate) {
        delegateInstalled = true
    }

    func authorizationState() async -> NativeNotificationPermissionState {
        permission
    }

    func requestAuthorization() async throws {
        requestAuthorizationCallCount += 1
        permission = requestOutcome
    }

    func pendingNotificationIdentifiers() async -> [String] {
        pendingIdentifiers
    }

    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
        removals.append(identifiers)
        let removed = Set(identifiers)
        pendingIdentifiers.removeAll { removed.contains($0) }
    }

    func schedule(
        _ notification: NativeEstimateFollowUpNotification,
        secondsFromNow: TimeInterval
    ) async throws {
        scheduled.append(notification.identifier)
        pendingIdentifiers.append(notification.identifier)
    }

    func registerCategories(_ categories: Set<UNNotificationCategory>) {
        registerCategoriesCallCount += 1
        lastRegisteredCategories = categories
    }
}

/// In-memory stand-in for `NativeReminderPromptStore`, scoped to one fake
/// "owner" the way the real store is scoped to one account binding. `signOut()`
/// mirrors the AppStore scrub calling `NativeReminderPromptStore.removeAll()`.
@MainActor
private final class FakeReminderPromptFlag {
    private(set) var shown = false
    private(set) var markCallCount = 0

    func wasShown() -> Bool { shown }

    func markShown() {
        markCallCount += 1
        shown = true
    }

    func signOut() {
        shown = false
    }
}

@MainActor
private func makeCoordinator(
    center: FakeNotificationCenter,
    binding: @escaping @MainActor () -> String?,
    flag: FakeReminderPromptFlag
) -> NativeEstimateFollowUpNotificationCoordinator {
    NativeEstimateFollowUpNotificationCoordinator(
        center: center,
        exactWorkspaceBinding: binding,
        notificationPlan: { _ in [] },
        namespacePlans: [],
        openFollowUp: { _ in },
        openOwnedRoute: nil,
        wasReminderPromptShown: { flag.wasShown() },
        markReminderPromptShown: { flag.markShown() }
    )
}

@main
@MainActor
enum NotificationPermissionTests {
    static func main() async {
        // 1. Categories: exactly one per family, keyed to the routes' payload
        // types, and every action is a non-destructive "View" (never a
        // destructive or customer-sending action).
        do {
            let categories = NativeNotificationCategories.makeAll()
            expect(categories.count == 5, "one category per family (5 namespaces)")
            let ids = Set(categories.map(\.identifier))
            expect(
                ids == Set(NativeNotificationNamespace.allCases.map(\.payloadType)),
                "category identifiers are keyed to the namespaces' payload types"
            )
            for category in categories {
                expect(category.actions.count == 1, "\(category.identifier) exposes exactly one action")
                for action in category.actions {
                    expect(
                        !action.options.contains(.destructive),
                        "\(category.identifier)'s \(action.identifier) action is not destructive"
                    )
                }
            }
        }

        // 2. Categories register exactly once per launch: the coordinator is
        // constructed once at app launch (TradeReadyNativeApp.init calls
        // registerCategoriesIfNeeded() a single time); a second call — e.g.
        // from a defensive re-invocation — must not re-register.
        do {
            let center = FakeNotificationCenter(permission: .notRequested)
            let flag = FakeReminderPromptFlag()
            let coordinator = makeCoordinator(center: center, binding: { "owner-a" }, flag: flag)
            expect(center.registerCategoriesCallCount == 0, "no registration before it is requested")
            coordinator.registerCategoriesIfNeeded()
            expect(center.registerCategoriesCallCount == 1, "first call registers once")
            expect(center.lastRegisteredCategories.count == 5, "registers all five categories")
            coordinator.registerCategoriesIfNeeded()
            coordinator.registerCategoriesIfNeeded()
            expect(center.registerCategoriesCallCount == 1, "later calls in the same launch are no-ops")
        }

        // 3. No exact signed-in workspace: no read, no stamp, no request.
        do {
            let center = FakeNotificationCenter(permission: .notRequested)
            let flag = FakeReminderPromptFlag()
            let coordinator = makeCoordinator(center: center, binding: { nil }, flag: flag)
            let outcome = await coordinator.promptForInvoiceRemindersIfNeeded()
            expect(outcome == .noWorkspace, "no workspace yields .noWorkspace")
            expect(flag.markCallCount == 0, "no workspace never stamps the flag")
            expect(center.requestAuthorizationCallCount == 0, "no workspace never requests authorization")
        }

        // 4. Already shown: silent, no re-read of OS status side effects beyond
        // the guard, no re-stamp, no request.
        do {
            let center = FakeNotificationCenter(permission: .notRequested)
            let flag = FakeReminderPromptFlag()
            flag.markShown() // pre-existing "already asked" state
            let markCountBefore = flag.markCallCount
            let coordinator = makeCoordinator(center: center, binding: { "owner-a" }, flag: flag)
            let outcome = await coordinator.promptForInvoiceRemindersIfNeeded()
            expect(outcome == .alreadyShown, "an existing flag yields .alreadyShown")
            expect(flag.markCallCount == markCountBefore, "already-shown never re-stamps")
            expect(center.requestAuthorizationCallCount == 0, "already-shown never requests authorization")
        }

        // 5. OS permission already settled (authorized): the flag is stamped
        // (so it never asks again), but no request is made — silent, matching
        // RN's "silent when the OS status is already settled".
        do {
            let center = FakeNotificationCenter(permission: .authorized)
            let flag = FakeReminderPromptFlag()
            let coordinator = makeCoordinator(center: center, binding: { "owner-a" }, flag: flag)
            let outcome = await coordinator.promptForInvoiceRemindersIfNeeded()
            expect(outcome == .permissionAlreadySettled, "authorized status yields .permissionAlreadySettled")
            expect(flag.markCallCount == 1, "settled status still stamps the flag exactly once")
            expect(center.requestAuthorizationCallCount == 0, "settled status never requests authorization")
        }

        // 5b. Same, but denied.
        do {
            let center = FakeNotificationCenter(permission: .denied)
            let flag = FakeReminderPromptFlag()
            let coordinator = makeCoordinator(center: center, binding: { "owner-a" }, flag: flag)
            let outcome = await coordinator.promptForInvoiceRemindersIfNeeded()
            expect(outcome == .permissionAlreadySettled, "denied status yields .permissionAlreadySettled")
            expect(flag.markCallCount == 1, "denied status still stamps the flag exactly once")
            expect(center.requestAuthorizationCallCount == 0, "denied status never requests authorization")
        }

        // 6. Undetermined + grant: the flag is stamped BEFORE the request (we
        // assert ordering by checking the mark happened even though we then
        // simulate a grant), exactly one request fires, and the grant
        // triggers exactly one synchronize (observed as exactly one
        // schedule() call from the injected plan item).
        do {
            let center = FakeNotificationCenter(permission: .notRequested)
            center.requestOutcome = .authorized
            let flag = FakeReminderPromptFlag()
            var stampedBeforeRequest = false
            let coordinator = NativeEstimateFollowUpNotificationCoordinator(
                center: center,
                exactWorkspaceBinding: { "owner-a" },
                notificationPlan: { now in
                    [.init(
                        identifier: "est_j1",
                        jobID: "j1",
                        title: "t",
                        body: "b",
                        fireDate: now.addingTimeInterval(3600)
                    )]
                },
                namespacePlans: [],
                openFollowUp: { _ in },
                openOwnedRoute: nil,
                wasReminderPromptShown: { flag.wasShown() },
                markReminderPromptShown: {
                    // Captured at the moment of stamping: the OS request has
                    // not fired yet (count is still 0).
                    stampedBeforeRequest = center.requestAuthorizationCallCount == 0
                    flag.markShown()
                }
            )
            let outcome = await coordinator.promptForInvoiceRemindersIfNeeded()
            expect(outcome == .requested(granted: true), "undetermined + grant yields .requested(granted: true)")
            expect(stampedBeforeRequest, "the flag is stamped before the authorization request")
            expect(flag.markCallCount == 1, "stamped exactly once")
            expect(center.requestAuthorizationCallCount == 1, "requests authorization exactly once")
            expect(center.scheduled == ["est_j1"], "a grant triggers exactly one synchronize (one schedule pass)")
        }

        // 7. Undetermined + refusal: request fires, but no synchronize (no
        // schedule call), and the flag is still stamped so it never re-asks.
        do {
            let center = FakeNotificationCenter(permission: .notRequested)
            center.requestOutcome = .denied
            let flag = FakeReminderPromptFlag()
            let coordinator = NativeEstimateFollowUpNotificationCoordinator(
                center: center,
                exactWorkspaceBinding: { "owner-a" },
                notificationPlan: { now in
                    [.init(identifier: "est_j1", jobID: "j1", title: "t", body: "b", fireDate: now.addingTimeInterval(3600))]
                },
                namespacePlans: [],
                openFollowUp: { _ in },
                openOwnedRoute: nil,
                wasReminderPromptShown: { flag.wasShown() },
                markReminderPromptShown: { flag.markShown() }
            )
            let outcome = await coordinator.promptForInvoiceRemindersIfNeeded()
            expect(outcome == .requested(granted: false), "undetermined + refusal yields .requested(granted: false)")
            expect(flag.markCallCount == 1, "still stamped exactly once on refusal")
            expect(center.requestAuthorizationCallCount == 1, "requests authorization exactly once")
            expect(center.scheduled.isEmpty, "a refusal never synchronizes")
        }

        // 8. Ask-at-most-once across repeated calls (e.g. two invoices created
        // in the same session): only the first call ever requests.
        do {
            let center = FakeNotificationCenter(permission: .notRequested)
            center.requestOutcome = .denied
            let flag = FakeReminderPromptFlag()
            let coordinator = makeCoordinator(center: center, binding: { "owner-a" }, flag: flag)
            _ = await coordinator.promptForInvoiceRemindersIfNeeded()
            _ = await coordinator.promptForInvoiceRemindersIfNeeded()
            _ = await coordinator.promptForInvoiceRemindersIfNeeded()
            expect(center.requestAuthorizationCallCount == 1, "only the first call ever requests authorization")
            expect(flag.markCallCount == 1, "only the first call ever stamps the flag")
        }

        // 9. Sign-out clears the flag: after a simulated scrub, the next owner
        // can be asked again (mirrors NativeReminderPromptStore.removeAll()
        // being called from AppStore's account-boundary scrub).
        do {
            let center = FakeNotificationCenter(permission: .authorized)
            let flag = FakeReminderPromptFlag()
            flag.markShown()
            let coordinatorBefore = makeCoordinator(center: center, binding: { "owner-a" }, flag: flag)
            let beforeSignOut = await coordinatorBefore.promptForInvoiceRemindersIfNeeded()
            expect(beforeSignOut == .alreadyShown, "flag still set before sign-out")

            flag.signOut()
            let markCountBeforeNextOwner = flag.markCallCount
            let coordinatorAfter = makeCoordinator(center: center, binding: { "owner-b" }, flag: flag)
            let afterSignOut = await coordinatorAfter.promptForInvoiceRemindersIfNeeded()
            expect(afterSignOut != .alreadyShown, "sign-out clears the flag for the next owner")
            expect(
                flag.markCallCount == markCountBeforeNextOwner + 1,
                "the next owner's settled status stamps its own flag exactly once"
            )
        }

        if failures == 0 {
            print("PASS: native notification permission/category tests")
        } else {
            exit(1)
        }
    }
}
