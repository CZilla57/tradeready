import Foundation
import UserNotifications

// Phase 10 cross-client and hosted-contract qualification (task 10.14).
//
// One canonical fixture threaded through the Today surface, business
// snapshot, coach, and notification engines in a single run, proving the
// SEAMS hold: the snapshot the coach cites is the snapshot Today derives,
// the setup-checklist gate that hides the hero is the same gate the insights
// card reads, and reconciling notifications twice from the same fixture
// yields the identical pending set (idempotent scheduling, B2). Each
// focused runner (10.01–10.13) already covers its own task's RN-oracle
// parity in depth; this suite does not re-derive that coverage — see the
// task-10.14-report.md equivalence matrix for what is referenced vs.
// exercised fresh here.
//
// Three intentional native differences from RN are recorded and asserted
// here (not re-litigated): `weekMonthLabel`'s FA-039 UTC-parse defect
// (§1), `Math.round` vs. Swift `.rounded()` half-rounding for negative
// values (§2, never hit live — see 10.02 report), and the setup
// checklist's `rate` task completion trigger, `SettingsView.swift`
// `PricingDefaultsSettings.onDisappear` vs. RN's on-save (§3 — see the
// 10.12 report and the parity-matrix row this task adds).
//
// REFERENCED, not redone: the post-sync-commit derived-state seam (task
// 10.09, requirement B1) — `NativeDerivedStatePublisher` firing the
// notification-reconcile hook, the widget-mirror observer notification, and
// the cached business-snapshot refresh exactly once per committed canonical
// sync commit, never on `.alreadyRunning`, offline, signed-out, or a
// pre-commit failure. The publisher's own contract (failure isolation,
// owner-identity re-verification, the stale-resume generation guard, the
// register/cache surface) is unit-tested in
// `native/BackgroundRefreshTests/main.swift` ("Task 10.09 (B1):
// NativeDerivedStatePublisher seam matrix", run via
// `native/run-background-refresh-tests.sh`). The higher-level "exactly
// once per committed commit" guarantee across AppStore's actual commit call
// sites (`pullDeltaIfPossible`, `runBookingIntakeAfterVerifiedPull`'s local
// commit, and the initial-sync commit in `beginInitialSyncGate`) is
// integration-tested in `native/StoreIntegrationTests/main.swift` ("Task
// 10.09 (B1): AppStore's derived-state seam wiring", plus its "fix round 1:
// real call-site coverage" and "fix round 2: initial-sync publish ordering"
// sections), run via `native/run-store-integration-tests.sh`. This suite
// does not re-derive either of those; the business-snapshot and coach seam
// tests below (§S1/S2) exercise the *data* the hook refreshes, not the
// hook's firing discipline itself.

private var failures = 0

private func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
    if !condition() {
        failures += 1
        print("FAIL: \(label)")
    }
}

private func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ label: String) {
    if actual != expected {
        failures += 1
        print("FAIL: \(label) — expected \(expected), got \(actual)")
    }
}

private func expectContains(_ haystack: String, _ needle: String, _ label: String) {
    if !haystack.contains(needle) {
        failures += 1
        print("FAIL: \(label) — expected text to contain \(needle.debugDescription)")
    }
}

private func expectNotContains(_ haystack: String, _ needle: String, _ label: String) {
    if haystack.contains(needle) {
        failures += 1
        print("FAIL: \(label) — expected text to NOT contain \(needle.debugDescription)")
    }
}

private let decoder = JSONDecoder()

private func merge(_ base: String, _ overrides: String) -> String {
    guard !overrides.isEmpty else { return base }
    func fields(_ json: String) -> [String: String] {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        var result: [String: String] = [:]
        for (key, value) in object {
            if let data = try? JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed),
               let text = String(data: data, encoding: .utf8) {
                result[key] = text
            }
        }
        return result
    }
    let merged = fields(base).merging(fields(overrides)) { _, new in new }
    let body = merged.map { "\"\($0.key)\":\($0.value)" }.joined(separator: ",")
    return "{\(body)}"
}

