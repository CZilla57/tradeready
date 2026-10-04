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
    total: String = "850",
    quoteOptions: String? = nil,
    validUntil: String? = nil
) throws -> Canonical.Job {
    let approval = approvalSentAt.map {
        """
        ,"approval":{"token":"token","sentAt":"\($0)","snapshot":{"businessName":"Dave Plumbing","customerName":"Dave Smith","jobTitle":"\(title)","lineItems":[],"total":\(total),"currency":"USD"}}
        """
    } ?? ""
    let sent = estimateSentAt.map { ",\"estimateSentAt\":\"\($0)\"" } ?? ""
    let options = quoteOptions.map { ",\"quoteOptions\":\($0)" } ?? ""
    let validity = validUntil.map { ",\"estimateValidUntil\":\"\($0)\"" } ?? ""
    let json = """
    {"id":"\(id)","customerId":"c1","customerName":"Dave Smith","title":"\(title)","description":"","status":"\(status)","scheduledDate":null,"scheduledStartTime":null,"scheduledEndTime":null,"address":"","estimateTotal":\(total),"laborHours":3,"laborRate":85,"materials":[],"materialMarkup":20,"overhead":15,"margin":20,"notes":"","invoiceId":null,"createdAt":"2026-07-01"\(sent)\(approval)\(options)\(validity)}
    """
    return try JSONDecoder().decode(Canonical.Job.self, from: Data(json.utf8))
}

