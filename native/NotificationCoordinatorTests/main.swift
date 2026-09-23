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
    var delegateInstalled = false
    var onSchedule: ((NativeEstimateFollowUpNotification) -> Void)?

    func install(delegate: any UNUserNotificationCenterDelegate) {
        delegateInstalled = true
    }

    func authorizationState() async -> NativeNotificationPermissionState {
        permission
    }

    func requestAuthorization() async throws {
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
        scheduled.append(notification)
        scheduledDelays.append(secondsFromNow)
        pendingIdentifiers.append(notification.identifier)
        onSchedule?(notification)
        await Task.yield()
    }
}

private func estPlan(
    _ id: String,
    now: Date,
    offset: TimeInterval = 120
) -> NativeEstimateFollowUpNotification {
    .init(
        identifier: "est_\(id)",
        jobID: id,
        title: "Estimate follow-up — Customer",
        body: "Tap to follow up.",
        fireDate: now.addingTimeInterval(offset)
    )
}

private func ownedPlan(
    _ route: NativeNotificationRoute,
    now: Date,
    offset: TimeInterval = 120
) -> NativeNotificationPlanItem {
    .init(
        identifier: route.identifier,
        jobID: route.jobID,
        title: "Title \(route.jobID)",
        body: "Tap to open.",
        route: route,
        fireDate: now.addingTimeInterval(offset)
    )
}

@MainActor
private func makeCoordinator(
    center: FakeNotificationCenter,
    binding: @escaping @MainActor () -> String?,
    est: @escaping @MainActor (Date) -> [NativeEstimateFollowUpNotification],
    appt: @escaping @MainActor (Date) -> [NativeNotificationPlanItem],
    review: @escaping @MainActor (Date) -> [NativeNotificationPlanItem],
    routes: (@MainActor (NativeNotificationRoute) -> Void)? = nil,
    invoice: (@MainActor (Date) -> [NativeNotificationPlanItem])? = nil,
    recurring: (@MainActor (Date) -> [NativeNotificationPlanItem])? = nil
) -> NativeEstimateFollowUpNotificationCoordinator {
    var plans: [NativeNotificationNamespacePlan] = [
        .init(namespace: .appointment, items: appt),
        .init(namespace: .review, items: review)
    ]
    if let invoice { plans.append(.init(namespace: .invoiceReminder, items: invoice)) }
    if let recurring { plans.append(.init(namespace: .recurringInvoice, items: recurring)) }
    return NativeEstimateFollowUpNotificationCoordinator(
        center: center,
        exactWorkspaceBinding: binding,
        notificationPlan: est,
        namespacePlans: plans,
        openFollowUp: { _ in },
        openOwnedRoute: routes
    )
}

@main
@MainActor
enum NotificationCoordinatorTests {
    static func main() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        // Foreign families preserved while every owned namespace is managed.
        do {
            let center = FakeNotificationCenter()
            center.pendingIdentifiers = [
                "inv_a", "rinv_b", "other_x",
                "est_old", "appt_old", "review_old"
            ]
            let coordinator = makeCoordinator(
                center: center,
                binding: { "owner-a" },
                est: { date in [estPlan("soon", now: date)] },
                appt: { _ in [] },
                review: { _ in [] }
            )

            await coordinator.synchronize(now: now)
            expect(
                center.removals == [["est_old", "appt_old", "review_old"]],
                "a sweep replaces all three owned namespaces in pending order"
            )
            expect(
                center.pendingIdentifiers.sorted() == ["est_soon", "inv_a", "other_x", "rinv_b"],
                "foreign families survive while the est_ item still schedules"
            )
            expect(
                center.scheduled.map(\.identifier) == ["est_soon"],
                "an empty appointment plan (toggle off) schedules nothing extra"
            )
        }

        // Shared 60-cap with est > appt > review priority.
        do {
            for (foreignCount, expected) in [
                (59, ["est_e"]), (58, ["est_e", "appt_a"]), (57, ["est_e", "appt_a", "review_r"])
            ] as [(Int, [String])] {
                let center = FakeNotificationCenter()
                center.pendingIdentifiers = (0..<foreignCount).map { "other_\($0)" }
                let coordinator = makeCoordinator(
                    center: center,
                    binding: { "owner-a" },
                    est: { date in [estPlan("e", now: date)] },
                    appt: { date in [ownedPlan(.appointmentConfirm(jobID: "a"), now: date)] },
                    review: { date in [ownedPlan(.reviewRequest(jobID: "r"), now: date)] }
                )

                await coordinator.synchronize(now: now)
                expect(
                    center.scheduled.map(\.identifier) == expected,
                    "with \(foreignCount) foreign requests only \(expected) schedule (est first)"
                )
            }
        }

