import Foundation

// Task 10.07 (N3): parity coverage for NativeAppointmentNotifications against
// utils/appointmentMessages.ts (`selectAppointmentReminders`, `fireDateFor`,
// `resolveChannel`, `ACTIVE_STATUSES`) and __tests__/notifications.test.js
// ("syncNotifications — appointment confirmations"). Never-auto-sends is
// proven by NativeAppointmentConfirmationReviewView (an editable TextEditor
// gated behind an explicit "Continue to Messages/Mail" tap that opens the
// system composer — see native/TradeReadyNative/NativeMessageComposer.swift)
// and by `canOpenNotification` below, which requires the exact current job
// rather than inventing a destination from a stale payload.

private var failures = 0
private func expect(_ value: @autoclosure () -> Bool, _ message: String) {
    if !value() { failures += 1; fputs("FAIL: \(message)\n", stderr) }
}

private func makeJob(
    id: String = "j1",
    customerId: String = "c1",
    status: String = "scheduled",
    scheduledDate: String? = "2026-07-19"
) -> Canonical.Job {
    let dateField = scheduledDate.map { "\"\($0)\"" } ?? "null"
    let json = """
    {"id":"\(id)","customerId":"\(customerId)","customerName":"Alice","title":"Job","description":"",
     "status":"\(status)","scheduledDate":\(dateField),"scheduledStartTime":null,"scheduledEndTime":null,
     "address":"","estimateTotal":0,"laborHours":0,"laborRate":85,"materials":[],"materialMarkup":20,
     "overhead":15,"margin":20,"notes":"","invoiceId":null,"createdAt":"2026-07-01"}
    """
    return try! JSONDecoder().decode(Canonical.Job.self, from: Data(json.utf8))
}

private func makeCustomer(
    id: String = "c1",
    name: String = "Alice",
    phone: String = "5551234567",
    email: String = "a@x.com"
) -> Canonical.Customer {
    let json = """
    {"id":"\(id)","name":"\(name)","email":"\(email)","phone":"\(phone)","address":"12 Oak St","notes":"","createdAt":"2026-01-01"}
    """
    return try! JSONDecoder().decode(Canonical.Customer.self, from: Data(json.utf8))
}

@main
struct AppointmentNotificationTests {
    static func main() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!

        // ── Fire date (RN `fireDateFor`: 5pm local on the day before) ──────
        let fire = NativeAppointmentNotifications.fireDate(for: "2026-07-19", calendar: calendar)
        expect(fire == calendar.date(from: .init(year: 2026, month: 7, day: 18, hour: 17)), "fires at 5pm local on the preceding day")
        expect(NativeAppointmentNotifications.fireDate(for: "2026-02-30", calendar: calendar) == nil, "rejects invalid calendar dates")

        // DST-boundary case, explicit TimeZone: America/Los_Angeles springs
        // forward 2027-03-14 (2:00am -> 3:00am). A job scheduled 2027-03-15
        // fires 5pm local on 2027-03-14 itself — the transition day — and
        // must land at exactly 17:00 local, not 16:00 or 18:00 from a naive
        // fixed-offset shift across the spring-forward.
        let dstFire = NativeAppointmentNotifications.fireDate(for: "2027-03-15", calendar: calendar)
        let expectedDst = calendar.date(from: .init(year: 2027, month: 3, day: 14, hour: 17))
        expect(dstFire == expectedDst, "DST spring-forward: still 5pm local on the transition day")
        if let dstFire {
            let comps = calendar.dateComponents([.year, .month, .day, .hour], from: dstFire)
            expect(comps.year == 2027 && comps.month == 3 && comps.day == 14 && comps.hour == 17,
                   "DST fire date resolves to 2027-03-14 17:00 local, not shifted by the 1h gap")
        }
        // Fall-back case: America/Los_Angeles falls back 2027-11-07 (2:00am -> 1:00am).
        // A job scheduled 2027-11-08 fires 5pm local on 2027-11-07 — after the
        // repeated hour, so no ambiguity affects the 17:00 instant.
        let fallBackFire = NativeAppointmentNotifications.fireDate(for: "2027-11-08", calendar: calendar)
        let expectedFallBack = calendar.date(from: .init(year: 2027, month: 11, day: 7, hour: 17))
        expect(fallBackFire == expectedFallBack, "DST fall-back: still 5pm local on the transition day")

        // ── Active-status set (RN ACTIVE_STATUSES = approved/scheduled/in_progress) ──
        let now = calendar.date(from: .init(year: 2026, month: 7, day: 1))!
        let customers = [makeCustomer()]
        for status in ["approved", "scheduled", "in_progress"] {
            let reminders = NativeAppointmentNotifications.reminders(
                jobs: [makeJob(status: status)], customers: customers, enabled: true, now: now, calendar: calendar)
            expect(reminders.count == 1, "status '\(status)' qualifies for an appointment reminder")
        }
        for status in ["lead", "estimate_sent", "invoiced", "complete", "cancelled"] {
            let reminders = NativeAppointmentNotifications.reminders(
                jobs: [makeJob(status: status)], customers: customers, enabled: true, now: now, calendar: calendar)
            expect(reminders.isEmpty, "status '\(status)' does not qualify for an appointment reminder")
        }