/// Phase 32 (spec 2026-10-03 §6.7): dated reminders, the `est_exp_`
/// reminder and its fold rule, and the dated customer copy.
private func quoteExpiryTests() throws {
    let calendar = phoenixCalendar()
    let now = localDate(2026, 8, 2, 12)

    // A 30-day estimate sent Aug 1 (valid until Aug 31): both reminders.
    let dated = try makeJob(estimateSentAt: "2026-08-01", validUntil: "2026-08-31")
    let datedReminders = NativeEstimateFollowUp.upcomingReminders(jobs: [dated], now: now, calendar: calendar)
    expect(datedReminders.map(\.kind) == [.followUp, .expiry], "Phase 32: a dated estimate gets the 3-day and the expiry reminder, soonest first")
    expect(datedReminders.last?.fireDate == localDate(2026, 8, 29, 9),
           "Phase 32: est_exp_ fires at 9:00 Phoenix two days before validUntil")
    expect(datedReminders.allSatisfy { $0.validUntil == "2026-08-31" }, "Phase 32: both reminders carry the date")

    let plan = NativeEstimateFollowUp.notificationPlan(jobs: [dated], now: now, enabled: true, calendar: calendar)
    expect(plan == [
        .init(
            identifier: "est_j1",
            jobID: "j1",
            title: "Estimate follow-up — Dave Smith",
            body: "Estimate for \"Water heater swap\" sent 3 days ago with no response. It expires Aug 31. Tap to follow up.",
            fireDate: localDate(2026, 8, 4, 9)
        ),
        .init(
            identifier: "est_exp_j1",
            jobID: "j1",
            title: "Estimate expiring — Dave Smith",
            body: "Your estimate for \"Water heater swap\" expires in 2 days (Aug 31). Tap to follow up or extend it.",
            fireDate: localDate(2026, 8, 29, 9)
        )
    ], "Phase 32: identifiers, titles and dated copy for both reminders")
    expect(plan.allSatisfy { $0.identifier.hasPrefix("est_") }, "Phase 32: both identifiers fall inside the coordinator's est_ prefix")

    // Fold rule: the expiry reminder must fire strictly after the 3-day one.
    let folded = try makeJob(estimateSentAt: "2026-08-01", validUntil: "2026-08-06") // exp would be Aug 4 9:00 == 3-day
    expect(NativeEstimateFollowUp.upcomingReminders(jobs: [folded], now: now, calendar: calendar).map(\.kind) == [.followUp],
           "Phase 32: an expiry reminder at the same instant as the 3-day one folds into it")
    let short = try makeJob(estimateSentAt: "2026-08-01", validUntil: "2026-08-03") // short validity
    let shortPlan = NativeEstimateFollowUp.notificationPlan(jobs: [short], now: now, enabled: true, calendar: calendar)
    expect(shortPlan.map(\.identifier) == ["est_j1"], "Phase 32: a short validity schedules only the 3-day reminder")
    expect(shortPlan.first?.body == "Estimate for \"Water heater swap\" sent 3 days ago with no response. It expired Aug 3. Tap to follow up.",
           "Phase 32: the 3-day copy says expired when the fire day is past the date")
    let onTheDay = try makeJob(estimateSentAt: "2026-08-01", validUntil: "2026-08-04")
    expect(NativeEstimateFollowUp.notificationPlan(jobs: [onTheDay], now: now, enabled: true, calendar: calendar).first?.body
               == "Estimate for \"Water heater swap\" sent 3 days ago with no response. It expires Aug 4. Tap to follow up.",
           "Phase 32: the 3-day copy still says expires on the last valid day")
    let nextAfter = try makeJob(estimateSentAt: "2026-08-01", validUntil: "2026-08-07") // exp Aug 5 9:00
    expect(NativeEstimateFollowUp.upcomingReminders(jobs: [nextAfter], now: now, calendar: calendar).map(\.kind) == [.followUp, .expiry],
           "Phase 32: one day later than the fold boundary schedules both")

    // The 3-day reminder already fired: the expiry reminder alone remains.
    let later = localDate(2026, 8, 10, 12)
    expect(NativeEstimateFollowUp.upcomingReminders(jobs: [dated], now: later, calendar: calendar).map(\.kind) == [.expiry],
           "Phase 32: after the 3-day reminder fires, the expiry reminder is still scheduled")
    expect(NativeEstimateFollowUp.upcomingReminders(jobs: [dated], now: localDate(2026, 8, 29, 9), calendar: calendar).isEmpty,
           "Phase 32: a past expiry fire date cannot recreate the reminder")

    // Undated, malformed, answered.
    let undated = try makeJob(estimateSentAt: "2026-08-01")
    expect(NativeEstimateFollowUp.upcomingReminders(jobs: [undated], now: now, calendar: calendar).map(\.kind) == [.followUp],
           "Phase 32: an undated estimate gets only the 3-day reminder")
    let malformed = try makeJob(estimateSentAt: "2026-08-01", validUntil: "2026-02-30")
    let malformedPlan = NativeEstimateFollowUp.notificationPlan(jobs: [malformed], now: now, enabled: true, calendar: calendar)
    expect(malformedPlan.map(\.identifier) == ["est_j1"]
               && malformedPlan.first?.body == "Estimate for \"Water heater swap\" sent 3 days ago with no response. Tap to follow up.",
           "Phase 32: a malformed date is treated as undated")
    let answered = try makeJob(status: "scheduled", estimateSentAt: "2026-08-01", validUntil: "2026-08-31")
    expect(NativeEstimateFollowUp.upcomingReminders(jobs: [answered], now: now, calendar: calendar).isEmpty,
           "Phase 32: a job that moved on gets no expiry reminder")

    // DST: Phoenix has none, but the 9:00 local rule holds in New York across the fall change.
    var newYork = Calendar(identifier: .gregorian)
    newYork.timeZone = TimeZone(identifier: "America/New_York")!
    let dst = try makeJob(estimateSentAt: "2026-10-20", validUntil: "2026-11-03")
    let dstExpiry = NativeEstimateFollowUp.upcomingReminders(jobs: [dst], now: localDate(2026, 10, 21), calendar: newYork).last
    expect(dstExpiry?.kind == .expiry
               && dstExpiry?.fireDate == ISO8601DateFormatter().date(from: "2026-11-01T14:00:00Z"),
           "Phase 32: the expiry reminder is 9:00 EST on Nov 1 after the DST change")

    // Ordering across jobs and kinds, and the shared cap.
    let a = try makeJob(id: "a", estimateSentAt: "2026-08-01", validUntil: "2026-08-10") // 3-day Aug 4, exp Aug 8
    let b = try makeJob(id: "b", estimateSentAt: "2026-08-02", validUntil: "2026-08-07") // 3-day Aug 5, exp Aug 5 (folded)
    let c = try makeJob(id: "c", estimateSentAt: "2026-08-02", validUntil: "2026-08-08") // 3-day Aug 5, exp Aug 6
    let mixed = NativeEstimateFollowUp.notificationPlan(jobs: [a, b, c], now: now, enabled: true, calendar: calendar)
    expect(mixed.map(\.identifier) == ["est_a", "est_b", "est_c", "est_exp_c", "est_exp_a"],
           "Phase 32: reminders of both kinds interleave soonest-first with source order for ties")
    expect(NativeEstimateFollowUp.notificationPlan(jobs: [a, b, c], now: now, enabled: true, maximumCount: 4, calendar: calendar)
               .map(\.identifier) == ["est_a", "est_b", "est_c", "est_exp_c"],
           "Phase 32: the shared cap counts both kinds")
    let many = try (0..<40).map { try makeJob(id: "m\($0)", estimateSentAt: "2026-08-01", validUntil: "2026-08-31") }
    let manyPlan = NativeEstimateFollowUp.notificationPlan(jobs: many, now: now, enabled: true, calendar: calendar)
    expect(manyPlan.count == 60 && manyPlan.prefix(40).allSatisfy { !$0.identifier.hasPrefix("est_exp_") },
           "Phase 32: 80 candidates cap at 60, the sooner 3-day reminders first")
    expect(NativeEstimateFollowUp.notificationPlan(jobs: [dated], now: now, enabled: false, calendar: calendar).isEmpty,
           "Phase 32: the settings toggle suppresses the expiry reminder too")
    expect(NativeEstimateFollowUp.notificationIdentifier(jobID: "x", kind: .followUp) == "est_x"
               && NativeEstimateFollowUp.notificationIdentifier(jobID: "x", kind: .expiry) == "est_exp_x",
           "Phase 32: identifier scheme")

    // Customer follow-up message.
    let quoted = try makeJob(title: "Panel upgrade", total: "2499.5", validUntil: "2026-11-02")
    let validNow = localDate(2026, 10, 20, 12)
    expect(NativeEstimateFollowUp.message(job: quoted, customerFirstName: "Dave", now: validNow, calendar: calendar)
               == "Hi Dave, just checking in on the estimate I sent over for Panel upgrade ($2,499.50). It's valid until November 2, 2026. Happy to answer any questions — want me to get you on the schedule?",
           "Phase 32: a valid dated estimate names its date")
    expect(NativeEstimateFollowUp.message(job: quoted, customerFirstName: "Dave", now: localDate(2026, 11, 2, 23, 30), calendar: calendar)
               .contains("It's valid until November 2, 2026."),
           "Phase 32: 23:30 local on the date is still valid")
    expect(NativeEstimateFollowUp.message(job: quoted, customerFirstName: "Dave", now: localDate(2026, 11, 3, 0, 0), calendar: calendar)
               == "Hi Dave, just checking in on the estimate I sent over for Panel upgrade. It expired on November 2, 2026, but I'm happy to put together an updated one — want me to take another look?",
           "Phase 32: an expired estimate offers an updated one")
    func tier(_ id: String, _ total: String) -> String {
        #"{"id":"\#(id)","name":"\#(id)","laborHours":3,"laborRate":85,"materials":[],"materialMarkup":20,"overhead":15,"margin":20,"estimateTotal":\#(total)}"#
    }
    let options = try makeJob(
        title: "Water heater",
        total: "1800",
        quoteOptions: #"{"tiers":[\#(tier("standard", "1800")),\#(tier("repair", "450.5"))],"addOns":[],"recommendedTierId":"standard"}"#,
        validUntil: "2026-11-02"
    )
    expect(NativeEstimateFollowUp.message(job: options, customerFirstName: "Dave", now: validNow, calendar: calendar)
               == "Hi Dave, just checking in on your quote options for Water heater (from $450.50). They're valid until November 2, 2026. Happy to answer any questions — want me to get you on the schedule?",
           "Phase 32: options copy names the date")
    expect(NativeEstimateFollowUp.message(job: options, customerFirstName: "Dave", now: localDate(2026, 11, 5, 9), calendar: calendar)
               .hasPrefix("Hi Dave, just checking in on the estimate I sent over for Water heater. It expired on November 2, 2026"),
           "Phase 32: expired options use the expired copy")
    let undatedQuote = try makeJob(title: "Panel upgrade", total: "2499.5")
    expect(NativeEstimateFollowUp.message(job: undatedQuote, customerFirstName: "Dave", now: validNow, calendar: calendar)
               == "Hi Dave, just checking in on the estimate I sent over for Panel upgrade ($2,499.50). Happy to answer any questions — want me to get you on the schedule?",
           "Phase 32: undated copy is unchanged")
    let draft = NativeEstimateFollowUp.draft(
        job: quoted, customerName: "Dave Smith", customerPhone: "555-0100", customerEmail: "",
        businessName: "Rector Plumbing", now: validNow, calendar: calendar
    )
    expect(draft?.body.contains("It's valid until November 2, 2026.") == true, "Phase 32: the draft passes now through to the copy")

    // Extension notice.
    let link = URL(string: "https://example.test/estimate?j=j1&t=token")!
    let extended = try makeJob(title: "Panel upgrade", total: "2499.5", validUntil: "2026-12-01")
    let linked = NativeEstimateFollowUp.extensionDraft(
        job: extended, approvalLink: link, customerName: " Dave Smith ", customerPhone: "555-0100",
        customerEmail: "dave@example.test", businessName: "Rector Plumbing", calendar: calendar
    )
    expect(linked?.body == "Hi Dave, good news — I've extended your estimate for Panel upgrade ($2,499.50) until December 1, 2026. You can review and approve it here: \(link.absoluteString)",
           "Phase 32: the extension notice with a link")
    expect(linked?.emailSubject == "Your estimate from Rector Plumbing has been extended"
               && linked?.customerName == "Dave Smith" && linked?.jobID == "j1",
           "Phase 32: the extension subject and recipient")
    expect(NativeEstimateFollowUp.extensionDraft(
        job: extended, approvalLink: nil, customerName: "Dave Smith", customerPhone: "555-0100",
        customerEmail: "", businessName: "Rector Plumbing", calendar: calendar
    )?.body == "Hi Dave, good news — I've extended your estimate for Panel upgrade ($2,499.50) until December 1, 2026. Just reply to approve and I'll get you on the schedule.",
           "Phase 32: the extension notice without a link")
    let extendedOptions = try makeJob(
        title: "Water heater",
        total: "1800",
        quoteOptions: #"{"tiers":[\#(tier("standard", "1800")),\#(tier("repair", "450.5"))],"addOns":[],"recommendedTierId":"standard"}"#,
        validUntil: "2026-12-01"
    )
    expect(NativeEstimateFollowUp.extensionDraft(
        job: extendedOptions, approvalLink: nil, customerName: "Dave Smith", customerPhone: "",
        customerEmail: "d@example.test", businessName: "Rector Plumbing", calendar: calendar
    )?.body.contains("your estimate for Water heater (from $450.50) until December 1, 2026.") == true,
           "Phase 32: undecided options quote from the lowest tier")
    let neverExpires = try makeJob(title: "Panel upgrade", total: "100")
    expect(NativeEstimateFollowUp.extensionDraft(
        job: neverExpires, approvalLink: nil, customerName: "Dave Smith",
        customerPhone: "555-0100", customerEmail: "", businessName: "Rector Plumbing", calendar: calendar
    )?.body == "Hi Dave, good news — I've extended your estimate for Panel upgrade ($100), and it no longer expires. Just reply to approve and I'll get you on the schedule.",
           "Phase 32: an extension to 'Doesn't expire' says so")
    let movedOn = try makeJob(status: "scheduled", validUntil: "2026-12-01")
    expect(NativeEstimateFollowUp.extensionDraft(
        job: movedOn, approvalLink: nil, customerName: "Dave Smith",
        customerPhone: "555-0100", customerEmail: "", businessName: "Rector Plumbing", calendar: calendar
    ) == nil && NativeEstimateFollowUp.extensionDraft(
        job: extended, approvalLink: nil, customerName: "  ", customerPhone: "555-0100",
        customerEmail: "", businessName: "Rector Plumbing", calendar: calendar
    ) == nil,
           "Phase 32: no extension notice for a job that moved on or a nameless customer")
}

