import Foundation

private var failures = 0
private let decoder = JSONDecoder()
private let encoder = JSONEncoder()

private func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
    guard condition() else {
        failures += 1
        print("FAIL: \(label)")
        return
    }
}

private func decimal(_ value: String) -> Decimal {
    Decimal(string: value, locale: Locale(identifier: "en_US_POSIX"))!
}

private func fixture(_ name: String) throws -> [String: Canonical.JSONValue] {
    guard let root = ProcessInfo.processInfo.environment["CANONICAL_FIXTURES_PATH"] else {
        throw NSError(domain: "CanonicalTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing fixture path"])
    }
    let url = URL(fileURLWithPath: root).appendingPathComponent(name)
    return try decoder.decode([String: Canonical.JSONValue].self, from: Data(contentsOf: url))
}

private func field<T: Codable>(_ key: String, from fixture: [String: Canonical.JSONValue], as type: T.Type = T.self) throws -> T {
    guard let value = fixture[key] else { throw NSError(domain: "CanonicalTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing field \(key)"]) }
    return try decoder.decode(T.self, from: encoder.encode(value))
}

private func json<T: Encodable>(_ value: T) throws -> Canonical.JSONValue {
    try decoder.decode(Canonical.JSONValue.self, from: encoder.encode(value))
}

private func object<T: Encodable>(_ value: T) throws -> [String: Canonical.JSONValue] {
    guard case let .object(result) = try json(value) else {
        throw NSError(domain: "CanonicalTests", code: 3, userInfo: [NSLocalizedDescriptionKey: "Expected JSON object"])
    }
    return result
}

private func roundTrip<T: Codable>(
    _ type: T.Type,
    field key: String,
    fixture source: [String: Canonical.JSONValue]
) throws {
    let decoded: T = try field(key, from: source)
    let encoded = try json(decoded)
    expect(encoded == source[key], "\(key) semantic JSON round trip")
}

private func run(_ label: String, _ body: () throws -> Void) {
    do { try body() }
    catch {
        failures += 1
        print("FAIL: \(label) — \(error)")
    }
}

let rich = try! fixture("canonical-rich.json")
let legacy = try! fixture("canonical-legacy.json")
let forward = try! fixture("canonical-forward-compatible.json")
let auxiliary = try! fixture("canonical-auxiliary.json")

// Each persisted record family gets a source-fixture round trip. The expected
// JSON is parsed from the fixture, rather than reconstructed in Swift, so these
// tests catch changes to stored field names, nesting, nulls, and number spelling.
run("rich record families") {
    try roundTrip(Canonical.Job.self, field: "job", fixture: rich)
    try roundTrip(Canonical.JobPhoto.self, field: "jobPhoto", fixture: rich)
    try roundTrip(Canonical.PricebookEntry.self, field: "pricebookEntry", fixture: rich)
    try roundTrip(Canonical.Invoice.self, field: "invoice", fixture: rich)
    try roundTrip(Canonical.Customer.self, field: "customer", fixture: rich)
    try roundTrip(Canonical.Expense.self, field: "expense", fixture: rich)
    try roundTrip(Canonical.Trip.self, field: "trip", fixture: rich)
    try roundTrip(Canonical.BookingRequest.self, field: "bookingRequest", fixture: rich)
    try roundTrip(Canonical.RecurringJob.self, field: "recurringJob", fixture: rich)
    try roundTrip(Canonical.RecurringInvoice.self, field: "recurringInvoice", fixture: rich)
    try roundTrip(Canonical.Settings.self, field: "settings", fixture: rich)
    try roundTrip(Canonical.CustomerNotes.self, field: "customerNotes", fixture: rich)
    // Phase 25: quote options, snapshot.options and approval.selection.
    try roundTrip(Canonical.Job.self, field: "quoteOptionsJob", fixture: rich)
    // Phase 20: forms (an instance and a custom template) and a photo
    // captured from a form item.
    try roundTrip(Canonical.Form.self, field: "form", fixture: rich)
    try roundTrip(Canonical.Form.self, field: "formTemplate", fixture: rich)
    try roundTrip(Canonical.JobPhoto.self, field: "formPhoto", fixture: rich)
    // Phase 33: a campaign with unknown keys at every level.
    try roundTrip(Canonical.Campaign.self, field: "campaign", fixture: rich)
}

