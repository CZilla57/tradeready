import Foundation

private var failures = 0
private func expect(_ condition: @autoclosure () -> Bool, _ label: String) { if !condition() { failures += 1; print("FAIL: \(label)") } }

private func decodeRule(_ json: String) -> Canonical.RecurringInvoice {
    try! JSONDecoder().decode(Canonical.RecurringInvoice.self, from: Data(json.utf8))
}

private func rule(
    id: String = "rule1", nextDue: String = "2026-09-01", cadence: String = "monthly",
    end: String = "\"never\"", endCount: Int? = nil, autoSend: String = "true", active: Bool = true, occurrences: Int = 0
) -> Canonical.RecurringInvoice {
    let countJSON = endCount.map { ",\"endCount\":\($0)" } ?? ""
    return decodeRule("""
    {"id":"\(id)","customerId":"c1","customerName":"Acme","description":"Maintenance","amount":150,"dueDays":30,"cadence":"\(cadence)","endCondition":\(end)\(countJSON),"occurrenceCount":\(occurrences),"nextDueDate":"\(nextDue)","isActive":\(active ? "true" : "false"),"createdAt":"2026-08-01","autoSendEnabled":\(autoSend)}
    """)
}

private var idCounter = 0
private func makeID() -> String { idCounter += 1; return "inv\(1_000_000_000_000 + idCounter)" }

private func run(
    rules: [Canonical.RecurringInvoice],
    invoices: [Canonical.Invoice] = [],
    today: String = "2026-09-15",
    master: Bool = true
) -> NativeRecurringInvoiceGeneration {
    NativeRecurringInvoices.generate(
        rules: rules,
        invoices: invoices,
        contactsByID: ["c1": NativeRecurringInvoiceContact(email: "amy@acme.test", phone: "555-0100")],
        contactsByName: [:],
        existingNumbers: invoices.map { Optional($0.number) },
        today: today,
        makeInvoiceID: makeID,
        resolveNumber: { "INV-\($0.count + 1)" },
        autoSendMasterEnabled: master,
        stampedAt: "2026-09-15T12:00:00.000Z")
}

// Catch-up: every occurrence due through today generates; numbers span the batch.
var out = run(rules: [rule(nextDue: "2026-07-01")])
expect(out.newInvoices.count == 3, "catch-up generates every elapsed occurrence")
expect(out.newInvoices.map(\.number) == ["INV-1", "INV-2", "INV-3"], "numbers span the working batch")
expect(out.newInvoices.map(\.occurrenceNumber) == [1, 2, 3], "occurrences number in order")
expect(out.newInvoices[0].due == "2026-07-31", "due is occurrence date plus net terms")
expect(out.updatedRules.first?.nextDueDate == "2026-10-01" && out.updatedRules.first?.occurrenceCount == 3,
       "rule advances past generated occurrences")
expect(out.newInvoices.allSatisfy { $0.recurringInvoiceId == "rule1" && !$0.paid }, "linkage and unpaid state")
expect(out.newInvoices.allSatisfy { $0.email == "amy@acme.test" }, "contact snapshot at generation time")
expect(out.autoSendInvoiceIDs.count == 1 && out.autoSendInvoiceIDs[0] == out.newInvoices.last?.id,
       "only the newest occurrence is stamped for auto-send")
expect(out.didChange, "generation reports change")

// Dedupe: an occurrence pulled from another device is never recreated.
let existing = out.newInvoices
idCounter = 0
let deduped = run(rules: [rule(nextDue: "2026-07-01")], invoices: existing)
expect(deduped.newInvoices.isEmpty, "present occurrences are never recreated")
expect(deduped.updatedRules.first?.nextDueDate == "2026-10-01", "rule converges past the shared occurrence")

// Paused rules generate nothing.
let paused = run(rules: [rule(active: false)])
expect(paused.newInvoices.isEmpty && paused.updatedRules.isEmpty && !paused.didChange, "paused rules generate nothing")

// End conditions deactivate.
let byCount = run(rules: [rule(end: "\"count\"", endCount: 2, occurrences: 2)])
expect(byCount.newInvoices.isEmpty && byCount.updatedRules.first?.isActive == false, "met count ends the plan")

// Auto-send gates: rule off, master off, implausible email each withdraw the stamp.
let ruleOff = run(rules: [rule(autoSend: "false")])
expect(ruleOff.autoSendInvoiceIDs.isEmpty && ruleOff.newInvoices.allSatisfy({ $0.autoEmailRequestedAt == nil }),
       "rule opt-out stamps nothing")
let masterOff = run(rules: [rule()], master: false)
expect(masterOff.autoSendInvoiceIDs.isEmpty, "master opt-out stamps nothing")

// Resume fast-forward skips elapsed paused periods without billing them.
let forwarded = RecurrenceRules.fastForwardedInvoiceDate(
    RecurrenceState(endCondition: .never, endCount: nil, endDate: nil, occurrenceCount: 2, nextDueDate: "2026-07-01"),
    cadence: .monthly, through: "2026-09-15")
expect(forwarded == "2026-10-01", "resume skips elapsed periods")

