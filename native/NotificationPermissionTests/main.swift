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

        // 6. Undetermined: the flag is stamped BEFORE anything else (we assert
        // ordering by checking the mark happened before any OS request could
        // have fired), the outcome is `.pendingUserChoice`, and — crucially —
        // NO OS permission request fires yet: the soft-ask alert is only
        // published as pending, awaiting "Not now"/"Turn on".
        do {
            let center = FakeNotificationCenter(permission: .notRequested)
            center.requestOutcome = .authorized
            let flag = FakeReminderPromptFlag()
            var stampedBeforeAnyRequest = false
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
                    stampedBeforeAnyRequest = center.requestAuthorizationCallCount == 0
                    flag.markShown()
                }
            )
            expect(!coordinator.pendingInvoiceReminderPrompt, "no pending alert before the call")
            let outcome = await coordinator.promptForInvoiceRemindersIfNeeded()
            expect(outcome == .pendingUserChoice, "undetermined status yields .pendingUserChoice")
            expect(stampedBeforeAnyRequest, "the flag is stamped before any OS request")
            expect(flag.markCallCount == 1, "stamped exactly once")
            expect(
                center.requestAuthorizationCallCount == 0,
                "no OS permission request fires until \"Turn on\" is chosen"
            )
            expect(coordinator.pendingInvoiceReminderPrompt, "the soft-ask is now pending")

            // "Turn on": the coordinator's request path runs, and a grant
            // triggers exactly one synchronize (observed as exactly one
            // schedule() call from the injected plan item).
            let granted = await coordinator.confirmInvoiceReminderPrompt()
            expect(granted, "requestOutcome .authorized reports as granted")
            expect(!coordinator.pendingInvoiceReminderPrompt, "\"Turn on\" clears the pending alert")
            expect(center.requestAuthorizationCallCount == 1, "\"Turn on\" requests authorization exactly once")
            expect(center.scheduled == ["est_j1"], "a grant triggers exactly one synchronize (one schedule pass)")
        }

        // 7. Undetermined + "Not now": no OS request is ever made, the pending
        // alert clears, and the flag is still stamped so it never re-asks.
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
            expect(outcome == .pendingUserChoice, "undetermined status yields .pendingUserChoice")
            expect(flag.markCallCount == 1, "still stamped exactly once")

            coordinator.dismissInvoiceReminderPrompt()
            expect(!coordinator.pendingInvoiceReminderPrompt, "\"Not now\" clears the pending alert")
            expect(center.requestAuthorizationCallCount == 0, "\"Not now\" never requests authorization")
            expect(center.scheduled.isEmpty, "\"Not now\" never synchronizes")
        }

        // 8. Ask-at-most-once across repeated calls (e.g. two invoices created
        // in the same session): only the first call ever stamps/pends, and a
        // second ask never happens even if the first is never resolved.
        do {
            let center = FakeNotificationCenter(permission: .notRequested)
            center.requestOutcome = .denied
            let flag = FakeReminderPromptFlag()
            let coordinator = makeCoordinator(center: center, binding: { "owner-a" }, flag: flag)
            let first = await coordinator.promptForInvoiceRemindersIfNeeded()
            let second = await coordinator.promptForInvoiceRemindersIfNeeded()
            let third = await coordinator.promptForInvoiceRemindersIfNeeded()
            expect(first == .pendingUserChoice, "the first call pends the soft-ask")
            expect(second == .alreadyShown, "a second call while pending is already-shown, never a second ask")
            expect(third == .alreadyShown, "a third call is also already-shown")
            expect(center.requestAuthorizationCallCount == 0, "no call ever requests authorization on its own")
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

        // 10. Sign-out dismisses a PENDING soft-ask: if owner-a has a pending
        // alert when the account switches, `synchronize()` (as driven by
        // TradeReadyNativeApp's `.task(id: store.estimateFollowUpNotificationScheduleKey)`,
        // which re-fires on every account change) must clear it — the user
        // must never see "Turn on"/"Not now" for an account they've left.
        do {
            let center = FakeNotificationCenter(permission: .notRequested)
            let flag = FakeReminderPromptFlag()
            var currentBinding: String? = "owner-a"
            let coordinator = makeCoordinator(center: center, binding: { currentBinding }, flag: flag)
            let outcome = await coordinator.promptForInvoiceRemindersIfNeeded()
            expect(outcome == .pendingUserChoice, "owner-a has a pending soft-ask")
            expect(coordinator.pendingInvoiceReminderPrompt, "the pending alert is showing")

            currentBinding = "owner-b"
            await coordinator.synchronize()
            expect(
                !coordinator.pendingInvoiceReminderPrompt,
                "an account-binding change during synchronize() dismisses the stale pending alert"
            )
        }

        // 11. Minor #1 fail-safe default: a coordinator constructed WITHOUT
        // injecting `wasReminderPromptShown`/`markReminderPromptShown` (as a
        // legacy call site or an unrelated test would) must never prompt —
        // the default must be fail-safe ("treat as already shown"), not the
        // unsafe old default of "never shown" which could re-request
        // indefinitely.
        do {
            let center = FakeNotificationCenter(permission: .notRequested)
            let coordinator = NativeEstimateFollowUpNotificationCoordinator(
                center: center,
                exactWorkspaceBinding: { "owner-a" },
                notificationPlan: { _ in [] },
                namespacePlans: [],
                openFollowUp: { _ in },
                openOwnedRoute: nil
            )
            let outcome = await coordinator.promptForInvoiceRemindersIfNeeded()
            expect(outcome == .alreadyShown, "the fail-safe default never prompts when no store is injected")
            expect(!coordinator.pendingInvoiceReminderPrompt, "no pending alert is ever raised")
            expect(center.requestAuthorizationCallCount == 0, "no OS request is ever made")
        }

        if failures == 0 {
            print("PASS: native notification permission/category tests")
        } else {
            exit(1)
        }
    }
}