// Phase 33 (campaigns spec §2): campaigns, customer tags and the opt-out, a
// job's campaignId and a booking request's campaignCode are typed fields, and
// unknown data survives inside segment, message and every recipient.
run("campaigns decode as typed fields and keep unknown data at every level") {
    let campaign: Canonical.Campaign = try field("campaign", from: rich)
    expect(campaign.status == "sending" && campaign.channelPlan == "text_first" && campaign.code == "04hmasw9nf6yy41j"
           && campaign.frozenOn == "2026-10-03" && campaign.endedAt == nil && campaign.manualExclusions == ["c_removed"],
           "campaign header decodes")
    expect(campaign.preservation.unknownFields["futureCampaignField"] != nil, "campaign unknown field retained")
    expect(campaign.segment.minMonthsSinceService == 6 && campaign.segment.maxMonthsSinceService == nil
           && campaign.segment.jobKeywords == ["furnace"] && campaign.segment.leadSources == ["google", "unknown"]
           && !campaign.segment.excludeMaintenancePlans
           && campaign.segment.preservation.unknownFields["futureSegmentField"] == .string("retain-me"),
           "segment decodes with its unknown field")
    expect(campaign.message.goal == "tune_up" && campaign.message.aiDrafted == true
           && campaign.message.lockedAt == "2026-10-03T15:10:00.000Z"
           && campaign.message.preservation.unknownFields["futureMessageField"] != nil,
           "message decodes with its unknown field")
    expect(campaign.recipients?.map(\.status) == ["sent", "skipped", "pending"]
           && campaign.recipients?[0].repliedOn == "2026-10-04"
           && campaign.recipients?[0].preservation.unknownFields["futureRecipientField"] != nil
           && campaign.recipients?[1].skipReason == "opted_out",
           "recipients decode with their unknown fields")

    var edited = campaign
    edited.recipients?[2].status = "sent"
    edited.recipients?[2].sentAt = "2026-10-03T16:00:00.000Z"
    edited.segment.jobKeywords.append("boiler")
    let encoded = try object(edited)
    guard case let .object(segment)? = encoded["segment"], case let .object(message)? = encoded["message"],
          case let .array(recipients)? = encoded["recipients"], recipients.count == 3,
          case let .object(first) = recipients[0], case let .object(second) = recipients[1]
    else { throw NSError(domain: "CanonicalTests", code: 33) }
    expect(encoded["endedAt"] == .null && encoded["futureCampaignField"] != nil, "an edit keeps the explicit null and unknown field")
    expect(segment["futureSegmentField"] == .string("retain-me") && segment["maxMonthsSinceService"] == .null,
           "an edit keeps the segment's unknown field and explicit null")
    expect(message["futureMessageField"] != nil, "an edit keeps the message's unknown field")
    expect(first["futureRecipientField"] != nil && second["manual"] == .null, "an edit keeps recipient unknown fields and nulls")

    // A minimal row written by an older or newer client decodes with defaults.
    let minimal = try decoder.decode(Canonical.Campaign.self, from: Data(#"{"id":"cmp_x","name":"X","code":"c","createdAt":"t","status":"draft"}"#.utf8))
    let minimalEncoded = try object(minimal)
    expect(minimal.segment == Canonical.Campaign.Segment() && minimal.channelPlan == "text_first"
           && minimalEncoded["segment"] == nil && minimalEncoded["message"] == nil && minimalEncoded["channelPlan"] == nil,
           "absent segment, message and plan decode as defaults and stay absent")
}

run("customer tags, opt-out, job campaignId and booking campaignCode are typed") {
    guard case var .object(customerFields)? = rich["customer"], case var .object(jobFields)? = rich["job"],
          case var .object(requestFields)? = rich["bookingRequest"]
    else { throw NSError(domain: "CanonicalTests", code: 34) }
    let plain: Canonical.Customer = try field("customer", from: rich)
    let plainFields = try object(plain)
    expect(plain.tags == nil && plain.marketingOptOutOn == nil && !plain.isMarketingOptedOut
           && plainFields["tags"] == nil && plainFields["marketingOptOutOn"] == nil && plainFields["marketingOptOutVia"] == nil,
           "a customer without tags or an opt-out stays without the keys")
    customerFields["tags"] = .array([.string("AC"), .string("VIP")])
    customerFields["marketingOptOutOn"] = .string("2026-03-04")
    customerFields["marketingOptOutVia"] = .string("text_stop")
    let tagged = try decoder.decode(Canonical.Customer.self, from: encoder.encode(Canonical.JSONValue.object(customerFields)))
    expect(tagged.tags == ["AC", "VIP"] && tagged.marketingOptOutOn == "2026-03-04" && tagged.marketingOptOutVia == "text_stop"
           && tagged.isMarketingOptedOut && tagged.preservation.unknownFields["tags"] == nil
           && tagged.preservation.unknownFields["marketingOptOutOn"] == nil,
           "tags and the opt-out decode as typed fields (merge copies them)")
    let taggedJSON = try json(tagged)
    expect(taggedJSON == .object(customerFields), "a tagged, opted-out customer round-trips exactly")
    var cleared = tagged
    cleared.tags = nil
    cleared.marketingOptOutOn = nil
    cleared.marketingOptOutVia = nil
    let clearedFields = try object(cleared)
    expect(clearedFields["tags"] == nil && clearedFields["marketingOptOutOn"] == nil, "clearing removes the keys")

    jobFields["campaignId"] = .string("cmp_1")
    let campaignJob = try decoder.decode(Canonical.Job.self, from: encoder.encode(Canonical.JSONValue.object(jobFields)))
    expect(campaignJob.campaignId == "cmp_1" && campaignJob.preservation.unknownFields["campaignId"] == nil,
           "a job's campaignId is typed")
    let campaignJobJSON = try json(campaignJob)
    expect(campaignJobJSON == .object(jobFields), "a campaign job round-trips exactly")
    let plainJob: Canonical.Job = try field("job", from: rich)
    let plainJobFields = try object(plainJob)
    expect(plainJob.campaignId == nil && plainJobFields["campaignId"] == nil, "a job without a campaign stays without the key")

    requestFields["campaignCode"] = .string("04hmasw9nf6yy41j")
    let coded = try decoder.decode(Canonical.BookingRequest.self, from: encoder.encode(Canonical.JSONValue.object(requestFields)))
    expect(coded.campaignCode == "04hmasw9nf6yy41j" && coded.preservation.unknownFields["campaignCode"] == nil,
           "a booking request's campaignCode is typed")
    let codedJSON = try json(coded)
    expect(codedJSON == .object(requestFields), "a coded booking request round-trips exactly")
}

run("forms decode as typed fields and keep unknown data at both levels") {
    let form: Canonical.Form = try field("form", from: rich)
    expect(form.kind == "instance" && form.jobId == "j_20260812_precision"
           && form.templateId == "builtin:electrical-safety" && form.completedAt == nil,
           "form header decodes")
    expect(form.preservation.unknownFields["futureFormField"] != nil, "form unknown field retained")
    expect(form.items.map(\.kind) == ["section", "check", "passFail", "text", "signature"],
           "item kinds decode as raw strings, including one this version does not know")
    expect(form.items[1].checked == true && form.items[1].photoIds == ["p1759420900000_abc"]
           && form.items[1].required == true && form.items[1].photoRequired == true,
           "check responses and flags decode")
    expect(form.items[2].result == "fail" && form.items[2].note == "Two unlabelled breakers"
           && form.items[2].preservation.unknownFields["futureItemField"] == .string("retain-me"),
           "pass/fail result, note and an item unknown field decode")
    expect(form.items[4].preservation.unknownFields["futureSignature"] != nil, "an unknown item kind keeps its data")

    var edited = form
    edited.items[2].result = "pass"
    edited.title = "Panel inspection"
    let encoded = try object(edited)
    guard case let .array(items)? = encoded["items"], items.count == 5,
          case let .object(failItem) = items[2], case let .object(textItem) = items[3]
    else { throw NSError(domain: "CanonicalTests", code: 13) }
    expect(encoded["completedAt"] == .null && encoded["futureFormField"] != nil,
           "editing a form keeps its explicit null and unknown field")
    expect(failItem["futureItemField"] == .string("retain-me") && failItem["result"] == .string("pass"),
           "editing an item keeps its unknown field")
    expect(textItem["photoRequired"] == .null && textItem["required"] == .bool(false),
           "explicit item null and false survive an edit elsewhere")

    let template: Canonical.Form = try field("formTemplate", from: rich)
    expect(template.kind == "template" && template.jobId == nil && template.archivedAt == "2026-10-02T17:00:00.000Z",
           "template decodes without job fields")
    let photo: Canonical.JobPhoto = try field("formPhoto", from: rich)
    expect(photo.formId == "fm1759420800000_k3x9" && photo.formItemId == "fi_2", "a form photo carries its back-references")
    let plainPhoto: Canonical.JobPhoto = try field("jobPhoto", from: rich)
    let plainEncoded = try object(plainPhoto)
    expect(plainPhoto.formId == nil && plainEncoded["formId"] == nil && plainEncoded["formItemId"] == nil,
           "a photo without a form stays without the keys")
}

run("quote options decode as typed fields") {
    let job: Canonical.Job = try field("quoteOptionsJob", from: rich)
    guard let options = job.quoteOptions, let approval = job.approval else {
        throw NSError(domain: "CanonicalTests", code: 11, userInfo: [NSLocalizedDescriptionKey: "quote options job lost its typed fields"])
    }
    expect(options.tiers.map(\.id) == ["qt_repair", "qt_standard"] && options.recommendedTierId == "qt_repair",
           "tiers and recommended tier decode")
    expect(options.tiers[1].estimateTotal == decimal("2336.05") && options.tiers[1].jobCosts?.first?.markupPolicy == "passthrough",
           "tier calculator fields decode with Job's types")
    expect(options.tiers[1].description == nil && options.tiers[1].preservation.unknownFields["futureTierField"] != nil,
           "tier explicit null and unknown field are preserved")
    expect(options.addOns[0].cost == decimal("60") && options.addOns[1].cost == nil && options.addOns[1].description == "Installed and paired.",
           "add-on cost and description decode")
    expect(options.acceptance?.tierId == "qt_standard" && options.acceptance?.addOnIds == ["qa_haul"]
           && options.acceptance?.total == decimal("2486.05") && options.acceptance?.source == "link",
           "acceptance decodes")
    expect(options.preservation.unknownFields["futureOptionsField"] == .string("kept"), "options unknown field retained")
    expect(approval.snapshot.options?.tiers.count == 2 && approval.snapshot.options?.addOns.last?.amount == decimal("49.99")
           && approval.snapshot.options?.tiers[1].description == nil,
           "snapshot options decode")
    expect(approval.selection?.tierName == "Standard unit" && approval.selection?.lineItems.count == 5
           && approval.selection?.total == decimal("2486.05"),
           "approval selection decodes")

    var edited = job
    edited.quoteOptions?.tiers[0].name = "Quick repair"
    let encoded = try object(edited)
    guard case let .object(encodedOptions)? = encoded["quoteOptions"],
          case let .array(tiers)? = encodedOptions["tiers"],
          case let .object(standard)? = tiers.last,
          case let .array(addOns)? = encodedOptions["addOns"],
          case let .object(wifi)? = addOns.last
    else { throw NSError(domain: "CanonicalTests", code: 12) }
    expect(standard["description"] == .null && standard["futureTierField"] != nil && wifi["cost"] == .null,
           "mutating quote options keeps nested explicit nulls and unknown data")

    let legacyJob: Canonical.Job = try field("job", from: legacy)
    let legacyEncoded = try object(legacyJob)
    expect(legacyJob.quoteOptions == nil && legacyEncoded["quoteOptions"] == nil, "a job without options stays without the key")
}

run("legacy compatibility") {
    try roundTrip(Canonical.Job.self, field: "job", fixture: legacy)
    try roundTrip(Canonical.Invoice.self, field: "invoice", fixture: legacy)
    try roundTrip(Canonical.Customer.self, field: "customer", fixture: legacy)
    try roundTrip(Canonical.Expense.self, field: "expense", fixture: legacy)
    try roundTrip(Canonical.BookingRequest.self, field: "bookingRequest", fixture: legacy)
    try roundTrip(Canonical.RecurringJob.self, field: "recurringJob", fixture: legacy)
    try roundTrip(Canonical.RecurringInvoice.self, field: "recurringInvoice", fixture: legacy)
    try roundTrip(Canonical.Settings.self, field: "settings", fixture: legacy)

    let job: Canonical.Job = try field("job", from: legacy)
    expect(job.laborBreakdown == nil && job.jobCosts == nil && job.photos == nil, "legacy job leaves additive optionals absent")
    let invoice: Canonical.Invoice = try field("invoice", from: legacy)
    expect(invoice.payments == nil && invoice.customerId == nil, "legacy invoice leaves additive optionals absent")
    let settings: Canonical.Settings = try field("settings", from: legacy)
    expect(settings.schedule == nil && settings.laborCostRate == nil && settings.bookingLink == nil, "legacy settings leave additive optionals absent")
}

run("plain settings tolerate absent additive and secure fields") {
    guard case var .object(minimalSettings)? = rich["settings"] else {
        throw NSError(domain: "CanonicalTests", code: 10)
    }
    let defaultedKeys = [
        "mileageRate", "providerKey", "providerKeys", "autoOutreachEnabled",
        "autoSendEmailEnabled", "appointmentRemindersEnabled",
        "appointmentConfirmTemplate", "onMyWayTemplate",
        "estimateFollowUpsEnabled", "autoInvoiceOnComplete",
        "autoEmailInvoiceOnComplete", "anthropicKey", "groqKey",
        "reviewRequestEnabled", "reviewRequestTemplate", "googleReviewLink",
        "reviewRequestDelayHours"
    ]
    defaultedKeys.forEach { minimalSettings.removeValue(forKey: $0) }
    var decoded = try decoder.decode(Canonical.Settings.self, from: encoder.encode(minimalSettings))
    expect(decoded.providerKey.isEmpty && decoded.anthropicKey.isEmpty && decoded.groqKey.isEmpty,
           "missing secure settings decode as empty runtime values")
    expect(decoded.estimateFollowUpsEnabled && !decoded.autoInvoiceOnComplete,
           "missing additive flags receive production read defaults")
    let unchanged = try object(decoded)
    expect(unchanged == minimalSettings, "unchanged defaulted fields remain absent on re-encode")
    decoded.autoInvoiceOnComplete = true
    let changed = try object(decoded)
    expect(changed["autoInvoiceOnComplete"] == .bool(true), "changing an absent default materializes the field")
}

run("typed values, precision, and explicit nulls") {
    let job: Canonical.Job = try field("job", from: rich)
    expect(job.status == "estimate_sent", "job status retains wire value")
    expect(job.estimateTotal == decimal("1234.567890123456789"), "job decimal retains precision")
    expect(job.materials[0].unitCost == decimal("43.210987654321"), "nested material decimal retains precision")
    expect(job.laborBreakdown?.nonBillableNote == "Inspection wait", "nested labor breakdown decodes")
    expect(job.changeOrders?[1].amount == decimal("-25.5"), "negative change order decodes")
    expect(job.invoiceId == nil && job.timeSessions?[0].end == nil, "explicit null optionals decode as nil")
    let encoded = try object(job)
    expect(encoded["invoiceId"] == .null, "imported explicit null survives encoding")
    guard case let .array(sessions)? = encoded["timeSessions"], case let .object(first)? = sessions.first else {
        throw NSError(domain: "CanonicalTests", code: 4)
    }
    expect(first["end"] == .null, "nested explicit null survives encoding")

    let invoice: Canonical.Invoice = try field("invoice", from: rich)
    expect(invoice.amount == decimal("1234.567890123456789"), "invoice decimal retains precision")
    expect(invoice.payments?[0].amount == decimal("300.123456789"), "payment decimal retains precision")
    let encodedInvoice = try object(invoice)
    expect(invoice.paidAt == nil && encodedInvoice["paidAt"] == .null, "invoice explicit null survives encoding")
}

run("forward-compatible values and mutations") {
    var job: Canonical.Job = try field("job", from: forward)
    expect(job.status == "server_new_status", "unknown job status remains readable")
    expect(job.jobCosts?[0].category == "carbon_fee" && job.jobCosts?[0].markupPolicy == "server_policy", "unknown job-cost values remain readable")
    expect(job.preservation.unknownFields["futureJobField"] != nil, "unknown job field is retained")
    expect(job.jobCosts?[0].preservation.unknownFields["futureNested"] == .string("discarded"), "unknown nested field is retained")
    job.title = "Owner-edited title"
    job.estimateTotal = decimal("2.000000000000000001")
    let changedJob = try object(job)
    expect(changedJob["title"] == .string("Owner-edited title"), "mutated job string encodes")
    expect(changedJob["estimateTotal"] == .number(decimal("2.000000000000000001")), "mutated job decimal encodes")
    expect(changedJob["futureJobField"] != nil, "mutating a job preserves unknown top-level data")
    guard case let .array(costs)? = changedJob["jobCosts"], case let .object(cost)? = costs.first else {
        throw NSError(domain: "CanonicalTests", code: 5)
    }
    expect(cost["futureNested"] == .string("discarded"), "mutating a job preserves unknown nested data")

    var invoice: Canonical.Invoice = try field("invoice", from: forward)
    expect(invoice.payments?[0].method == "bank_transfer", "unknown payment method remains readable")
    expect(invoice.lineItems?[0].category == "carbon_fee", "unknown invoice category remains readable")
    invoice.desc = "Owner-edited description"
    let changedInvoice = try object(invoice)
    expect(changedInvoice["futureInvoiceField"] == .number(1), "mutating an invoice preserves unknown data")
    guard case let .array(payments)? = changedInvoice["payments"], case let .object(payment)? = payments.first else {
        throw NSError(domain: "CanonicalTests", code: 6)
    }
    expect(payment["futurePaymentField"] == .bool(true), "mutating an invoice preserves unknown nested data")

    var booking: Canonical.BookingRequest = try field("bookingRequest", from: forward)
    expect(booking.status == "queued_by_server", "unknown booking status remains readable")
    expect(booking.history?[0].actor == "automation", "unknown booking actor remains readable")
    booking.details = "Updated"
    let changedBooking = try object(booking)
    expect(changedBooking["futureBookingField"] == .bool(true), "mutating booking preserves unknown data")

    var settings: Canonical.Settings = try field("settings", from: forward)
    expect(settings.trade == "solar" && settings.provider == "wire_transfer", "open settings enum values remain readable")
    settings.businessName = "Updated Future"
    let changedSettings = try object(settings)
    expect(changedSettings["futureSettingsField"] == .bool(true), "mutating settings preserves unknown data")
    guard case let .object(schedule)? = changedSettings["schedule"] else { throw NSError(domain: "CanonicalTests", code: 7) }
    expect(schedule["futureScheduleField"] == .string("ignored"), "mutating settings preserves unknown nested data")
}

run("nil mutation semantics") {
    var richJob: Canonical.Job = try field("job", from: rich)
    richJob.photos = nil
    let afterRemovingPresentValue = try object(richJob)
    expect(afterRemovingPresentValue["photos"] == nil, "setting a present optional to nil removes its key")

    var explicitNullJob: Canonical.Job = try field("job", from: rich)
    explicitNullJob.invoiceId = nil
    let afterKeepingNull = try object(explicitNullJob)
    expect(afterKeepingNull["invoiceId"] == .null, "setting an imported-null optional to nil keeps null")

    var legacyJob: Canonical.Job = try field("job", from: legacy)
    legacyJob.photos = nil
    let afterKeepingAbsent = try object(legacyJob)
    expect(afterKeepingAbsent["photos"] == nil, "setting an absent optional to nil keeps it absent")
}

// Phase 27 (spec 2026-10-02-lead-source-design.md §2-§3): the customer's
// first-touch source and a booking link's `?src=` tag are typed fields.
run("lead source is typed on customers and booking requests") {
    let customer: Canonical.Customer = try field("customer", from: rich)
    let encoded = try object(customer)
    expect(customer.leadSource == "referral", "rich customer lead source decodes")
    expect(customer.preservation.unknownFields["leadSource"] == nil, "lead source is typed, not an unknown field")
    expect(encoded["leadSource"] == .string("referral"), "rich customer lead source encodes")

    var cleared = customer
    cleared.leadSource = nil
    let clearedFields = try object(cleared)
    expect(clearedFields["leadSource"] == nil, "clearing the lead source removes the key")
    var custom = customer
    custom.leadSource = "Home Show"
    let customFields = try object(custom)
    expect(customFields["leadSource"] == .string("Home Show"), "a custom label is written verbatim")

    let legacyCustomer: Canonical.Customer = try field("customer", from: legacy)
    let legacyFields = try object(legacyCustomer)
    expect(legacyCustomer.leadSource == nil && legacyFields["leadSource"] == nil,
           "a customer without a source stays without the key")

    guard case var .object(requestFields)? = rich["bookingRequest"] else {
        throw NSError(domain: "CanonicalTests", code: 13, userInfo: [NSLocalizedDescriptionKey: "Missing booking request"])
    }
    let plain: Canonical.BookingRequest = try field("bookingRequest", from: rich)
    let plainFields = try object(plain)
    expect(plain.leadSource == nil && plainFields["leadSource"] == nil, "a request without a tag stays without the key")
    requestFields["leadSource"] = .string("nextdoor")
    let tagged = try decoder.decode(Canonical.BookingRequest.self, from: encoder.encode(Canonical.JSONValue.object(requestFields)))
    let taggedJSON = try json(tagged)
    expect(tagged.leadSource == "nextdoor" && tagged.preservation.unknownFields["leadSource"] == nil,
           "a booking request's lead source decodes as a typed field")
    expect(taggedJSON == .object(requestFields), "a tagged booking request round-trips exactly")
}

run("versioned envelope") {
    let job: Canonical.Job = try field("job", from: rich)
    var envelope = Canonical.Envelope(schemaVersion: 7, payload: job)
    envelope.preservation.unknownFields["futureEnvelopeField"] = .string("retained")
    let decoded = try decoder.decode(Canonical.Envelope<Canonical.Job>.self, from: encoder.encode(envelope))
    expect(decoded.schemaVersion == 7 && decoded.payload.id == job.id, "versioned envelope retains version and payload")
    expect(decoded.preservation.unknownFields["futureEnvelopeField"] == .string("retained"), "versioned envelope retains unknown data")
}

run("auxiliary model families") {
    try roundTrip(Canonical.AIPricingSuggestion.self, field: "aiPricingSuggestion", fixture: auxiliary)
    try roundTrip(Canonical.JobCostInput.self, field: "jobCostInput", fixture: auxiliary)
    try roundTrip(Canonical.PaymentDraft.self, field: "paymentDraft", fixture: auxiliary)
    try roundTrip(Canonical.ExpenseDraft.self, field: "expenseDraft", fixture: auxiliary)
    try roundTrip(Canonical.PaymentPlan.self, field: "paymentPlan", fixture: auxiliary)
    try roundTrip(Canonical.EstimateInput.self, field: "estimateInput", fixture: auxiliary)
    try roundTrip(Canonical.EstimateBreakdown.self, field: "estimateBreakdown", fixture: auxiliary)
    try roundTrip(Canonical.PriceRange.self, field: "priceRange", fixture: auxiliary)
    try roundTrip(Canonical.JobEstimateBreakdown.self, field: "jobEstimateBreakdown", fixture: auxiliary)

    let input: Canonical.EstimateInput = try field("estimateInput", from: auxiliary)
    guard case .string("2.75")? = input.materials?.first?.quantity else {
        throw NSError(domain: "CanonicalTests", code: 8, userInfo: [NSLocalizedDescriptionKey: "numeric-string material input was not retained"])
    }
    guard case .string("12.345")? = input.jobCosts?.first?.unitCost else {
        throw NSError(domain: "CanonicalTests", code: 9, userInfo: [NSLocalizedDescriptionKey: "numeric-string direct-cost input was not retained"])
    }
}

if failures == 0 {
    print("PASS: native canonical model fixture tests")
} else {
    print("FAILED: \(failures) native canonical model fixture test(s)")
    exit(1)
}