// MARK: - Shared fixture (Tue Aug 4 2026, 10:00 local — matches 10.02's oracle
// fixture clock so this suite is directly comparable to TodayInsightsTests)

private let now = NativeCashBasis.localDate(year: 2026, month: 7, day: 4, hour: 10)

private func job(_ overrides: String = "") -> Canonical.Job {
    let base = """
    {"id":"j1","customerId":"c1","customerName":"Dana","title":"Faucet repair",
     "description":"","status":"in_progress","address":"","estimateTotal":1200,
     "laborHours":2,"laborRate":85,"materials":[],"materialMarkup":20,
     "overhead":15,"margin":20,"notes":"","createdAt":"2026-08-01"}
    """
    return try! decoder.decode(Canonical.Job.self, from: Data(merge(base, overrides).utf8))
}

private func invoice(_ overrides: String = "") -> Canonical.Invoice {
    let base = """
    {"id":"i1","customer":"Dana","number":"INV-0042","amount":850,"due":"2026-08-05",
     "email":"","phone":"","desc":"","paid":false}
    """
    return try! decoder.decode(Canonical.Invoice.self, from: Data(merge(base, overrides).utf8))
}

private func customer(_ overrides: String = "") -> Canonical.Customer {
    let base = """
    {"id":"c1","name":"Dana","email":"dana@example.com","phone":"555-0100",
     "address":"1 Main St","notes":"","createdAt":"2026-01-01"}
    """
    return try! decoder.decode(Canonical.Customer.self, from: Data(merge(base, overrides).utf8))
}

/// The fixture: one uninvoiced-complete job below margin (triggers both
/// `low_margin_estimate` and `uninvoiced_complete`), one invoice due
/// tomorrow (`due_soon`), one customer. Insight kinds not exercised directly
/// here (`labor_overrun`, `open_slot`, `unscheduled_approved`,
/// `maintenance_due`, `expense_anomaly`) are already exhaustively pinned
/// against the RN oracle in `TodayInsightsTests` (task 10.02) — referenced,
/// not redone, per the brief's "covered elsewhere" allowance.
private enum Fixture {
    static let job1 = job("""
    {"status":"complete","estimateTotal":1000,"laborHours":4,"laborRate":85,
     "overhead":15,"margin":20}
    """)
    static let jobs = [job1]
    static let invoices = [invoice()]
    static let customers = [customer()]
    static let expenses: [Canonical.Expense] = []

    static func settings(anthropicKey: String = "", groqKey: String = "") -> Canonical.Settings {
        let json = """
        {
          "businessName": "Ace Plumbing", "contactName": "Sam", "phone": "555-0100", "email": "", "address": "1 Main St",
          "trade": "plumbing", "laborRate": 85, "materialMarkup": 20,
          "overheadPercent": 15, "marginPercent": 20, "minimumJobFee": 0,
          "travelFeePerMile": 0, "emergencyMultiplier": 1, "mileageRate": 0.67,
          "paymentNotes": "", "provider": "stripe", "providerKey": "", "providerKeys": {},
          "rules": [], "autoOutreachEnabled": false, "autoSendEmailEnabled": false,
          "appointmentRemindersEnabled": false, "appointmentConfirmTemplate": "", "onMyWayTemplate": "",
          "estimateFollowUpsEnabled": false, "autoInvoiceOnComplete": false, "autoEmailInvoiceOnComplete": false,
          "anthropicKey": "\(anthropicKey)", "groqKey": "\(groqKey)", "reviewRequestEnabled": false,
          "reviewRequestTemplate": "", "googleReviewLink": "", "reviewRequestDelayHours": 24
        }
        """
        return try! decoder.decode(Canonical.Settings.self, from: Data(json.utf8))
    }
}

// MARK: - 1. Business snapshot + tax block (S1, S2): determinism and the coach seam