/// Review fix 2026-10-03 (finding 1): the expiry reminder and the dated copy
/// under a Buddhist or Japanese device calendar (what `Calendar.current` is
/// when the iPhone's Calendar setting is not Gregorian). `estimateValidUntil`
/// is a Gregorian `YYYY-MM-DD`, so the reminder fires on that Gregorian day
/// and the copy compares Gregorian days. The send stamp here is a link-only
/// `approval.sentAt` instant, which reads the same in every calendar.
private func deviceCalendarTests() throws {
    for identifier in [Calendar.Identifier.buddhist, .japanese] {
        var device = Calendar(identifier: identifier)
        device.locale = Locale(identifier: "en_US")
        device.timeZone = TimeZone(identifier: "America/Phoenix")!
        let name = "\(identifier)"
        let now = localDate(2026, 8, 2, 12)
        let dated = try makeJob(approvalSentAt: "2026-08-01T19:00:00.000Z", validUntil: "2026-08-31")

        let reminders = NativeEstimateFollowUp.upcomingReminders(jobs: [dated], now: now, calendar: device)
        expect(reminders.map(\.kind) == [.followUp, .expiry],
               "\(name) calendar: a dated estimate still gets both reminders (got \(reminders.map(\.kind)))")
        expect(reminders.last?.fireDate == localDate(2026, 8, 29, 9),
               "\(name) calendar: est_exp_ fires at 9:00 Phoenix on the Gregorian validUntil − 2 (got \(reminders.last.map { "\($0.fireDate)" } ?? "nil"))")
        let plan = NativeEstimateFollowUp.notificationPlan(jobs: [dated], now: now, enabled: true, calendar: device)
        expect(plan.first?.body == "Estimate for \"Water heater swap\" sent 3 days ago with no response. It expires Aug 31. Tap to follow up.",
               "\(name) calendar: the 3-day copy compares Gregorian days (got \(plan.first?.body ?? "nil"))")

        let quoted = try makeJob(title: "Panel upgrade", total: "2499.5", validUntil: "2026-11-02")
        expect(NativeEstimateFollowUp.message(job: quoted, customerFirstName: "Dave", now: localDate(2026, 10, 20, 12), calendar: device)
                   .contains("It's valid until November 2, 2026."),
               "\(name) calendar: an open estimate is not called expired")
        expect(NativeEstimateFollowUp.message(job: quoted, customerFirstName: "Dave", now: localDate(2026, 11, 3, 0, 0), calendar: device)
                   .contains("It expired on November 2, 2026"),
               "\(name) calendar: the day after is expired")
    }
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

        // Phase 25: undecided good/better/best options quote "from" the
        // lowest tier, whatever the tier order or the recommended tier.
        func tier(_ id: String, _ total: String) -> String {
            #"{"id":"\#(id)","name":"\#(id)","laborHours":3,"laborRate":85,"materials":[],"materialMarkup":20,"overhead":15,"margin":20,"estimateTotal":\#(total)}"#
        }
        let tiers = "[\(tier("standard", "1800")),\(tier("repair", "450.5")),\(tier("premium", "2600"))]"
        let undecidedOptions = try makeJob(
            title: "Water heater",
            total: "1800",
            quoteOptions: #"{"tiers":\#(tiers),"addOns":[],"recommendedTierId":"standard"}"#
        )
        let optionsMessage = NativeEstimateFollowUp.message(job: undecidedOptions, customerFirstName: "Dave")
        expect(
            optionsMessage == "Hi Dave, just checking in on your quote options for Water heater (from $450.50). Happy to answer any questions — want me to get you on the schedule?",
            "Phase 25: undecided options copy quotes the lowest tier total"
        )
        let optionsDraft = NativeEstimateFollowUp.draft(
            job: undecidedOptions,
            customerName: "Dave Smith",
            customerPhone: "555-0100",
            customerEmail: "",
            businessName: "Rector Plumbing",
            calendar: calendar
        )
        expect(
            optionsDraft?.body == optionsMessage && optionsDraft?.estimateTotal == 1800
                && optionsDraft?.emailSubject == "Checking in on your estimate — Rector Plumbing",
            "Phase 25: the options draft uses the options copy and keeps the job's displayed total"
        )
        let acceptedOptions = try makeJob(
            title: "Water heater",
            total: "1950",
            quoteOptions: #"{"tiers":\#(tiers),"addOns":[],"recommendedTierId":"standard","acceptance":{"tierId":"standard","addOnIds":[],"total":1950,"acceptedAt":"2026-08-02T10:00:00.000Z","source":"owner"}}"#
        )
        expect(
            NativeEstimateFollowUp.message(job: acceptedOptions, customerFirstName: "Dave")
                == "Hi Dave, just checking in on the estimate I sent over for Water heater ($1,950). Happy to answer any questions — want me to get you on the schedule?",
            "Phase 25: accepted options use the normal single-estimate copy"
        )
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

        try quoteExpiryTests()
        try deviceCalendarTests()

        if failures == 0 {
            print("PASS: native estimate follow-up eligibility and message tests")
        } else {
            exit(1)
        }
    }
}
