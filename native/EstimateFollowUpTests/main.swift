import Foundation

private var failures = 0

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        failures += 1
        fputs("FAIL: \(message)\n", stderr)
    }
}

private func phoenixCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.locale = Locale(identifier: "en_US_POSIX")
    calendar.timeZone = TimeZone(identifier: "America/Phoenix")!
    return calendar
}

private func localDate(
    _ year: Int,
    _ month: Int,
    _ day: Int,
    _ hour: Int = 0,
    _ minute: Int = 0
) -> Date {
    phoenixCalendar().date(
        from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)
    )!
}

private func makeJob(
    id: String = "j1",
    status: String = "estimate_sent",
    estimateSentAt: String? = nil,
    approvalSentAt: String? = nil,
    title: String = "Water heater swap",
    total: String = "850"
) throws -> Canonical.Job {
    let approval = approvalSentAt.map {
        """
        ,"approval":{"token":"token","sentAt":"\($0)","snapshot":{"businessName":"Dave Plumbing","customerName":"Dave Smith","jobTitle":"\(title)","lineItems":[],"total":\(total),"currency":"USD"}}
        """
    } ?? ""
    let sent = estimateSentAt.map { ",\"estimateSentAt\":\"\($0)\"" } ?? ""
    let json = """
    {"id":"\(id)","customerId":"c1","customerName":"Dave Smith","title":"\(title)","description":"","status":"\(status)","scheduledDate":null,"scheduledStartTime":null,"scheduledEndTime":null,"address":"","estimateTotal":\(total),"laborHours":3,"laborRate":85,"materials":[],"materialMarkup":20,"overhead":15,"margin":20,"notes":"","invoiceId":null,"createdAt":"2026-07-01"\(sent)\(approval)}
    """
    return try JSONDecoder().decode(Canonical.Job.self, from: Data(json.utf8))
}

