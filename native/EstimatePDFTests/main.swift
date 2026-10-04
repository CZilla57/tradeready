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

/// Phase 25: a job with three good/better/best tiers (the middle one
/// recommended) and two add-ons, one carrying an internal `cost` that must
/// never reach the customer document. `acceptance` (raw JSON) marks it decided.
private func optionsJob(estimateTotal: String = "1800", acceptance: String? = nil) throws -> Canonical.Job {
    let accepted = acceptance.map { ",\"acceptance\":\($0)" } ?? ""
    let json = """
    {"id":"job-options","customerId":"c1","customerName":"Pat O'Brien","title":"Water heater","description":"","status":"lead","scheduledDate":null,"scheduledStartTime":null,"scheduledEndTime":null,"address":"","estimateTotal":\(estimateTotal),"laborHours":4,"laborRate":100,"materials":[],"materialMarkup":0,"overhead":10,"margin":20,"notes":"","invoiceId":null,"createdAt":"2026-07-01",
     "quoteOptions":{"tiers":[
       {"id":"qt_good","name":"Repair","description":"Replace the thermostat and anode rod.","laborHours":2,"laborRate":100,"materials":[],"materialMarkup":0,"overhead":10,"margin":20,"estimateTotal":450},
       {"id":"qt_better","name":"Standard unit","laborHours":4,"laborRate":100,"materials":[],"materialMarkup":0,"overhead":10,"margin":20,"estimateTotal":1800},
       {"id":"qt_best","name":"High-efficiency unit","description":"Hybrid heat pump water heater.","laborHours":5,"laborRate":100,"materials":[],"materialMarkup":0,"overhead":10,"margin":20,"estimateTotal":2600}
     ],"addOns":[
       {"id":"qa_haul","label":"Haul-away","description":"Remove and recycle the old tank.","price":150,"cost":37.25},
       {"id":"qa_pan","label":"Drain pan","price":45.5}
     ],"recommendedTierId":"qt_better"\(accepted)}}
    """
    return try JSONDecoder().decode(Canonical.Job.self, from: Data(json.utf8))
}

private func review(snapshot: Canonical.EstimateApprovalSnapshot) -> NativeEstimateReviewDraft {
    NativeEstimateReviewDraft(
        jobID: "job-options",
        expectedStatus: .lead,
        snapshot: snapshot,
        customerEmail: "pat@example.test",
        customerPhone: "555-0199",
        customerAddress: "10 Main St",
        businessContactName: "Chad Rector",
        businessPhone: "555-0100",
        businessEmail: "hello@example.test",
        businessAddress: "20 Trade Ave",
        businessLogoReference: nil,
        jobDescription: ""
    )
}

private func optionsDocumentTests() throws {
    let snapshot = try CanonicalUIAdapters.estimateApprovalSnapshot(
        job: try optionsJob(),
        customerName: nil,
        businessName: "Rector Plumbing"
    )
    let document = NativeEstimatePDFDocument(review: review(snapshot: snapshot))
    expect(document.options.map(\.name) == ["Repair", "Standard unit", "High-efficiency unit"],
           "Phase 25: every tier is carried in snapshot order")
    expect(document.options.map(\.isRecommended) == [false, true, false],
           "Phase 25: only the recommended tier is flagged")
    expect(document.options.map(\.total) == [450, 1800, 2600],
           "Phase 25: each option keeps its own frozen total")
    expect(document.options[0].description == "Replace the thermostat and anode rod."
               && document.options[1].description.isEmpty,
           "Phase 25: descriptions carry through and an absent one is empty")
    expect(document.options.allSatisfy { !$0.lineItems.isEmpty }
               && document.options[0].lineItems.first?.label == "Labor (2 hrs @ $100/hr)"
               && document.options[0].lineItems.reduce(Decimal.zero) { $0 + $1.amount } == 450,
           "Phase 25: each option's lines are its own derivation and sum to its total")
    expect(document.addOns == [
        NativeEstimatePDFAddOn(label: "Haul-away", description: "Remove and recycle the old tank.", amount: 150),
        NativeEstimatePDFAddOn(label: "Drain pan", description: "", amount: 45.5)
    ], "Phase 25: add-ons carry label, description and customer price in order")
    expect(Mirror(reflecting: document.addOns[0]).children.compactMap(\.label) == ["label", "description", "amount"]
               && !String(describing: document).contains("37.25"),
           "Phase 25: the add-on's internal cost never reaches the document")
    expect(document.lineItems.map(\.amount) == snapshot.lineItems.map(\.amount) && document.total == 1800,
           "Phase 25: top-level lines and total stay the recommended tier's, as before")

    let acceptedSnapshot = try CanonicalUIAdapters.estimateApprovalSnapshot(
        job: try optionsJob(
            estimateTotal: "1950",
            acceptance: #"{"tierId":"qt_better","addOnIds":["qa_haul"],"total":1950,"acceptedAt":"2026-10-01T12:00:00.000Z","source":"owner"}"#
        ),
        customerName: nil,
        businessName: "Rector Plumbing"
    )
    let accepted = NativeEstimatePDFDocument(review: review(snapshot: acceptedSnapshot))
    expect(accepted.options.isEmpty && accepted.addOns.isEmpty,
           "Phase 25: an accepted estimate prints only the chosen option")
    expect(accepted.total == 1950 && accepted.lineItems.last == NativeEstimatePDFLineItem(label: "Haul-away", amount: 150),
           "Phase 25: the accepted document is one estimate with the accepted add-on as its own line")
}

