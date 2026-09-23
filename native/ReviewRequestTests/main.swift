import Foundation

// Ports the RN fixture vectors from __tests__/reviewRequest.test.js
// (message rendering, missing-link guard, mark-sent upsert) plus the
// Batch 1 pure-policy contract: complete-transition gating, delay fallback,
// review_ plan item shape, one-shot consumption, live-contact preference,
// and the exact-owner-bound mutable store.

private var failures = 0

private func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
    if !condition() {
        failures += 1
        print("FAIL: \(label)")
    }
}

private let defaultTemplate =
    "Hi {customerName}, thanks for choosing {businessName}! If you were happy with the work, we'd really appreciate a Google review:\n\n{googleReviewLink}\n\nThank you!"

private func record(
    _ jobId: String,
    customerId: String = "c1",
    name: String = "Sam",
    phone: String = "555-0100",
    email: String = "sam@example.com",
    sentAt: String? = nil
) -> NativeReviewRequestRecord {
    NativeReviewRequestRecord(
        jobId: jobId,
        customerId: customerId,
        customerName: name,
        customerPhone: phone,
        customerEmail: email,
        scheduledAt: "2026-07-30T10:00:00.000Z",
        sentAt: sentAt
    )
}

private let bindingA = String(repeating: "a", count: 64)
private let bindingB = String(repeating: "b", count: 64)