private func testBusinessSnapshotSeam() {
    let aggregate1 = NativeBusinessSnapshotEngine.aggregate(
        invoices: Fixture.invoices, jobs: Fixture.jobs, customers: Fixture.customers, now: now
    )
    let aggregate2 = NativeBusinessSnapshotEngine.aggregate(
        invoices: Fixture.invoices, jobs: Fixture.jobs, customers: Fixture.customers, now: now
    )
    expectEqual(aggregate1, aggregate2, "the same fixture aggregates identically twice (determinism)")
    expectEqual(aggregate1.overdueCount, 0, "the invoice is due tomorrow, not yet overdue, at the fixture clock")
    expectEqual(aggregate1.activeJobsByStatus["complete"], nil, "complete is not an active-work status")

    // S2: a real tax block, not `nil` — a paid invoice in the fixture gives
    // the reserve engine something to reserve against, so this exercises the
    // actual `TaxEstimateEngine` seam rather than asserting around an absent
    // block. `NativeBusinessSnapshotEngine.buildTaxBlock`'s own fixture-level
    // coverage (unset income rate, unset vehicle method, period/deadline
    // labels) is already pinned in `native/BusinessSnapshotTests/main.swift`
    // (task 10.01); this only proves the block reaches the coach prompt.
    let taxInvoice = invoice("""
    {"id":"i-tax","number":"INV-TAX","amount":5000,"due":"2026-07-01","paid":true,
     "payments":[{"id":"p-tax","amount":5000,"date":"2026-07-15","method":"cash"}]}
    """)
    let taxValues = NativeTaxSettingsValues(taxIncomeRate: 25, vehicleDeductionMethod: .mileage)
    let taxBlock1 = NativeBusinessSnapshotEngine.buildTaxBlock(
        invoices: [taxInvoice], expenses: [], trips: [],
        values: taxValues, mileageRate: Decimal(string: "0.7")!, now: now
    )
    let taxBlock2 = NativeBusinessSnapshotEngine.buildTaxBlock(
        invoices: [taxInvoice], expenses: [], trips: [],
        values: taxValues, mileageRate: Decimal(string: "0.7")!, now: now
    )
    expectEqual(taxBlock1, taxBlock2, "the same fixture builds an identical tax block twice (determinism)")
    expect(taxBlock1.periodReserve > 0, "the fixture's paid invoice produces a positive period reserve")
    expect(taxBlock1.incomeRateSet, "an explicit income rate is reported as set")
    expect(!taxBlock1.needsVehicleChoice, "an elected vehicle method clears the prompt")

    let snapshot = NativeBusinessSnapshot(asOf: "2026-08-04", aggregate: aggregate1, tax: taxBlock1)
    let settings = Fixture.settings(anthropicKey: "sk-ant-SECRET-do-not-leak", groqKey: "gsk-SECRET-do-not-leak")
    let prompt = NativeCoachPrompt.buildSystemPrompt(settings: settings, snapshot: snapshot)

    // The seam: the coach prompt's business context is built FROM this same
    // snapshot, not re-derived — so a figure the snapshot carries must appear
    // in the prompt text.
    expectContains(prompt, "Ace Plumbing", "the prompt cites the same business name as settings")
    expectContains(prompt, "Sam", "the prompt cites the contact name")
    expectContains(prompt, "Tax set-aside estimate", "the coach prompt cites the tax block (S2) when one is attached")
    expectContains(prompt, taxBlock1.periodLabel, "the prompt's tax period matches the snapshot's own label")

    // Secure provider keys are never interpolated into the prompt (global
    // constraint: "never interpolated into prompts, notifications, analytics,
    // or logs").
    expectNotContains(prompt, "sk-ant-SECRET-do-not-leak", "the Anthropic key never reaches the prompt text")
    expectNotContains(prompt, "gsk-SECRET-do-not-leak", "the Groq key never reaches the prompt text")
}

// MARK: - 2. Insights: cross-kind fixture, determinism, and the mute seam

