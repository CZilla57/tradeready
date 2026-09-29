import Foundation
import UserNotifications

private var failures = 0

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        failures += 1
        fputs("FAIL: \(message)\n", stderr)
    }
}

@MainActor
private final class FakeNotificationCenter: NativeEstimateFollowUpNotificationCenter {
    var permission: NativeNotificationPermissionState = .authorized
    var pendingIdentifiers: [String] = []
    var scheduled: [NativeEstimateFollowUpNotification] = []
    var scheduledDelays: [TimeInterval] = []
    var removals: [[String]] = []
    var requestCount = 0
    var delegateInstalled = false
    var authorizationRequestFails = false
    var failedScheduleIDs: Set<String> = []
    var onSchedule: ((NativeEstimateFollowUpNotification) -> Void)?

    func install(delegate: any UNUserNotificationCenterDelegate) {
        delegateInstalled = true
    }

    func authorizationState() async -> NativeNotificationPermissionState {
        permission
    }

    func requestAuthorization() async throws {
        requestCount += 1
        if authorizationRequestFails { throw TestError.authorization }
        permission = .authorized
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
        if failedScheduleIDs.contains(notification.identifier) { throw TestError.schedule }
        scheduled.append(notification)
        scheduledDelays.append(secondsFromNow)
        pendingIdentifiers.append(notification.identifier)
        onSchedule?(notification)
        await Task.yield()
    }

    private enum TestError: Error {
        case authorization
        case schedule
    }
}

private func plan(_ id: String, now: Date, offset: TimeInterval = 120) -> NativeEstimateFollowUpNotification {
    .init(
        identifier: "est_\(id)",
        jobID: id,
        title: "Estimate follow-up — Customer",
        body: "Tap to follow up.",
        fireDate: now.addingTimeInterval(offset)
    )
}

@main
@MainActor
enum EstimateFollowUpNotificationTests {
    static func main() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        do {
            let center = FakeNotificationCenter()
            center.pendingIdentifiers = (0..<59).map { "other_\($0)" } + ["est_old"]
            var binding: String? = "owner-a"
            let coordinator = NativeEstimateFollowUpNotificationCoordinator(
                center: center,
                exactWorkspaceBinding: { binding },
                notificationPlan: { date in [plan("soon", now: date), plan("later", now: date)] },
                openFollowUp: { _ in }
            )

            await coordinator.synchronize(now: now)
            expect(center.delegateInstalled, "the coordinator installs the notification response delegate")
            expect(center.removals.first == ["est_old"], "a sweep replaces only its existing est_ namespace")
            expect(center.scheduled.map(\.jobID) == ["soon"], "non-est requests retain priority under the shared 60-request cap")
            expect(center.scheduledDelays == [120], "the OS adapter receives the exact future delay")
            expect(coordinator.permissionState == .authorized, "a sweep publishes the current permission state")
            binding = nil
        }

        do {
            let center = FakeNotificationCenter()
            center.pendingIdentifiers = ["appt_keep", "est_remove"]
            var planCalls = 0
            let coordinator = NativeEstimateFollowUpNotificationCoordinator(
                center: center,
                exactWorkspaceBinding: { nil },
                notificationPlan: { date in
                    planCalls += 1
                    return [plan("private", now: date)]
                },
                openFollowUp: { _ in }
            )

            await coordinator.synchronize(now: now)
            expect(center.removals == [["est_remove"]], "signed-out synchronization cancels stale estimate reminders")
            expect(center.pendingIdentifiers == ["appt_keep"], "signed-out cleanup leaves other notification families untouched")
            expect(center.scheduled.isEmpty && planCalls == 0, "no customer-visible plan is derived without an exact workspace")
        }

        do {
            let center = FakeNotificationCenter()
            center.permission = .denied
            center.pendingIdentifiers = ["est_remove"]
            let coordinator = NativeEstimateFollowUpNotificationCoordinator(
                center: center,
                exactWorkspaceBinding: { "owner-a" },
                notificationPlan: { date in [plan("blocked", now: date)] },
                openFollowUp: { _ in }
            )

            await coordinator.synchronize(now: now)
            expect(center.scheduled.isEmpty, "denied permission prevents scheduling")
            expect(center.removals == [["est_remove"]], "denied permission still clears obsolete est_ requests")
            expect(coordinator.permissionState == .denied, "denied permission is exposed to Settings")
        }

        do {
            let signedOutCenter = FakeNotificationCenter()
            signedOutCenter.permission = .notRequested
            let signedOut = NativeEstimateFollowUpNotificationCoordinator(
                center: signedOutCenter,
                exactWorkspaceBinding: { nil },
                notificationPlan: { _ in [] },
                openFollowUp: { _ in }
            )
            let signedOutGranted = await signedOut.requestAuthorization()
            expect(!signedOutGranted && signedOutCenter.requestCount == 0, "signed-out state cannot trigger the system permission prompt")

            let activeCenter = FakeNotificationCenter()
            activeCenter.permission = .notRequested
            let active = NativeEstimateFollowUpNotificationCoordinator(
                center: activeCenter,
                exactWorkspaceBinding: { "owner-a" },
                notificationPlan: { _ in [] },
                openFollowUp: { _ in }
            )
            let activeGranted = await active.requestAuthorization()
            expect(activeGranted && activeCenter.requestCount == 1, "an exact signed-in workspace may request notification permission")
        }

        do {
            let center = FakeNotificationCenter()
            center.failedScheduleIDs = ["est_first"]
            let coordinator = NativeEstimateFollowUpNotificationCoordinator(
                center: center,
                exactWorkspaceBinding: { "owner-a" },
                notificationPlan: { date in [plan("first", now: date), plan("second", now: date)] },
                openFollowUp: { _ in }
            )

            await coordinator.synchronize(now: now)
            expect(center.scheduled.map(\.jobID) == ["second"], "one OS scheduling failure does not discard later eligible reminders")
        }

        do {
            let center = FakeNotificationCenter()
            var binding: String? = "owner-a"
            var changedBinding = false
            center.onSchedule = { _ in
                guard !changedBinding else { return }
                changedBinding = true
                binding = nil
            }
            let coordinator = NativeEstimateFollowUpNotificationCoordinator(
                center: center,
                exactWorkspaceBinding: { binding },
                notificationPlan: { date in [plan("first", now: date), plan("second", now: date)] },
                openFollowUp: { _ in }
            )

            await coordinator.synchronize(now: now)
            expect(center.scheduled.map(\.jobID) == ["first"], "an account transition stops the old owner's plan at the first suspension point")
            expect(!center.pendingIdentifiers.contains("est_first"), "a request added during an account transition is immediately removed")
            expect(center.removals.contains(["est_first"]), "account-bound cleanup is explicit and deterministic")
        }

        if failures == 0 {
            print("PASS: native estimate follow-up notification coordinator tests")
        } else {
            exit(1)
        }
    }
}