        // Owner switch mid-sync triggers cleanup plus a resync pass.
        do {
            let center = FakeNotificationCenter()
            var binding: String? = "owner-a"
            var estCalls = 0
            var flipped = false
            center.onSchedule = { _ in
                guard !flipped else { return }
                flipped = true
                binding = "owner-b"
            }
            let coordinator = makeCoordinator(
                center: center,
                binding: { binding },
                est: { date in
                    estCalls += 1
                    return [estPlan("first", now: date), estPlan("second", now: date)]
                },
                appt: { _ in [] },
                review: { _ in [] }
            )

            await coordinator.synchronize(now: now)
            expect(
                center.removals.contains(["est_first"]),
                "a request added during an account transition is immediately removed"
            )
            expect(
                estCalls == 2,
                "the binding change triggers a second synchronize pass under the new owner"
            )
            expect(
                center.scheduled.map(\.identifier) == ["est_first", "est_first", "est_second"],
                "the resync pass reschedules under the new binding"
            )
            expect(
                Set(center.pendingIdentifiers) == ["est_first", "est_second"],
                "no stale request survives the owner transition"
            )
        }

        // Denied permission clears only owned namespaces.
        do {
            let center = FakeNotificationCenter()
            center.permission = .denied
            center.pendingIdentifiers = ["est_x", "appt_x", "review_x", "inv_keep"]
            let coordinator = makeCoordinator(
                center: center,
                binding: { "owner-a" },
                est: { date in [estPlan("blocked", now: date)] },
                appt: { date in [ownedPlan(.appointmentConfirm(jobID: "a"), now: date)] },
                review: { date in [ownedPlan(.reviewRequest(jobID: "r"), now: date)] }
            )

            await coordinator.synchronize(now: now)
            expect(center.scheduled.isEmpty, "denied permission prevents all scheduling")
            expect(
                center.removals == [["est_x", "appt_x", "review_x"]],
                "denied permission still clears every owned namespace"
            )
            expect(
                center.pendingIdentifiers == ["inv_keep"],
                "denied-permission cleanup leaves foreign families untouched"
            )
            expect(coordinator.permissionState == .denied, "denied permission is published")
        }

        // Signed-out cleanup clears every owned namespace and derives no plan.
        do {
            let center = FakeNotificationCenter()
            center.pendingIdentifiers = ["est_x", "appt_x", "review_x", "inv_keep"]
            var planCalls = 0
            let coordinator = makeCoordinator(
                center: center,
                binding: { nil },
                est: { _ in planCalls += 1; return [] },
                appt: { _ in planCalls += 1; return [] },
                review: { _ in planCalls += 1; return [] }
            )

            await coordinator.synchronize(now: now)
            expect(
                center.removals == [["est_x", "appt_x", "review_x"]],
                "signed-out synchronization cancels every owned namespace"
            )
            expect(
                center.pendingIdentifiers == ["inv_keep"],
                "signed-out cleanup preserves foreign families"
            )
            expect(
                center.scheduled.isEmpty && planCalls == 0,
                "no plan is derived without an exact workspace"
            )
        }

        // Legacy inits stay est_-only: appt_-prefixed pending is foreign there.
        do {
            let center = FakeNotificationCenter()
            center.pendingIdentifiers = ["appt_keep", "est_remove"]
            let coordinator = NativeEstimateFollowUpNotificationCoordinator(
                center: center,
                exactWorkspaceBinding: { "owner-a" },
                notificationPlan: { _ in [] },
                openFollowUp: { _ in }
            )

            await coordinator.synchronize(now: now)
            expect(
                center.removals == [["est_remove"]],
                "the legacy init manages est_ only"
            )
            expect(
                center.pendingIdentifiers == ["appt_keep"],
                "appt_ stays foreign until Batch 1 injects an appointment planner"
            )
        }