/// Phase 32 (spec 2026-10-03 §6.6): the frozen valid-until date, its header
/// display and the closing sentence, single and options, dated and undated.
private func validityDocumentTests() throws {
    let single = try approvalSnapshot()
    let undated = NativeEstimatePDFDocument(review: review(snapshot: single))
    expect(undated.validUntil == nil && undated.validUntilDisplay == nil,
           "Phase 32: an undated snapshot has no valid-until date or header line")
    expect(undated.closingNote == "Reply to approve and we'll get you scheduled.",
           "Phase 32: an undated single estimate closes with the call to action alone")

    var datedSingle = single
    datedSingle.validUntil = "2026-11-02"
    datedSingle.validUntilTimeZone = "America/Phoenix"
    let dated = NativeEstimatePDFDocument(review: review(snapshot: datedSingle))
    expect(dated.validUntil == "2026-11-02", "Phase 32: the document carries the snapshot's frozen date")
    expect(dated.validUntilDisplay == "Nov 2, 2026", "Phase 32: the header shows the medium date")
    expect(dated.closingNote == "This estimate is valid until November 2, 2026. Reply to approve and we'll get you scheduled.",
           "Phase 32: a dated single estimate names its date in the closing note")

    let optionsJob = try optionsJob()
    let optionsUndated = NativeEstimatePDFDocument(review: review(snapshot: try CanonicalUIAdapters.estimateApprovalSnapshot(
        job: optionsJob, customerName: nil, businessName: "Rector Plumbing"
    )))
    expect(optionsUndated.closingNote == "Reply with the option you'd like and we'll get you scheduled.",
           "Phase 32: an undated options estimate closes with the option call to action alone")
    let optionsDated = NativeEstimatePDFDocument(review: review(snapshot: try CanonicalUIAdapters.estimateApprovalSnapshot(
        job: optionsJob, customerName: nil, businessName: "Rector Plumbing",
        validUntil: "2027-01-01", validUntilTimeZone: "America/Phoenix"
    )))
    expect(optionsDated.validUntilDisplay == "Jan 1, 2027", "Phase 32: Jan 1 never shifts to Dec 31 west of UTC")
    expect(optionsDated.closingNote == "This estimate is valid until January 1, 2027. Reply with the option you'd like and we'll get you scheduled.",
           "Phase 32: a dated options estimate names its date in the closing note")
    expect(dated != undated, "Phase 32: the date is part of the document's identity")
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
        // Phase 21 (spec 2026-10-02-properties-equipment-design.md §3): the
        // "Service address" line, computed by the store, rides on the draft.
        expect(document.serviceAddress.isEmpty, "Phase 21: no service address unless the draft carries one")
        var atRental = review
        atRental.serviceAddress = "  44 Elm St, Unit B  "
        let rentalDocument = NativeEstimatePDFDocument(review: atRental, issuedAt: issuedAt, calendar: calendar)
        expect(rentalDocument.serviceAddress == "44 Elm St, Unit B" && rentalDocument.customerAddress == "10 Main St",
               "Phase 21: the service address prints beside, not instead of, the customer address")
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
        expect(document.options.isEmpty && document.addOns.isEmpty,
               "Phase 25: a single-total estimate has no option or add-on blocks")

        try optionsDocumentTests()
        try validityDocumentTests()

        if failures == 0 {
            print("PASS: native estimate PDF document tests")
        } else {
            exit(1)
        }
    }
}
