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

print(failures == 0 ? "PASS: native recurring invoice tests" : "FAILED: \(failures) native recurring invoice test(s)")
if failures != 0 { exit(1) }