        // Tap routing decodes all three owned types.
        do {
            expect(
                NativeNotificationRoute.decode(userInfo: ["type": "estimate_follow_up", "jobId": "j1"])
                    == .estimateFollowUp(jobID: "j1"),
                "estimate_follow_up decodes"
            )
            expect(
                NativeNotificationRoute.decode(userInfo: ["type": "appointment_confirm", "jobId": "j2"])
                    == .appointmentConfirm(jobID: "j2"),
                "appointment_confirm decodes"
            )
            expect(
                NativeNotificationRoute.decode(userInfo: ["type": "review_request", "jobId": "j3"])
                    == .reviewRequest(jobID: "j3"),
                "review_request decodes"
            )
            expect(
                NativeNotificationRoute.decode(userInfo: ["type": "some_other_type", "jobId": "j9"]) == nil,
                "foreign payload types do not decode"
            )
            expect(
                NativeNotificationRoute.decode(userInfo: ["type": "appointment_confirm", "jobId": "   "]) == nil,
                "blank appointment job IDs do not decode"
            )
            expect(
                NativeNotificationRoute.decode(userInfo: ["type": "review_request"]) == nil,
                "a missing review job ID does not decode"
            )
            expect(
                NativeNotificationRoute.decode(userInfo: ["jobId": "j1"]) == nil,
                "a missing type does not decode"
            )
            expect(
                NativeNotificationRoute.appointmentConfirm(jobID: "j2").identifier == "appt_j2"
                    && NativeNotificationRoute.reviewRequest(jobID: "j3").identifier == "review_j3",
                "route identifiers match the RN appt_/review_ schemes"
            )
            expect(
                NativeNotificationRoute.decode(userInfo: ["type": "overdue_outreach", "invoiceId": "i1", "daysPastDue": 7])
                    == .invoiceReminder(invoiceID: "i1", daysPastDue: 7, opensOutreach: true),
                "overdue_outreach decodes with its invoice payload"
            )
            expect(
                NativeNotificationRoute.decode(userInfo: ["type": "overdue_invoice", "invoiceId": "i2"])
                    == .invoiceReminder(invoiceID: "i2", daysPastDue: 0, opensOutreach: false),
                "plain overdue payloads decode without the outreach flag"
            )
            expect(
                NativeNotificationRoute.decode(userInfo: ["type": "recurring_invoice", "ruleId": "r1"])
                    == .recurringInvoiceReminder(ruleID: "r1"),
                "recurring_invoice decodes with its rule payload"
            )
            expect(
                NativeNotificationRoute.decode(userInfo: ["type": "overdue_outreach"]) == nil,
                "a missing invoice id does not decode"
            )
            expect(
                NativeNotificationRoute.invoiceReminder(invoiceID: "i1", daysPastDue: 7, opensOutreach: true).identifier == "inv_i1_7d"
                    && NativeNotificationRoute.recurringInvoiceReminder(ruleID: "r1").identifier == "rinv_r1",
                "route identifiers match the RN inv_/rinv_ schemes"
            )
        }

        // Invoice namespaces are owned only when injected: cleanup, cap priority, tap routing.
        do {
            let center = FakeNotificationCenter()
            center.pendingIdentifiers = ["inv_old_1d", "rinv_old", "other_x"]
            let coordinator = makeCoordinator(
                center: center,
                binding: { "owner-a" },
                est: { _ in [] },
                appt: { _ in [] },
                review: { _ in [] },
                invoice: { date in [ownedPlan(.invoiceReminder(invoiceID: "i1", daysPastDue: 1, opensOutreach: false), now: date)] },
                recurring: { date in [ownedPlan(.recurringInvoiceReminder(ruleID: "r1"), now: date)] }
            )

            await coordinator.synchronize(now: now)
            expect(
                center.removals == [["inv_old_1d", "rinv_old"]],
                "a sweep replaces the injected inv_/rinv_ namespaces in pending order"
            )
            expect(
                center.pendingIdentifiers.sorted() == ["inv_i1_1d", "other_x", "rinv_r1"],
                "foreign families survive while invoice items schedule"
            )
        }

        // Estimate decode parity with the pre-existing helper (incl. edges).
        do {
            let long = String(repeating: "x", count: 257)
            let cases: [[AnyHashable: Any]] = [
                ["type": "estimate_follow_up", "jobId": "abc"],
                ["type": "estimate_follow_up", "jobId": "  padded  "],
                ["type": "estimate_follow_up", "jobId": ""],
                ["type": "estimate_follow_up", "jobId": "   "],
                ["type": "estimate_follow_up", "jobId": long],
                ["type": "estimate_follow_up"],
                ["type": "estimate_follow_up", "jobId": 42],
                ["type": "ESTIMATE_FOLLOW_UP", "jobId": "abc"]
            ]
            for userInfo in cases {
                let legacy = NativeEstimateFollowUp.notificationJobID(userInfo: userInfo)
                let route = NativeNotificationRoute.decode(userInfo: userInfo)
                switch (legacy, route) {
                case (nil, nil):
                    break
                case let (.some(jobID), .estimateFollowUp(routed)) where jobID == routed:
                    break
                default:
                    expect(false, "estimate decode parity for \(userInfo)")
                }
            }
        }

        if failures == 0 {
            print("PASS: native notification coordinator tests")
        } else {
            exit(1)
        }
    }
}