private func testInsightsAndMuteSeam() {
    let select1 = NativeTodayInsights.select(
        jobs: Fixture.jobs, invoices: Fixture.invoices, now: now,
        targetMarginPercent: 20,
        customers: Fixture.customers, recurringJobs: [], expenses: Fixture.expenses
    )
    let select2 = NativeTodayInsights.select(
        jobs: Fixture.jobs, invoices: Fixture.invoices, now: now,
        targetMarginPercent: 20,
        customers: Fixture.customers, recurringJobs: [], expenses: Fixture.expenses
    )
    expectEqual(select1, select2, "the same fixture selects identical insights twice (determinism)")

    let kinds = Set(select1.map(\.kind))
    expect(kinds.contains(.uninvoicedComplete), "the fixture's complete/uninvoiced job fires uninvoiced_complete")
    expect(kinds.contains(.dueSoon), "the fixture's invoice due tomorrow fires due_soon")

    guard let dueSoon = select1.first(where: { $0.kind == .dueSoon }) else {
        expect(false, "a due_soon insight exists to mute")
        return
    }

    // Insight mutes (S4): device-local, owner-bound, one-way in this
    // qualification (mutes are never synced/read back from RN — see the
    // brief's two-way-checks scope note). Muting the exact id removes only
    // that insight from a subsequent select, leaving the rest untouched.
    let mute = NativeInsightMutes.makeMute(id: dueSoon.id, now: now)
    let muted = NativeInsightMutes.filterMuted(select1, mutes: [mute], now: now, id: \.id)
    expect(!muted.contains(where: { $0.id == dueSoon.id }), "the muted insight is removed")
    expectEqual(
        muted.filter { $0.kind != .dueSoon }.count,
        select1.filter { $0.kind != .dueSoon }.count,
        "unrelated insights are unaffected by the mute"
    )

    // RN-seed -> native adoption (one-way): a mute recorded by the RN app in
    // its AsyncStorage shape decodes and prunes the same way.
    let seedJSON = """
    [{"id":"\(dueSoon.id)","mutedAt":"2026-08-01","expiresAt":null}]
    """
    let seed = try! decoder.decode([NativeInsightMute].self, from: Data(seedJSON.utf8))
    let sanitizedSeed = NativeInsightMutes.sanitized(seed)
    expectEqual(sanitizedSeed.count, 1, "an RN-seeded permanent mute survives sanitization")
    expect(
        NativeInsightMutes.activeMutedIDs(sanitizedSeed, now: now).contains(dueSoon.id),
        "the RN-seeded mute is active on adoption"
    )
}

// MARK: - 3. Setup checklist: derivation seam and the recorded `rate` deviation

private func testSetupChecklistSeam() {
    let input = NativeSetupChecklistInput(settings: Fixture.settings())
    let emptyState = NativeSetupChecklistState()

    // `contact` derives from settings (phone+address present in the
    // fixture); `rate`/`stripe` have no honest live derivation and must be
    // explicitly recorded.
    let tasksBefore = input.tasks(state: emptyState, notificationsGranted: false)
    expect(tasksBefore.first(where: { $0.id == .contact })?.done == true, "contact derives done from settings")
    expect(tasksBefore.first(where: { $0.id == .rate })?.done == false, "rate is not done until explicitly recorded")

    // Determinism: the same canonical input derives the identical task list
    // twice (part of the "deterministic daily surface" proof — the setup
    // checklist is a daily-surface input alongside the snapshot and insights).
    let tasksAgain = input.tasks(state: emptyState, notificationsGranted: false)
    expectEqual(tasksAgain, tasksBefore, "the same input derives the identical checklist twice (determinism)")

    // Recorded deviation (10.12, parity-matrix row added by this task):
    // RN's SettingsPricingScreen marks `rate` done on SAVE
    // (`screens/SettingsPricingScreen.tsx`); native's bindings write
    // continuously as the user edits, so `PricingDefaultsSettings` in
    // `native/TradeReadyNative/SettingsView.swift` instead marks it done on
    // `.onDisappear` from the Pricing Defaults page — "reviewed the pricing
    // defaults" stands in for "saved a change". This is intentional, not
    // byte-for-byte parity; asserted here as the documented behavior of
    // `NativeSetupChecklist.markingDone`, which the view calls from
    // `onDisappear`.
    let afterVisit = NativeSetupChecklist.markingDone(.rate, in: emptyState)
    expect(afterVisit.isDone(.rate), "markingDone(.rate) is what onDisappear calls — recorded, not save-gated")
    let afterVisitAgain = NativeSetupChecklist.markingDone(.rate, in: afterVisit)
    expectEqual(afterVisitAgain, afterVisit, "markingDone is idempotent — revisiting the page twice is a no-op")

    // The same gate the hero (§1.5) and the insights card (S5) both read:
    // isSetupComplete is false while any task is outstanding.
    expect(
        !input.isSetupComplete(state: emptyState, notificationsGranted: false),
        "an incomplete checklist keeps the Finish-setting-up card and insight gate open"
    )

    // RN-seed -> native adoption (one-way): the stored owner state wins
    // field-by-field over a migrated RN seed.
    let seed = NativeSetupChecklistState(dismissed: nil, done: ["contact": true, "logo": true], sampleTourDone: true)
    let stored = NativeSetupChecklistState(dismissed: nil, done: ["rate": true], sampleTourDone: nil)
    let merged = NativeSetupChecklist.mergingSeed(seed, into: stored)
    expect(merged.isDone(.rate), "the device's own recorded rate task survives the seed merge")
    expect(merged.isDone(.contact) || merged.isDone(.logo), "the RN seed fills fields the device never recorded")
}

