import Foundation

private var failures = 0

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        failures += 1
        fputs("FAIL: \(message)\n", stderr)
    }
}

private func approvalSnapshot() throws -> Canonical.EstimateApprovalSnapshot {
    let json = """
    {
      "businessName": "Rector Plumbing",
      "customerName": "Pat Lee",
      "jobTitle": "Panel upgrade",
      "lineItems": [
        { "label": "Labor (2 hrs @ $100/hr)", "amount": 200 },
        { "label": "Permit", "amount": 50 },
        { "label": "Overhead & operating costs", "amount": 75 }
      ],
      "total": 325,
      "currency": "USD"
    }
    """
    return try JSONDecoder().decode(Canonical.EstimateApprovalSnapshot.self, from: Data(json.utf8))
}

/// Phase 25: an undecided good/better/best snapshot. The top level mirrors the
/// recommended tier, exactly as `estimateApprovalSnapshot` freezes it.
private func optionsSnapshot(addOns: Bool = true) throws -> Canonical.EstimateApprovalSnapshot {
    let addOnsJSON = addOns
        ? #"[{ "id": "qa_haul", "label": "Haul-away", "description": "Remove the old tank.", "amount": 150 }]"#
        : "[]"
    let json = """
    {
      "businessName": "Rector Plumbing",
      "customerName": "Pat Lee",
      "jobTitle": "Water heater",
      "lineItems": [
        { "label": "Labor (4 hrs @ $100/hr)", "amount": 400 },
        { "label": "Overhead & operating costs", "amount": 1400 }
      ],
      "total": 1800,
      "currency": "USD",
      "options": {
        "tiers": [
          { "id": "qt_good", "name": "Repair", "description": "Replace the thermostat.",
            "lineItems": [
              { "label": "Labor (2 hrs @ $100/hr)", "amount": 200 },
              { "label": "Overhead & operating costs", "amount": 250 }
            ], "total": 450 },
          { "id": "qt_better", "name": "Standard unit",
            "lineItems": [
              { "label": "Labor (4 hrs @ $100/hr)", "amount": 400 },
              { "label": "Overhead & operating costs", "amount": 1400 }
            ], "total": 1800 },
          { "id": "qt_best", "name": "High-efficiency unit",
            "lineItems": [
              { "label": "Labor (5 hrs @ $100/hr)", "amount": 500 },
              { "label": "Overhead & operating costs", "amount": 2100 }
            ], "total": 2600 }
        ],
        "addOns": \(addOnsJSON),
        "recommendedTierId": "qt_better"
      }
    }
    """
    return try JSONDecoder().decode(Canonical.EstimateApprovalSnapshot.self, from: Data(json.utf8))
}

private func review(
    snapshot: Canonical.EstimateApprovalSnapshot,
    businessPhone: String = "555-0100",
    jobDescription: String = "Replace the water heater."
) -> NativeEstimateReviewDraft {
    NativeEstimateReviewDraft(
        jobID: "job-options",
        expectedStatus: .lead,
        snapshot: snapshot,
        customerEmail: "pat@example.test",
        customerPhone: "555-0199",
        customerAddress: "10 Main St",
        businessContactName: "Chad Rector",
        businessPhone: businessPhone,
        businessEmail: "hello@example.test",
        businessAddress: "20 Trade Ave",
        businessLogoReference: nil,
        jobDescription: jobDescription
    )
}

private func optionsDraftTests() throws {
    let link = URL(string: "https://example.test/estimate?j=job-options&t=token")!
    let options = review(snapshot: try optionsSnapshot())
    let withoutPhone = review(snapshot: try optionsSnapshot(), businessPhone: "")
    let withoutAddOns = review(snapshot: try optionsSnapshot(addOns: false))
    let intro = "Hi Pat Lee, Rector Plumbing here. Options for \"Water heater\": "
        + "Repair: $450. Standard unit: $1,800 (recommended). High-efficiency unit: $2,600. "
        + "Add-on Haul-away: +$150."

    expect(NativeEstimateMessageDrafting.prepare(review: options, channel: .text).body
               == intro + " Reply with the option you'd like or call 555-0100.",
           "Phase 25: options text lists every tier, marks the recommended one, adds add-ons and asks for a choice")
    expect(NativeEstimateMessageDrafting.prepare(
               review: withoutPhone,
               channel: .text
           ).body == intro + " Reply with the option you'd like.",
           "Phase 25: options text without a business phone omits the call fallback")
    let linkedText = NativeEstimateMessageDrafting.prepare(review: options, channel: .text, approvalLink: link)
    expect(linkedText.body == intro + " View your options and approve: \(link.absoluteString)",
           "Phase 25: options text with a link points at the options page instead of a reply")
    expect(linkedText.subject.isEmpty, "Phase 25: options text has no hidden subject")
    expect(NativeEstimateMessageDrafting.prepare(
               review: withoutAddOns,
               channel: .text
           ).body == "Hi Pat Lee, Rector Plumbing here. Options for \"Water heater\": "
               + "Repair: $450. Standard unit: $1,800 (recommended). High-efficiency unit: $2,600. "
               + "Reply with the option you'd like or call 555-0100.",
           "Phase 25: options text without add-ons has no add-on entries")

    let email = NativeEstimateMessageDrafting.prepare(review: options, channel: .email, approvalLink: link)
    expect(email.subject == "Estimate for Water heater – Rector Plumbing",
           "Phase 25: options email subject is unchanged")
    expect(email.body == """
        Hi Pat Lee,

        Thank you for reaching out. Here are your options for Water heater:

        Option 1: Repair
        Replace the thermostat.
          Labor (2 hrs @ $100/hr)  $200
          Overhead & operating costs  $250
          ────────────────────────────────────
          OPTION TOTAL  $450

        Option 2: Standard unit (recommended)
          Labor (4 hrs @ $100/hr)  $400
          Overhead & operating costs  $1,400
          ────────────────────────────────────
          OPTION TOTAL  $1,800

        Option 3: High-efficiency unit
          Labor (5 hrs @ $100/hr)  $500
          Overhead & operating costs  $2,100
          ────────────────────────────────────
          OPTION TOTAL  $2,600

        Optional add-ons (added to the option you choose):
          Haul-away  +$150
            Remove the old tank.

        Replace the water heater.

        Reply with the option you'd like, or give me a call.
        I can typically schedule work within a few business days of approval.

        View your options and approve here:
        \(link.absoluteString)

        Best regards,
        Chad Rector
        Rector Plumbing
        555-0100
        """,
           "Phase 25: options email lists each option block, the add-ons and the choice call to action")
    let unlinkedEmail = NativeEstimateMessageDrafting.prepare(review: options, channel: .email)
    expect(!unlinkedEmail.body.contains("View your options") && !unlinkedEmail.body.contains("TOTAL ESTIMATE")
               && !unlinkedEmail.body.contains("To approve this estimate"),
           "Phase 25: options email without a link has no single-estimate total or approve sentence")
}