// Local-frame date math and the email gate.
expect(NativeRecurringInvoices.addDays("2026-01-31", days: 30) == "2026-03-02", "due math stays in the local frame")
expect(NativeRecurringInvoices.isPlausibleEmail("amy@acme.test"), "plausible email passes")
expect(!NativeRecurringInvoices.isPlausibleEmail("amy@acme"), "dotless domain fails")
expect(!NativeRecurringInvoices.isPlausibleEmail("a,b@acme.test"), "list separators fail")
expect(!NativeRecurringInvoices.isPlausibleEmail(nil), "missing email fails")

// 7.16 cross-client characterization: two devices generating the same
// occurrence while BOTH offline mint distinct `inv<ms>` IDs, so a later sync
// holds two invoices for occurrence 1. This matches the React Native engine
// exactly (`inv${Date.now()}` — same flaw, same shape), so parity holds, but
// it is a known multi-device limitation: the Phase 12 staging exercise must
// confirm the sequential path (generate-after-pull, which dedupes — proven
// above) dominates in practice, and any deterministic-ID fix must preserve
// issue-date extraction plus RN parity. This test pins the current behavior
// so that fix has a failing-then-passing gate.
do {
    idCounter = 9000
    let shared = rule(nextDue: "2026-09-01")
    let deviceA = run(rules: [shared])
    // A different wall-clock on device B (the production IDs embed `Date.now()`).
    idCounter = 9500
    let deviceB = run(rules: [shared])
    let merged = deviceA.newInvoices + deviceB.newInvoices
    let occurrenceOne = merged.filter { $0.occurrenceNumber == 1 }
    expect(occurrenceOne.count == 2 && occurrenceOne[0].id != occurrenceOne[1].id,
           "simultaneous offline generation diverges (documents the multi-device limit)")
    // Sequential generation after a pull converges: B seeing A's invoice
    // recreates nothing.
    idCounter = 9500
    let sequential = run(rules: [shared], invoices: deviceA.newInvoices)
    expect(sequential.newInvoices.isEmpty, "generate-after-pull converges")
}

// Final review I1: "Cancel plan"/"Delete plan" on the maintenance-plan
// screen. The confirmation dialog's `isPresented` setter clears the tapped
// plan when the dialog dismisses (which it does right after a destructive
// button), so an alert that read that plan always saw nil and silently did
// nothing. The destructive target is its own state and survives the dismissal.
do {
    let tapped = rule(nextDue: "2026-09-01")
    for kind in [NativeRecurringPlanActionState<Canonical.RecurringInvoice>.DestructiveKind.cancelPlan, .deletePlan] {
        var state = NativeRecurringPlanActionState<Canonical.RecurringInvoice>()
        state.showActions(for: tapped)
        expect(state.isDialogPresented && state.isPresentingAnything, "I1 \(kind): the plan actions open")
        state.requestDestructive(kind)
        // SwiftUI then dismisses the dialog through its isPresented setter.
        state.dismissActions()
        expect(!state.isDialogPresented, "I1 \(kind): the dialog is dismissed")
        expect(state.isConfirming(kind), "I1 \(kind): the confirmation alert is presented")
        expect(!state.isConfirming(kind == .cancelPlan ? .deletePlan : .cancelPlan), "I1 \(kind): only its own alert")
        expect(state.pendingDestructive?.rule.id == tapped.id,
               "I1 \(kind): the confirm action receives the tapped plan after the dialog dismissed")
        state.endConfirmation()
        expect(state.pendingDestructive == nil && !state.isPresentingAnything, "I1 \(kind): the target clears when the alert ends")
    }
    // Keep plan: the alert ends without an action; nothing is left presented.
    var kept = NativeRecurringPlanActionState<Canonical.RecurringInvoice>()
    kept.showActions(for: tapped)
    kept.requestDestructive(.deletePlan)
    kept.dismissActions()
    kept.endConfirmation()
    expect(!kept.isPresentingAnything, "I1: Keep plan leaves nothing presented")
    // A destructive request with no open dialog does nothing.
    var idle = NativeRecurringPlanActionState<Canonical.RecurringInvoice>()
    idle.requestDestructive(.cancelPlan)
    expect(idle.pendingDestructive == nil, "I1: no plan, no destructive target")

    // The screen drives both alerts from the surviving target, never from the
    // dialog's plan (which is nil by then).
    let viewURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("TradeReadyNative/NativeRecurringInvoicesView.swift")
    let view = (try? String(contentsOf: viewURL, encoding: .utf8)) ?? ""
    expect(!view.isEmpty, "I1: the plan screen source is readable")
    expect(!view.contains("if let rule = actionRule"), "I1: no alert reads the dialog's (already cleared) plan")
    expect(view.contains("NativeRecurringPlanActionState<Canonical.RecurringInvoice>"), "I1: the screen uses the action state")
    expect(view.contains("presenting: planActions.pendingDestructive"), "I1: the alerts present the destructive target")
}

print(failures == 0 ? "PASS: native recurring invoice tests" : "FAILED: \(failures) native recurring invoice test(s)")
if failures != 0 { exit(1) }