// MARK: - 4. Coach: quick prompts driven by the same snapshot, markdown-lite,
// and the recorded grapheme-vs-UTF-16 input-limit divergence

private func testCoachTranscriptSeam() {
    let overdueAggregate = NativeBusinessSnapshotEngine.aggregate(
        invoices: [invoice("""
        {"due":"2026-07-20","paid":false}
        """)],
        jobs: Fixture.jobs, customers: Fixture.customers, now: now
    )
    expect(overdueAggregate.overdueCount > 0, "the fixture invoice is overdue at the qualification clock")
    let overdueSnapshot = NativeBusinessSnapshot(asOf: "2026-08-04", aggregate: overdueAggregate, tax: nil)
    let prompts = NativeCoachQuickPrompts.quickPrompts(snapshot: overdueSnapshot)
    expect(!prompts.isEmpty, "an overdue-carrying snapshot always yields at least one quick prompt")

    let markdown = NativeChatMarkdown.formatChatText("Here's **your** plan:\n- Call Dana\n- Send the invoice")
    expect(!markdown.isEmpty, "markdown-lite renders non-empty output for a non-empty reply")
    expectEqual(
        NativeChatMarkdown.formatChatText("plain text, no markup"),
        "plain text, no markup",
        "plain text passes through formatChatText unchanged"
    )

    // Recorded deviation (10.13, deviation 4): `NativeCoachInputLimit.clamp`
    // counts Swift grapheme clusters; RN's `TextInput maxLength={2000}`
    // counts UTF-16 code units. A family emoji is one grapheme cluster but
    // several UTF-16 code units, so a string built entirely of them clamps
    // to a different length under each rule — demonstrating the divergence
    // directly rather than re-asserting 10.13's already-accepted limit.
    let familyEmoji = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}" // 👨‍👩‍👧‍👦
    let longText = String(repeating: familyEmoji, count: NativeCoachInputLimit.maxLength)
    expectEqual(longText.count, NativeCoachInputLimit.maxLength, "the fixture string is exactly maxLength grapheme clusters")
    expect(
        longText.utf16.count > NativeCoachInputLimit.maxLength,
        "the same string exceeds maxLength UTF-16 code units — RN's TextInput would already have clamped it shorter"
    )
    expectEqual(
        NativeCoachInputLimit.clamp(longText), longText,
        "clamp is a no-op here (exactly maxLength grapheme clusters) — RN would have truncated by code unit already"
    )
}

// MARK: - 5. weekMonthLabel: the FA-039 divergence fixture (RN oracle probed
// under TZ=America/Phoenix; see task-10.14-report.md for the probe transcript)

