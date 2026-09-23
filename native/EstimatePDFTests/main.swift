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
      "customerName": "Pat O'Brien",
      "jobTitle": "Roof / leak: repair",
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
enum EstimatePDFTests {
    static func main() throws {
        let review = NativeEstimateReviewDraft(
            jobID: "job-pdf",
            expectedStatus: .lead,
            snapshot: try approvalSnapshot(),
            customerEmail: "pat@example.test",
            customerPhone: "555-0199",
            customerAddress: "10 Main St",
            businessContactName: "Chad Rector",
            businessPhone: "555-0100",
            businessEmail: "hello@example.test",
            businessAddress: "20 Trade Ave",
            businessLogoReference: "file:///tmp/logo.png",
            jobDescription: "Repair the active roof leak without replacing unrelated decking."
        )
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let issuedAt = Date(timeIntervalSince1970: 1_789_516_800) // 2026-09-16 00:00:00Z
        let document = NativeEstimatePDFDocument(
            review: review,
            issuedAt: issuedAt,
            calendar: calendar
        )

        expect(document.businessName == "Rector Plumbing", "reviewed business name is frozen")
        expect(document.customerEmail == "pat@example.test" && document.customerAddress == "10 Main St",
               "customer contact fields are carried into the document")
        expect(document.businessEmail == "hello@example.test" && document.businessAddress == "20 Trade Ave",
               "business contact fields are carried into the document")
        expect(document.lineItems.count == 3 && document.lineItems[1].amount == 50,
               "all reviewed customer-visible line items remain exact")
        expect(document.total == 325 && document.currency == "USD",
               "reviewed total and currency remain authoritative")
        expect(document.issueDate == "Sep 16, 2026", "issue date uses the injected calendar deterministically")
        expect(document.filename == "Estimate-Roof-leak-repair-Pat-O-Brien.pdf",
               "filename is readable and removes path separators")
        expect(!document.filename.contains("/") && !document.filename.contains(":"),
               "filename cannot escape the export directory")
        expect(NativeEstimatePDFDocument.filenameComponent("  !!!  ").isEmpty,
               "punctuation-only names have a safe empty component")

        if failures == 0 {
            print("PASS: native estimate PDF document tests")
        } else {
            exit(1)
        }
    }
}