@main
enum EstimateMessageDraftTests {
    static func main() throws {
        let review = NativeEstimateReviewDraft(
            jobID: "job-message",
            expectedStatus: .lead,
            snapshot: try approvalSnapshot(),
            customerEmail: "pat@example.test",
            customerPhone: "555-0199",
            customerAddress: "10 Main St",
            businessContactName: "Chad Rector",
            businessPhone: "555-0100",
            businessEmail: "hello@example.test",
            businessAddress: "20 Trade Ave",
            businessLogoReference: nil,
            jobDescription: "Replace the existing panel and label every circuit."
        )
        let link = URL(string: "https://example.test/estimate?j=job-message&t=token")!

        let email = NativeEstimateMessageDrafting.prepare(
            review: review,
            channel: .email,
            approvalLink: link
        )
        expect(email.subject == "Estimate for Panel upgrade – Rector Plumbing",
               "email subject is deterministic")
        expect(email.body.contains("Overhead & operating costs"),
               "email retains every reviewed customer-facing line")
        expect(email.body.contains("Replace the existing panel and label every circuit."),
               "email retains the reviewed scope")
        expect(email.body.contains(link.absoluteString),
               "email regeneration retains the approval link")
        expect(email.clipboardText(channel: .email) == "Subject: \(email.subject)\n\n\(email.body)",
               "email copy contains the exact visible subject and body")

        let text = NativeEstimateMessageDrafting.prepare(review: review, channel: .text)
        expect(text.subject.isEmpty, "text draft has no hidden subject")
        expect(!text.body.contains("Overhead & operating costs"),
               "text keeps the compact React Native line-item rule")
        expect(text.body.contains("Permit: $50") && text.body.contains("Total: $325."),
               "text preserves reviewed visible amounts and authoritative total")
        expect(text.body.hasSuffix("Reply YES to approve or call 555-0100."),
               "text uses the saved business phone fallback")
        expect(text.clipboardText(channel: .text) == text.body,
               "text copy contains only the exact visible body")

        let linkedText = NativeEstimateMessageDrafting.prepare(
            review: review,
            channel: .text,
            approvalLink: link
        )
        expect(linkedText.body.contains("View & approve: \(link.absoluteString)"),
               "text regeneration retains the approval link")
        expect(!linkedText.body.contains("Reply YES"),
               "approval link replaces the reply fallback instead of duplicating calls to action")
        expect(linkedText == NativeEstimateMessageDrafting.prepare(
            review: review,
            channel: .text,
            approvalLink: link
        ), "regeneration is deterministic and has no side effects")

        // Phase 25 regression: a snapshot without `options` keeps today's
        // exact copy, byte for byte.
        expect(text.body == "Hi Pat Lee, Rector Plumbing here. Estimate for \"Panel upgrade\": "
                   + "Labor (2 hrs @ $100/hr): $200 Permit: $50 Total: $325. Reply YES to approve or call 555-0100.",
               "Phase 25: single-estimate text is unchanged")
        expect(email.body == """
            Hi Pat Lee,

            Thank you for reaching out. Here's your estimate for Panel upgrade:

              Labor (2 hrs @ $100/hr)  $200
              Permit  $50
              Overhead & operating costs  $75
              ────────────────────────────────────
              TOTAL ESTIMATE  $325

            Replace the existing panel and label every circuit.

            To approve this estimate, simply reply to this email or give me a call.
            I can typically schedule work within a few business days of approval.

            View and approve your estimate here:
            \(link.absoluteString)

            Best regards,
            Chad Rector
            Rector Plumbing
            555-0100
            """,
               "Phase 25: single-estimate email is unchanged")

        try optionsDraftTests()

        if failures == 0 {
            print("PASS: native estimate message drafting tests")
        } else {
            exit(1)
        }
    }
}