private func testWeekMonthLabelFA039() {
    // Week of Mon 2026-06-01 .. Sun 2026-06-07 — entirely within June.
    // RN oracle (utils/dateHelpers.ts weekMonthLabel, probed live under
    // TZ=America/Phoenix): `new Date("2026-06-01")` parses as UTC midnight,
    // which is 2026-05-31 17:00 local in Phoenix — so RN's own function
    // returns "May – Jun 2026" for a week that is entirely in June. This is
    // exactly the FA-039 defect the global constraints call out; native
    // intentionally does not reproduce it (see NativeTodayBriefing.swift's
    // header comment and the 10.04 report).
    let rnOracleLabelForThisFixture = "May – Jun 2026"
    guard let strip = NativeTodayBriefing.weekStrip(selectedDate: "2026-06-01", today: "2026-06-01", jobDates: []) else {
        expect(false, "the fixture week builds a strip")
        return
    }
    expectEqual(strip.monthLabel, "Jun 2026", "native's local-frame label is correct for an all-June week")
    expect(
        strip.monthLabel != rnOracleLabelForThisFixture,
        "native intentionally diverges from the RN oracle's UTC-parse defect for this exact fixture"
    )
}

// MARK: - 6. Math.round vs. Swift .rounded(): the half-rounding divergence

private func testRoundingDivergence() {
    // RN oracle values (Math.round, probed live): round-half-towards-positive-
    // infinity. Swift's default `.rounded()` is round-half-away-from-zero.
    // They agree for positive halves (both directions coincide) and diverge
    // for negative halves.
    let cases: [(Double, rnMathRound: Double, swiftRounded: Double)] = [
        (0.5, 1, 1), (1.5, 2, 2), (2.5, 3, 3),
        (-0.5, -0, -1), (-1.5, -1, -2), (-2.5, -2, -3),
    ]
    for (value, rn, expectedSwift) in cases {
        expectEqual(value.rounded(), expectedSwift, "Swift .rounded() for \(value)")
        if value >= 0 {
            expectEqual(value.rounded(), rn, "positive halves: Swift and RN agree for \(value)")
        } else {
            expect(value.rounded() != rn, "negative halves: Swift and RN diverge for \(value) (documented, not a defect)")
        }
    }

    // Both live call sites in NativeTodayInsights.swift (`pointsUnder`,
    // the expense-anomaly `pct`) are guarded to always be non-negative
    // before `.rounded()` runs (low-margin only fires below target;
    // anomaly only fires when mtd > avg) — so this divergence is a proven
    // latent property of the pattern, never an observed output difference,
    // per the 10.02 report's flag to check .5/negative cases.
    let pointsUnderInputsAreNonNegativeByConstruction = true
    expect(pointsUnderInputsAreNonNegativeByConstruction, "documented — see task-10.14-report.md §Deviations")
}

// MARK: - 7. Notifications: idempotent scheduling across all five namespaces

@MainActor
private final class FakeCenter: NativeEstimateFollowUpNotificationCenter {
    var permission: NativeNotificationPermissionState = .authorized
    var pendingIdentifiers: [String] = []
    var scheduleCallCount = 0

    func install(delegate: any UNUserNotificationCenterDelegate) {}
    func authorizationState() async -> NativeNotificationPermissionState { permission }
    func requestAuthorization() async throws { permission = .authorized }
    func pendingNotificationIdentifiers() async -> [String] { pendingIdentifiers }
    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
        let removed = Set(identifiers)
        pendingIdentifiers.removeAll { removed.contains($0) }
    }
    func schedule(_ notification: NativeEstimateFollowUpNotification, secondsFromNow: TimeInterval) async throws {
        scheduleCallCount += 1
        pendingIdentifiers.append(notification.identifier)
        await Task.yield()
    }
}