@main
enum EstimateFollowUpTests {
    static func main() throws {
        let calendar = phoenixCalendar()

        let preferred = try makeJob(
            estimateSentAt: "2026-08-01",
            approvalSentAt: "2026-07-20T14:00:00.000Z"
        )
        expect(
            NativeEstimateFollowUp.sentDate(for: preferred, calendar: calendar) == localDate(2026, 8, 1),
            "local estimateSentAt takes precedence over approval.sentAt"
        )

        let fallback = try makeJob(approvalSentAt: "2026-07-20T14:00:00.000Z")
        expect(
            NativeEstimateFollowUp.sentDate(for: fallback, calendar: calendar)
                == ISO8601DateFormatter().date(from: "2026-07-20T14:00:00Z"),
            "approval.sentAt is the legacy fallback"
        )
        let malformedNewest = try makeJob(
            estimateSentAt: "garbage",
            approvalSentAt: "2026-07-20T14:00:00Z"
        )
        expect(
            NativeEstimateFollowUp.sentDate(for: malformedNewest, calendar: calendar) == nil,
            "a malformed newest stamp fails closed instead of reviving an older approval date"
        )
        let invalidLocalDate = try makeJob(estimateSentAt: "2026-02-30")
        expect(
            NativeEstimateFollowUp.sentDate(for: invalidLocalDate, calendar: calendar) == nil,
            "an invalid local calendar date is rejected"
        )

        let now = localDate(2026, 8, 2, 12)
        let reminderJob = try makeJob(estimateSentAt: "2026-08-01")
        let reminders = NativeEstimateFollowUp.upcomingReminders(
            jobs: [reminderJob], now: now, calendar: calendar
        )
        expect(reminders.count == 1, "a silent estimate with a future fire date is eligible")
        expect(
            reminders.first?.fireDate == localDate(2026, 8, 4, 9),
            "the reminder fires at 9 a.m. local three calendar days after send"
        )
        let answeredJob = try makeJob(status: "approved", estimateSentAt: "2026-08-01")
        expect(
            NativeEstimateFollowUp.upcomingReminders(
                jobs: [answeredJob],
                now: now,
                calendar: calendar
            ).isEmpty,
            "answered estimates are ineligible"
        )
        let expiredJob = try makeJob(estimateSentAt: "2026-07-20")
        expect(
            NativeEstimateFollowUp.upcomingReminders(
                jobs: [expiredJob],
                now: now,
                calendar: calendar
            ).isEmpty,
            "a past fire date cannot recreate the one-shot reminder"
        )

        let ordered = NativeEstimateFollowUp.upcomingReminders(
            jobs: [
                try makeJob(id: "late", estimateSentAt: "2026-08-02"),
                try makeJob(id: "soon-a", estimateSentAt: "2026-08-01"),
                try makeJob(id: "soon-b", estimateSentAt: "2026-08-01")
            ],
            now: now,
            calendar: calendar
        )
        expect(
            ordered.map(\.jobID) == ["soon-a", "soon-b", "late"],
            "reminders are soonest-first and retain source order for ties"
        )

        let notificationPlan = NativeEstimateFollowUp.notificationPlan(
            jobs: [reminderJob], now: now, enabled: true, calendar: calendar
        )
        expect(
            notificationPlan == [
                .init(
                    identifier: "est_j1",
                    jobID: "j1",
                    title: "Estimate follow-up — Dave Smith",
                    body: "Estimate for \"Water heater swap\" sent 3 days ago with no response. Tap to follow up.",
                    fireDate: localDate(2026, 8, 4, 9)
                )
            ],
            "notification identifiers and visible copy match the React Native contract"
        )
        expect(
            NativeEstimateFollowUp.notificationPlan(
                jobs: [reminderJob], now: now, enabled: false, calendar: calendar
            ).isEmpty,
            "the settings toggle suppresses every estimate notification"
        )
        let cappedJobs = [
            try makeJob(id: "first", estimateSentAt: "2026-08-01"),
            try makeJob(id: "second", estimateSentAt: "2026-08-02")
        ]
        expect(
            NativeEstimateFollowUp.notificationPlan(
                jobs: cappedJobs,
                now: now,
                enabled: true,
                maximumCount: 1,
                calendar: calendar
            ).map(\.jobID) == ["first"],
            "the notification plan preserves soonest-first priority under the shared cap"
        )

        let dayThreeBeforeNine = localDate(2026, 8, 4, 8)
        expect(
            NativeEstimateFollowUp.awaitingResponse(
                jobs: [reminderJob], now: dayThreeBeforeNine, calendar: calendar
            ).count == 1,
            "the Today row becomes eligible at the exact three-day duration"
        )
        expect(
            NativeEstimateFollowUp.upcomingReminders(
                jobs: [reminderJob], now: dayThreeBeforeNine, calendar: calendar
            ).count == 1,
            "day three before 9 a.m. intentionally overlaps both selectors"
        )
        let youngJob = try makeJob(estimateSentAt: "2026-08-02")
        expect(
            NativeEstimateFollowUp.awaitingResponse(
                jobs: [youngJob],
                now: dayThreeBeforeNine,
                calendar: calendar
            ).isEmpty,
            "younger estimates are absent from the Today row"
        )

        expect(
            NativeEstimateFollowUp.awaitingResponseLabel(count: 1) == "1 estimate awaiting response"
                && NativeEstimateFollowUp.awaitingResponseLabel(count: 3) == "3 estimates awaiting response",
            "awaiting-response copy pluralizes deterministically"
        )

        let quoted = try makeJob(title: "Panel upgrade", total: "2499.5")
        let message = NativeEstimateFollowUp.message(job: quoted, customerFirstName: "Dave")
        expect(
            message == "Hi Dave, just checking in on the estimate I sent over for Panel upgrade ($2,499.50). Happy to answer any questions — want me to get you on the schedule?",
            "message content and quote formatting match the React Native oracle"
        )
        expect(
            message == NativeEstimateFollowUp.message(job: quoted, customerFirstName: "Dave"),
            "message generation is deterministic and side-effect free"
        )
        let draft = NativeEstimateFollowUp.draft(
            job: quoted,
            customerName: "  Dave Smith  ",
            customerPhone: " 555-0100 ",
            customerEmail: " dave@example.test ",
            businessName: "Rector Plumbing",
            calendar: calendar
        )
        expect(
            draft?.customerName == "Dave Smith"
                && draft?.customerPhone == "555-0100"
                && draft?.customerEmail == "dave@example.test"
                && draft?.emailSubject == "Checking in on your estimate — Rector Plumbing"
                && draft?.body == message,
            "the reviewed composer draft uses live trimmed contact details and deterministic copy"
        )
        let decidedDraft = NativeEstimateFollowUp.draft(
            job: answeredJob,
            customerName: "Dave Smith",
            customerPhone: "555-0100",
            customerEmail: "",
            businessName: "Rector Plumbing",
            calendar: calendar
        )
        expect(decidedDraft == nil, "an answered estimate cannot open a stale follow-up draft")
        expect(
            NativeEstimateFollowUp.canOpenNotification(
                exactOwnerWorkspace: true,
                signedIn: true,
                job: reminderJob
            ),
            "a notification can open only for the exact signed-in owner and still-open estimate"
        )
        expect(
            !NativeEstimateFollowUp.canOpenNotification(
                exactOwnerWorkspace: false,
                signedIn: true,
                job: reminderJob
            ) && !NativeEstimateFollowUp.canOpenNotification(
                exactOwnerWorkspace: true,
                signedIn: false,
                job: reminderJob
            ) && !NativeEstimateFollowUp.canOpenNotification(
                exactOwnerWorkspace: true,
                signedIn: true,
                job: answeredJob
            ),
            "owner mismatch, signed-out state, and answered estimates all fail closed"
        )
        // Task 11.06 (P8, contract C11 resolved): an archived estimate_sent job
        // is still scheduled for `est_` (no archive filter, like RN), so its
        // delivered notification opens: never a dead tap.
        var archivedJob = reminderJob
        archivedJob.archivedAt = "2026-08-02T10:00:00.000Z"
        expect(
            NativeEstimateFollowUp.upcomingReminders(jobs: [archivedJob], now: now, calendar: calendar).count == 1,
            "sanity: an archived estimate_sent job still gets an est_ reminder"
        )
        expect(
            NativeEstimateFollowUp.canOpenNotification(
                exactOwnerWorkspace: true,
                signedIn: true,
                job: archivedJob
            ),
            "P8: the archived estimate's delivered est_ notification opens (no dead tap)"
        )
        expect(
            !NativeEstimateFollowUp.canOpenNotification(
                exactOwnerWorkspace: false,
                signedIn: true,
                job: archivedJob
            ) && !NativeEstimateFollowUp.canOpenNotification(
                exactOwnerWorkspace: true,
                signedIn: true,
                job: nil
            ),
            "P8 keeps the owner gate and a missing job still fails closed"
        )
        expect(
            NativeEstimateFollowUp.notificationJobID(userInfo: [
                "type": "estimate_follow_up",
                "jobId": "  j1  "
            ]) == "j1",
            "the notification route accepts only a trimmed estimate-follow-up job ID"
        )
        expect(
            NativeEstimateFollowUp.notificationJobID(userInfo: [
                "type": "appointment_confirm",
                "jobId": "j1"
            ]) == nil
                && NativeEstimateFollowUp.notificationJobID(userInfo: [
                    "type": "estimate_follow_up",
                    "jobId": String(repeating: "x", count: 257)
                ]) == nil,
            "wrong-family and oversized notification routes fail closed"
        )
        expect(NativeEstimateFollowUp.followUpDays == 3, "the follow-up interval remains one shared constant")

        if failures == 0 {
            print("PASS: native estimate follow-up eligibility and message tests")
        } else {
            exit(1)
        }
    }
}