        // ── Contact requirement (RN resolveChannel: sms preferred, email fallback, else none) ──
        let noContact = [makeCustomer(phone: "", email: "")]
        expect(NativeAppointmentNotifications.reminders(
            jobs: [makeJob()], customers: noContact, enabled: true, now: now, calendar: calendar).isEmpty,
            "no phone and no email excludes the job")
        let phoneOnly = [makeCustomer(phone: "5551234567", email: "")]
        expect(NativeAppointmentNotifications.reminders(
            jobs: [makeJob()], customers: phoneOnly, enabled: true, now: now, calendar: calendar).count == 1,
            "phone-only contact qualifies")
        let emailOnly = [makeCustomer(phone: "", email: "a@x.com")]
        expect(NativeAppointmentNotifications.reminders(
            jobs: [makeJob()], customers: emailOnly, enabled: true, now: now, calendar: calendar).count == 1,
            "email-only contact qualifies")
        let whitespaceOnly = [makeCustomer(phone: "   ", email: "  ")]
        expect(NativeAppointmentNotifications.reminders(
            jobs: [makeJob()], customers: whitespaceOnly, enabled: true, now: now, calendar: calendar).isEmpty,
            "whitespace-only contact fields count as absent")

        // Toggle off schedules nothing regardless of otherwise-qualifying jobs.
        expect(NativeAppointmentNotifications.reminders(
            jobs: [makeJob()], customers: customers, enabled: false, now: now, calendar: calendar).isEmpty,
            "toggle off schedules nothing")

        // A fire date already in the past is excluded (job scheduled for yesterday).
        let pastJob = makeJob(scheduledDate: "2020-01-02")
        expect(NativeAppointmentNotifications.reminders(
            jobs: [pastJob], customers: customers, enabled: true, now: now, calendar: calendar).isEmpty,
            "a fire date already past is excluded")

        // ── Stable soonest-first ordering ───────────────────────────────────
        // Three jobs with distinct fire dates in scrambled input order sort
        // ascending by fireDate...
        let scrambled = [
            makeJob(id: "late", customerId: "c1", scheduledDate: "2026-08-10"),
            makeJob(id: "soon", customerId: "c1", scheduledDate: "2026-07-15"),
            makeJob(id: "mid", customerId: "c1", scheduledDate: "2026-07-25"),
        ]
        let sorted = NativeAppointmentNotifications.reminders(
            jobs: scrambled, customers: customers, enabled: true, now: now, calendar: calendar)
        expect(sorted.map(\.jobID) == ["soon", "mid", "late"], "reminders sort soonest-fire-date first")

        // ...and two jobs with an IDENTICAL fire date (same scheduledDate)
        // preserve their original input order (stable sort), matching JS
        // Array.prototype.sort's guaranteed stability since ES2019.
        let tied = [
            makeJob(id: "tie-a", customerId: "c1", scheduledDate: "2026-07-20"),
            makeJob(id: "tie-b", customerId: "c1", scheduledDate: "2026-07-20"),
        ]
        let tiedSorted = NativeAppointmentNotifications.reminders(
            jobs: tied, customers: customers, enabled: true, now: now, calendar: calendar)
        expect(tiedSorted.map(\.jobID) == ["tie-a", "tie-b"], "equal fire dates preserve stable input order")

        // ── Notification plan item shape (RN `appt_<jobId>` / appointment_confirm) ──
        let plan = NativeAppointmentNotifications.notificationPlan(
            jobs: [makeJob()], customers: customers, enabled: true, now: now, calendar: calendar)
        expect(plan.first?.identifier == "appt_j1", "plan identifier is appt_<jobId>")
        expect(plan.first?.route.namespace.payloadType == "appointment_confirm", "plan stamps the appointment_confirm payload type")
        expect(plan.first?.title == "Confirm tomorrow's job — Alice", "plan title matches the RN notification title")
        expect(plan.first?.body.contains("Tap to send Alice a confirmation") == true, "plan body matches the RN notification body")

        // ── Tap routing never invents a destination (N6) ───────────────────
        expect(NativeAppointmentNotifications.canOpenNotification(exactOwnerWorkspace: true, signedIn: true, job: nil) == false, "requires the exact current job for a tap")
        expect(NativeAppointmentNotifications.canOpenNotification(exactOwnerWorkspace: false, signedIn: true, job: makeJob()) == false, "requires the exact owner workspace")
        expect(NativeAppointmentNotifications.canOpenNotification(exactOwnerWorkspace: true, signedIn: false, job: makeJob()) == false, "requires an active signed-in session")
        expect(NativeAppointmentNotifications.canOpenNotification(exactOwnerWorkspace: true, signedIn: true, job: makeJob()), "opens when the exact job, workspace, and session all line up")

        // Final-review I1 (RN parity, contract §9.6): an archived job keeps
        // its appt_ notification AND its tap opens — never a dead tap.
        var archived = makeJob(id: "j-archived")
        archived.archivedAt = "2026-07-10"
        let archivedPlan = NativeAppointmentNotifications.notificationPlan(
            jobs: [archived], customers: customers, enabled: true, now: now, calendar: calendar)
        expect(archivedPlan.map(\.identifier) == ["appt_j-archived"],
               "I1 an archived scheduled job still gets its appt_ notification (RN archive.ts parity)")
        expect(NativeAppointmentNotifications.canOpenNotification(exactOwnerWorkspace: true, signedIn: true, job: archived),
               "I1 the archived job's appt_ tap opens (paired with the scheduled notification above)")
        expect(NativeAppointmentNotifications.canOpenNotification(exactOwnerWorkspace: false, signedIn: true, job: archived) == false,
               "I1 a foreign/non-exact workspace still fails closed for an archived job")

        if failures == 0 { print("PASS: appointment notification tests") } else { exit(1) }
    }
}
