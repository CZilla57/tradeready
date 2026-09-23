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

        if failures == 0 {
            print("PASS: native estimate message drafting tests")
        } else {
            exit(1)
        }
    }
}