@main
enum ReviewRequestTests {
    static func main() {
        // RN parity: reviewMessageMissingLink vectors.
        expect(NativeReviewRequests.messageMissingLink(template: defaultTemplate, googleReviewLink: ""), "missing link when placeholder present and link empty")
        expect(NativeReviewRequests.messageMissingLink(template: defaultTemplate, googleReviewLink: "   "), "missing link when link is only whitespace")
        expect(!NativeReviewRequests.messageMissingLink(template: defaultTemplate, googleReviewLink: "https://g.page/r/abc/review"), "no missing link when a real link is set")
        expect(!NativeReviewRequests.messageMissingLink(template: "Hi {customerName}, thanks for choosing {businessName}! Please leave us a review.", googleReviewLink: ""), "no missing link when the placeholder was removed")

        // RN parity: buildReviewMessage vectors.
        expect(
            NativeReviewRequests.buildMessage(template: defaultTemplate, businessName: "Acme Plumbing", customerName: "Sam", googleReviewLink: "https://g.page/r/abc/review")
                == "Hi Sam, thanks for choosing Acme Plumbing! If you were happy with the work, we'd really appreciate a Google review:\n\nhttps://g.page/r/abc/review\n\nThank you!",
            "substitutes all placeholders when a link is set"
        )
        expect(
            NativeReviewRequests.buildMessage(template: defaultTemplate, businessName: "Acme Plumbing", customerName: "Sam", googleReviewLink: "")
                == "Hi Sam, thanks for choosing Acme Plumbing! If you were happy with the work, we'd really appreciate a Google review\n\nThank you!",
            "empty link leaves no blank hole and trims the dangling colon"
        )
        let emptyLink = NativeReviewRequests.buildMessage(template: defaultTemplate, businessName: "Acme Plumbing", customerName: "Sam", googleReviewLink: "")
        expect(emptyLink.range(of: "\n{3,}", options: .regularExpression) == nil, "empty link never produces three or more consecutive newlines")
        expect(emptyLink.contains("Sam") && emptyLink.contains("Acme Plumbing") && !emptyLink.contains("{"), "names still substitute when the link is empty")

        // Delay: max(1, delayHours || 3) * 3600.
        expect(NativeReviewRequests.delaySeconds(delayHours: nil) == 10_800, "absent delay falls back to 3h")
        expect(NativeReviewRequests.delaySeconds(delayHours: 0) == 10_800, "zero delay falls back to 3h like the RN || coercion")
        expect(NativeReviewRequests.delaySeconds(delayHours: 1) == 3_600, "1h delay")
        expect(NativeReviewRequests.delaySeconds(delayHours: 2) == 7_200, "2h delay")
        expect(NativeReviewRequests.delaySeconds(delayHours: 48) == 172_800, "48h delay")
        expect(NativeReviewRequests.delaySeconds(delayHours: -5) == 3_600, "negative delay floors at 1h")

        // Schedule gating: only a transition into complete, toggle on,
        // contact present, no existing record.
        func schedule(previous: String = "in_progress", enabled: Bool = true, phone: String = "555-0100", email: String = "", existing: Bool = false) -> Bool {
            NativeReviewRequests.shouldSchedule(
                previousStatusRaw: previous, currentStatusRaw: "complete",
                reviewRequestEnabled: enabled, customerPhone: phone,
                customerEmail: email, hasExistingRecord: existing
            )
        }
        expect(schedule(), "complete transition with toggle on and a phone schedules")
        expect(schedule(phone: "", email: "sam@example.com"), "email-only contact schedules")
        expect(!schedule(previous: "complete"), "re-saving an already-complete job does not re-arm")
        expect(!NativeReviewRequests.shouldSchedule(previousStatusRaw: "in_progress", currentStatusRaw: "invoiced", reviewRequestEnabled: true, customerPhone: "555-0100", customerEmail: "", hasExistingRecord: false), "non-complete transitions never schedule")
        expect(!schedule(enabled: false), "toggle off blocks scheduling")
        expect(!schedule(phone: "", email: "  "), "no contact blocks scheduling")
        expect(!schedule(existing: true), "an existing record blocks re-scheduling (one-shot)")

        // Plan item: review_<jobId>, review_request payload, stable fire date.
        let scheduledAt = Date(timeIntervalSince1970: 1_800_000_000)
        let item = NativeReviewRequests.planItem(jobId: "j1", customerName: "Sam", jobTitle: "Faucet swap", scheduledAt: scheduledAt, delayHours: 3)
        expect(item.identifier == "review_j1", "plan identifier is review_<jobId>")
        expect(item.route == .reviewRequest(jobID: "j1"), "plan routes to the review tap destination")
        expect(item.route.namespace.payloadType == "review_request", "plan stamps the review_request payload type")
        expect(item.route.namespace.payloadType == NativeReviewRequests.notificationPayloadType, "payload type matches the policy constant")
        expect(item.title == "Time to ask for a review!", "plan title matches the RN notification")
        expect(item.body == "Send Sam a review request for \"Faucet swap\".", "plan body matches the RN notification")
        expect(item.fireDate == scheduledAt.addingTimeInterval(10_800), "fire date re-derives from scheduledAt plus the shared delay")
        let rebuilt = NativeReviewRequests.planItem(jobId: "j1", customerName: "Sam", jobTitle: "Faucet swap", scheduledAt: scheduledAt, delayHours: nil)
        expect(rebuilt.fireDate == item.fireDate, "absent delay rebuilds the same fire instant")

        // One-shot consumption: only successful/unreportable sends count.
        expect(NativeReviewRequests.consumesOneShot(opened: true, outcome: .sent), "a sent SMS consumes the one-shot")
        expect(NativeReviewRequests.consumesOneShot(opened: true, outcome: .unknown), "an unreportable outcome still counts as sent")
        expect(!NativeReviewRequests.consumesOneShot(opened: true, outcome: .notSent), "cancelling the composer burns nothing")
        expect(!NativeReviewRequests.consumesOneShot(opened: false, outcome: .notSent), "a composer that never opened burns nothing")

        // Contact resolution: live customer preferred, record as fallback.
        let live = NativeReviewRequests.preferredContact(liveName: "Sam", livePhone: "555-0199", liveEmail: "", record: record("j1"))
        expect(live.phone == "555-0199", "a corrected live phone wins over the schedule-time snapshot")
        let fallback = NativeReviewRequests.preferredContact(liveName: "", livePhone: "", liveEmail: "", record: record("j1"))
        expect(fallback == (name: "Sam", phone: "555-0100", email: "sam@example.com"), "the saved record covers a deleted customer row")
        let none = NativeReviewRequests.preferredContact(liveName: "", livePhone: "", liveEmail: "", record: nil)
        expect(none.phone.isEmpty && none.email.isEmpty, "no live contact and no record resolves to nothing to send to")

        // RN parity: recordsMarkingSent vectors (markReviewRequestSent without I/O).
        let now = "2026-08-01T12:00:00.000Z"
        do {
            let out = NativeReviewRequests.recordsMarkingSent([record("j1"), record("j2")], jobId: "j1", fallback: nil, nowISO: now)
            expect(out.count == 2 && out[0].sentAt == now && out[1].sentAt == nil, "sets sentAt on the matching record and leaves others untouched")
        }
        do {
            let out = NativeReviewRequests.recordsMarkingSent(
                [record("j1")], jobId: "j1",
                fallback: NativeReviewRequestFallbackContact(customerId: "c9", customerName: "Pat", customerPhone: "555-0199", customerEmail: "pat@example.com"),
                nowISO: now
            )
            expect(out.count == 1 && out[0].customerId == "c1" && out[0].sentAt == now, "an existing record wins over a provided fallback")
            expect(out[0].customerPhone == "555-0100", "marking sent keeps the schedule-time snapshot (live contact is used at send time)")
        }
        do {
            let out = NativeReviewRequests.recordsMarkingSent(
                [record("j1")], jobId: "j9",
                fallback: NativeReviewRequestFallbackContact(customerId: "c9", customerName: "Pat", customerPhone: "555-0199", customerEmail: "pat@example.com"),
                nowISO: now
            )
            expect(out.count == 2 && out[0].jobId == "j1" && out[0].sentAt == nil && out[1].jobId == "j9" && out[1].sentAt == now, "fallback-create appends alongside other jobs")
        }
        do {
            let out = NativeReviewRequests.recordsMarkingSent(
                [], jobId: "j9",
                fallback: NativeReviewRequestFallbackContact(customerId: "c9", customerName: "Pat", customerPhone: "555-0199", customerEmail: "pat@example.com"),
                nowISO: now
            )
            expect(out.count == 1 && out[0].scheduledAt == now && out[0].sentAt == now, "manual send creates a sent record when none exists")
        }
        do {
            let out = NativeReviewRequests.recordsMarkingSent([record("j1")], jobId: "j9", fallback: nil, nowISO: now)
            expect(out.count == 1 && out[0].jobId == "j1" && out[0].sentAt == nil, "no match and no fallback appends nothing")
        }

        // Store: durable, exact-owner-bound, scrubbed on sign-out.
        do {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            let store = NativeReviewRequestStore(fileURL: dir.appendingPathComponent("review-requests.json"))
            let fresh = try store.load(for: bindingA)
            expect(fresh == [], "a fresh binding loads no records")
            try store.save([record("j2"), record("j1")], for: bindingA)
            let roundTripped = try store.load(for: bindingA)
            expect(roundTripped.map(\.jobId) == ["j1", "j2"], "records round-trip in stable order")
            do {
                _ = try store.load(for: bindingB)
                expect(false, "a different owner binding must not open another owner's records")
            } catch NativeReviewRequestStoreError.accountBindingMismatch {
                expect(true, "a different owner binding must not open another owner's records")
            }
            do {
                _ = try store.load(for: "not-a-binding")
                expect(false, "malformed bindings are rejected")
            } catch NativeReviewRequestStoreError.invalidAccountBinding {
                expect(true, "malformed bindings are rejected")
            }
            // Migration seed: stored owner records win, genuinely new jobs fill in.
            let merged = try store.mergeSeeded(
                [record("j1", phone: "stale"), record("j3", customerId: "c3")],
                for: bindingA
            )
            expect(merged.map(\.jobId) == ["j1", "j2", "j3"], "seeding fills only genuinely new jobs")
            expect(merged.first(where: { $0.jobId == "j1" })?.customerPhone == "555-0100", "stored owner records win over the migration seed")
            try store.removeAll()
            let scrubbed = try store.load(for: bindingA)
            expect(scrubbed == [], "removeAll scrubs the owner ledger (sign-out/account-change)")
        } catch {
            expect(false, "review-request store happy path — \(error)")
        }
        do {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            let store = NativeReviewRequestStore(fileURL: dir.appendingPathComponent("review-requests.json"))
            do {
                try store.save([record(""), record("j1")], for: bindingA)
                expect(false, "blank job identifiers are rejected")
            } catch NativeReviewRequestStoreError.invalidRecord {
                expect(true, "blank job identifiers are rejected")
            }
            do {
                try store.save([record("j1"), record("j1")], for: bindingA)
                expect(false, "duplicate job identifiers are rejected")
            } catch NativeReviewRequestStoreError.invalidRecord {
                expect(true, "duplicate job identifiers are rejected")
            }
        } catch {
            expect(false, "review-request store validation — \(error)")
        }

        if failures == 0 {
            print("PASS: native review request policy and repository tests")
        } else {
            print("FAILED: \(failures) native review request test(s)")
            exit(1)
        }
    }
}