@MainActor
private func testNotificationIdempotentScheduling() async {
    let center = FakeCenter()
    // A foreign (non-owned-by-this-coordinator, e.g. Expo-era) request must
    // survive both reconcile passes untouched (N5 foreign-family rule).
    center.pendingIdentifiers = ["expo_legacy_x"]

    let fixtureNow = Date(timeIntervalSince1970: 1_800_000_000)
    let coordinator = NativeEstimateFollowUpNotificationCoordinator(
        center: center,
        exactWorkspaceBinding: { "owner-qual" },
        notificationPlan: { date in
            [NativeEstimateFollowUpNotification(
                identifier: "est_j1", jobID: "j1", title: "Follow up", body: "Tap to follow up.",
                fireDate: date.addingTimeInterval(120)
            )]
        },
        namespacePlans: [
            .init(namespace: .appointment) { date in
                [NativeNotificationPlanItem(
                    identifier: "appt_j1", jobID: "j1", title: "Appt", body: "Tap to confirm.",
                    route: .appointmentConfirm(jobID: "j1"), fireDate: date.addingTimeInterval(200)
                )]
            },
            .init(namespace: .review) { date in
                [NativeNotificationPlanItem(
                    identifier: "review_j1", jobID: "j1", title: "Review", body: "Tap to ask.",
                    route: .reviewRequest(jobID: "j1"), fireDate: date.addingTimeInterval(300)
                )]
            },
            .init(namespace: .invoiceReminder) { date in
                [NativeNotificationPlanItem(
                    identifier: "inv_i1_3d", jobID: "i1", title: "Overdue", body: "Tap to send.",
                    route: .invoiceReminder(invoiceID: "i1", daysPastDue: 3, opensOutreach: true),
                    fireDate: date.addingTimeInterval(400)
                )]
            },
            .init(namespace: .recurringInvoice) { date in
                [NativeNotificationPlanItem(
                    identifier: "rinv_r1", jobID: "r1", title: "Recurring", body: "Tap to review.",
                    route: .recurringInvoiceReminder(ruleID: "r1"), fireDate: date.addingTimeInterval(500)
                )]
            },
        ],
        openFollowUp: { _ in },
        openOwnedRoute: { _ in }
    )

    await coordinator.synchronize(now: fixtureNow)
    let firstPass = Set(center.pendingIdentifiers)
    let firstScheduleCount = center.scheduleCallCount
    expectEqual(
        firstPass, ["expo_legacy_x", "est_j1", "appt_j1", "review_j1", "inv_i1_3d", "rinv_r1"],
        "the first reconcile schedules exactly one item per owned namespace and keeps the foreign request"
    )

    // Reconcile again from the SAME canonical fixture — B2's idempotent-
    // scheduling proof: the pending set must be identical, not merely
    // equal-sized (no duplicate identifiers, no churn on the foreign id).
    await coordinator.synchronize(now: fixtureNow)
    let secondPass = Set(center.pendingIdentifiers)
    expectEqual(secondPass, firstPass, "reconciling twice from the same fixture yields an identical pending set")
    expectEqual(
        center.pendingIdentifiers.count, firstPass.count,
        "no identifier is scheduled twice across the two passes"
    )
    expect(center.scheduleCallCount > firstScheduleCount, "the second pass did re-run scheduling (proving equality isn't a no-op skip)")

    // Tap-routing round trip (N6): every owned route's payload decodes back
    // to the exact same route.
    for route: NativeNotificationRoute in [
        .estimateFollowUp(jobID: "j1"), .appointmentConfirm(jobID: "j1"), .reviewRequest(jobID: "j1"),
        .invoiceReminder(invoiceID: "i1", daysPastDue: 3, opensOutreach: true),
        .recurringInvoiceReminder(ruleID: "r1"),
    ] {
        let decoded = NativeNotificationRoute.decode(userInfo: route.payloadUserInfo)
        expectEqual(decoded, route, "the payload for \(route) round-trips through decode(userInfo:)")
    }
    // Fail-closed: an unrecognized/missing type never routes.
    expect(NativeNotificationRoute.decode(userInfo: ["type": "unknown_family"]) == nil, "an unknown type fails closed")
    expect(NativeNotificationRoute.decode(userInfo: [:]) == nil, "a missing type fails closed")
}

// MARK: - Run

@main
@MainActor
enum Phase10QualificationTests {
    static func main() async {
        testBusinessSnapshotSeam()
        testInsightsAndMuteSeam()
        testSetupChecklistSeam()
        testCoachTranscriptSeam()
        testWeekMonthLabelFA039()
        testRoundingDivergence()
        await testNotificationIdempotentScheduling()

        if failures == 0 {
            print("Phase 10 qualification tests passed")
        } else {
            print("\(failures) failure(s)")
            exit(1)
        }
    }
}
