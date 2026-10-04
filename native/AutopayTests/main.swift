import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Phase 24 §6.3 / §8 (native): the pure autopay policy (status decoding,
// plan status, display strings, the invoice banner, the plan editor's
// availability and notes, the refresh rule) and the owner-route transport
// against an injected loader. Run west of UTC (TZ=America/Phoenix) so a
// due date read in the process zone would shift a day.

private var failures = 0
private func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
    if !condition() { failures += 1; print("FAIL: \(label)") }
}

private func date(_ iso: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: iso)!
}

private let phoenix = TimeZone(identifier: "America/Phoenix")!
private let visa = NativeAutopayCard(brand: "visa", last4: "4242", expMonth: 8, expYear: 2027, wallet: nil)

private func enrollment(
    id: String = "enr-1", plan: String = "plan-1", customer: String? = "cust-1", status: String = "active",
    card: NativeAutopayCard? = visa, max: Decimal? = 120, activated: String? = "2026-10-01T15:00:00Z",
    revoked: String? = nil, by: String? = nil, reason: String? = nil
) -> NativeAutopayEnrollment {
    NativeAutopayEnrollment(
        id: id, recurringInvoiceId: plan, customerId: customer, status: status, card: card, maxAmount: max,
        activatedAt: activated.map(date), revokedAt: revoked.map(date), revokedBy: by, revokeReason: reason)
}

private func charge(_ invoice: String, _ status: String, reason: String? = nil, at: String? = "2026-11-01T14:05:00Z") -> NativeAutopayCharge {
    NativeAutopayCharge(invoiceId: invoice, status: status, amount: 120, failureReason: reason, at: at.map(date))
}

private func invoice(
    _ id: String = "inv-1", plan: String? = "plan-1", due: String = "2026-11-01", balance: Decimal = 120,
    customer: String = "Acme Co", imported: Bool = false
) -> NativeAutopayInvoiceFacts {
    NativeAutopayInvoiceFacts(id: id, recurringInvoiceId: plan, due: due, balanceDue: balance,
                              customerName: customer, isImported: imported)
}

private let offeringPlan = NativeAutopayPlanFacts(id: "plan-1", customerId: "cust-1", autopayEnabled: true)
private let quietPlan = NativeAutopayPlanFacts(id: "plan-1", customerId: "cust-1", autopayEnabled: false)

private func snapshot(_ enrollments: [NativeAutopayEnrollment] = [], _ charges: [NativeAutopayCharge] = []) -> NativeAutopayStatusSnapshot {
    NativeAutopayStatusSnapshot(enrollments: enrollments, charges: charges)
}

// MARK: - Status decoding

private func testParseStatus() {
    let body = Data("""
    {"enrollments":[
      {"id":"enr-1","recurringInvoiceId":"plan-1","customerId":"cust-1","status":"active",
       "card":{"brand":"visa","last4":"4242","expMonth":8,"expYear":2027,"wallet":null},
       "maxAmount":120.1,"activatedAt":"2026-10-01T15:00:00.123456+00:00","revokedAt":null,
       "revokedBy":null,"revokeReason":null,"consentedAt":"2026-10-01T14:59:00Z","futureKey":1},
      {"id":"enr-0","recurringInvoiceId":"plan-1","customerId":"cust-1","status":"revoked","card":null,
       "maxAmount":"100","activatedAt":"2026-09-01","revokedAt":"2026-09-20T10:00:00Z","revokedBy":"customer"},
      {"recurringInvoiceId":"plan-x","status":"active"},
      "not an object"
    ],
    "charges":[
      {"invoiceId":"inv-1","status":"failed","amount":120,"failureReason":"insufficient_funds","at":"2026-11-01T14:05:00.5Z"},
      {"status":"succeeded"}
    ]}
    """.utf8)
    guard let parsed = NativeAutopay.parseStatus(body) else { expect(false, "status body decodes"); return }
    expect(parsed.enrollments.count == 2, "malformed enrollments are skipped, valid ones kept")
    expect(parsed.charges.count == 1, "a malformed charge is skipped")
    let active = parsed.enrollments.first
    expect(active?.card == visa, "the card decodes (a null wallet reads nil)")
    expect(active?.maxAmount == Decimal(string: "120.1"), "a JSON double amount rounds to cents exactly")
    expect(active?.activatedAt.map { abs($0.timeIntervalSince(date("2026-10-01T15:00:00Z")) - 0.123) < 0.001 } == true,
           "six fractional digits (Postgres) parse to the millisecond")
    expect(parsed.enrollments.last?.card == nil && parsed.enrollments.last?.maxAmount == 100,
           "a null card reads nil and a numeric string amount parses")
    expect(parsed.enrollments.last?.activatedAt == date("2026-09-01T00:00:00Z"), "a bare date reads as UTC midnight")
    expect(parsed.charges.first?.failureReason == "insufficient_funds" && parsed.charges.first?.amount == 120,
           "a charge decodes its reason and amount")
    expect(parsed.charges.first?.at == date("2026-11-01T14:05:00Z").addingTimeInterval(0.5), "Z with fractions parses")
    expect(NativeAutopay.parseStatus(Data("{\"enrollments\":[]}".utf8)) == nil, "a body without charges is refused")
    expect(NativeAutopay.parseStatus(Data("[]".utf8)) == nil, "a non-object body is refused")
    expect(NativeAutopay.parseStatus(Data("{\"enrollments\":[],\"charges\":[]}".utf8)) == .empty, "empty arrays decode")
    expect(NativeAutopay.timestamp("2026-02-30") == nil, "an impossible date is refused")

    // The build record's §13.1 example body, verbatim.
    let contract = Data("""
    {
      "enrollments": [
        {
          "id": "6f1c2a4e-1d2b-4c3d-8e9f-0a1b2c3d4e5f",
          "recurringInvoiceId": "ri_abc",
          "customerId": "c_123",
          "status": "active",
          "card": { "brand": "visa", "last4": "4242", "expMonth": 8, "expYear": 2027, "wallet": null },
          "maxAmount": 120,
          "consentedAt": "2026-10-03T18:00:00.000Z",
          "activatedAt": "2026-10-03T18:01:07.000Z",
          "revokedAt": null,
          "revokedBy": null,
          "revokeReason": null
        }
      ],
      "charges": [
        { "invoiceId": "inv_789", "status": "failed", "amount": 120, "failureReason": "card_declined", "at": "2026-11-01T14:00:12.000Z" }
      ]
    }
    """.utf8)
    let decoded = NativeAutopay.parseStatus(contract)
    expect(decoded?.enrollments == [NativeAutopayEnrollment(
        id: "6f1c2a4e-1d2b-4c3d-8e9f-0a1b2c3d4e5f", recurringInvoiceId: "ri_abc", customerId: "c_123", status: "active",
        card: visa, maxAmount: 120, activatedAt: date("2026-10-03T18:01:07Z"), revokedAt: nil, revokedBy: nil, revokeReason: nil)],
           "the §13.1 contract enrollment decodes exactly")
    expect(decoded?.charges == [NativeAutopayCharge(invoiceId: "inv_789", status: "failed", amount: 120,
                                                    failureReason: "card_declined", at: date("2026-11-01T14:00:12Z"))],
           "the §13.1 contract charge decodes exactly")
}

// MARK: - Display strings

private func testDisplayStrings() {
    expect(NativeAutopay.cardShort(visa) == "Visa •••• 4242", "short card")
    expect(NativeAutopay.cardDisplay(visa) == "Visa •••• 4242 · exp 08/27", "spec display string")
    var wallet = visa
    wallet.wallet = "apple_pay"
    expect(NativeAutopay.cardDisplay(wallet) == "Visa •••• 4242 (Apple Pay) · exp 08/27", "a wallet card names the wallet")
    expect(NativeAutopay.cardShort(NativeAutopayCard(brand: "amex", last4: "0005")) == "Amex •••• 0005", "amex")
    expect(NativeAutopay.cardShort(NativeAutopayCard(brand: "mystery", last4: "1111")) == "Card •••• 1111", "unknown brand")
    expect(NativeAutopay.cardShort(NativeAutopayCard(brand: "visa", last4: nil)) == "Visa card", "no last 4")
    expect(NativeAutopay.cardShort(nil) == "Saved card", "no card details at all")
    expect(NativeAutopay.cardShort(NativeAutopayCard(brand: "visa", last4: "42<b>")) == "Visa card", "a non-digit last 4 is dropped")
    expect(NativeAutopay.cardDisplay(NativeAutopayCard(brand: "visa", last4: "4242", expMonth: 13, expYear: 2027))
           == "Visa •••• 4242", "an invalid expiry is omitted")
    expect(NativeAutopay.cardAccessibilityText(visa) == "Visa ending in 4242, expires 08/27", "VoiceOver text has no bullets")
    expect(NativeAutopay.cardAccessibilityText(wallet, includeExpiry: false) == "Visa ending in 4242, Apple Pay",
           "VoiceOver text without expiry")
    expect(NativeAutopay.failureReasonText("insufficient_funds") == "insufficient funds", "insufficient funds")
    expect(NativeAutopay.failureReasonText("do_not_honor") == "card declined", "generic declines read card declined")
    expect(NativeAutopay.failureReasonText(nil) == "card declined", "a missing reason reads card declined")
    expect(NativeAutopay.failureReasonText("EXPIRED_CARD") == "the card has expired", "reasons are case-insensitive")
    expect(NativeAutopay.failureReasonText("authentication_required") == "the bank asked the customer to confirm the payment",
           "authentication required")
    expect(NativeAutopay.failureReasonText("amount_above_authorized") == "the amount is above what the customer authorized",
           "the sweep's amount skip")
    expect(NativeAutopay.dueDisplay("2026-11-01") == "Nov 1, 2026", "a due date never shifts west of UTC")
    expect(NativeAutopay.dueDisplay("soon") == "soon", "a malformed due date is shown as is")
    expect(NativeAutopay.shortDate(date("2026-11-01T06:30:00Z"), timeZone: phoenix) == "Oct 31",
           "a charge time formats in the device zone")
    expect(NativeAutopay.currency(120) == "$120.00", "currency")
}

// MARK: - Plan status and rows

private func testPlanStatus() {
    func status(_ plan: NativeAutopayPlanFacts, invoices: [NativeAutopayInvoiceFacts] = [], _ snap: NativeAutopayStatusSnapshot?) -> NativeAutopayPlanStatus {
        NativeAutopay.planStatus(plan: plan, invoices: invoices, snapshot: snap)
    }
    expect(status(offeringPlan, nil) == .offered, "before any read, an offering plan reads offered")
    expect(status(quietPlan, nil) == .off, "before any read, a quiet plan reads off")
    expect(status(offeringPlan, snapshot()) == .offered, "no enrollment: offered")
    expect(status(offeringPlan, snapshot([enrollment()])) == .on(visa), "an active card on an offering plan: on")
    expect(status(quietPlan, snapshot([enrollment()])) == .paused(visa), "an active card on a quiet plan: paused, still saved")
    expect(status(offeringPlan, snapshot([enrollment(plan: "plan-2")])) == .offered, "another plan's card doesn't count")
    expect(status(offeringPlan, snapshot([enrollment(status: "pending", activated: nil)])) == .offered,
           "a pending checkout isn't a saved card")
    expect(status(offeringPlan, snapshot([enrollment(status: "revoked", activated: nil, revoked: "2026-10-05T00:00:00Z",
                                                     by: "system", reason: "abandoned")])) == .offered,
           "an abandoned checkout never reads as a removed card")
    let removed = enrollment(status: "revoked", revoked: "2026-10-05T00:00:00Z", by: "customer")
    expect(status(offeringPlan, snapshot([removed])) == .removed(by: "customer", reason: nil), "a customer turn-off reads removed")
    expect(status(quietPlan, snapshot([removed])) == .off, "a removed card on a quiet plan reads off")
    expect(status(offeringPlan, snapshot([enrollment(status: "replaced"), enrollment(id: "enr-2")])) == .on(visa),
           "a replaced card is history; the new active one counts")

    let failed = charge("inv-1", "failed", reason: "card_declined")
    let unpaid = [invoice()]
    expect(status(offeringPlan, invoices: unpaid, snapshot([enrollment()], [failed]))
           == .failed(reason: "card_declined", date: date("2026-11-01T14:05:00Z")),
           "a failure on an unpaid plan invoice is the headline")
    expect(status(offeringPlan, invoices: [invoice(balance: 0)], snapshot([enrollment()], [failed])) == .on(visa),
           "once the failed invoice is paid, the row reads on again")
    expect(status(offeringPlan, invoices: [invoice(plan: "plan-9")], snapshot([enrollment()], [failed])) == .on(visa),
           "a charge on another plan's invoice doesn't count")
    expect(status(offeringPlan, invoices: unpaid, snapshot([enrollment(activated: "2026-11-02T00:00:00Z")], [failed])) == .on(visa),
           "a card saved after the failure clears it")
    let hardDecline = enrollment(status: "revoked", revoked: "2026-11-01T14:06:00Z", by: "system", reason: "expired_card")
    expect(status(offeringPlan, invoices: unpaid, snapshot([hardDecline], [charge("inv-1", "failed", reason: "expired_card")]))
           == .failed(reason: "expired_card", date: date("2026-11-01T14:05:00Z")),
           "a hard decline that removed the card still headlines the failure while unpaid")
    expect(status(offeringPlan, invoices: unpaid, snapshot([enrollment()], [charge("inv-1", "skipped", reason: "amount_above_authorized")]))
           == .failed(reason: "amount_above_authorized", date: date("2026-11-01T14:05:00Z")),
           "a skip reads as a failure")

    expect(NativeAutopay.planRowText(.on(visa)) == "Autopay on · Visa •••• 4242", "row: on")
    expect(NativeAutopay.planRowText(.offered) == "Autopay offered", "row: offered")
    expect(NativeAutopay.planRowText(.failed(reason: "card_declined", date: date("2026-11-01T14:05:00Z")), timeZone: phoenix)
           == "Autopay failed Nov 1: card declined", "row: failed (spec copy)")
    expect(NativeAutopay.planRowText(.failed(reason: nil, date: nil)) == "Autopay failed: card declined", "row: failed, no date")
    expect(NativeAutopay.planRowText(.off) == nil, "row: off shows no line")
    expect(NativeAutopay.planRowText(.paused(visa)) == "Autopay not offered · Visa •••• 4242 still saved", "row: paused")
    expect(NativeAutopay.planRowText(.removed(by: "customer", reason: nil)) == "Autopay offered · your customer turned it off",
           "row: removed by the customer")
    expect(NativeAutopay.planRowText(.removed(by: "owner", reason: nil)) == "Autopay offered · you removed the card",
           "row: removed by the owner")
    expect(NativeAutopay.planRowText(.removed(by: "system", reason: "stripe_disconnected"))
           == "Autopay offered · Stripe was disconnected", "row: removed by the system")
    expect(NativeAutopay.planRowText(.removed(by: "system", reason: "hard_decline"))
           == "Autopay offered · the card was declined and removed", "row: a hard decline removed the card")
    expect(NativeAutopay.planRowText(.removed(by: "system", reason: "plan_removed"))
           == "Autopay offered · the card was removed when the plan changed", "row: the plan changed")
    expect(NativeAutopay.planRowText(.removed(by: "system", reason: "something_new"))
           == "Autopay offered · the card was removed", "row: an unknown reason reads as a generic removal")
    expect(NativeAutopay.planRowAccessibilityText(.on(visa)) == "Autopay on, Visa ending in 4242", "row VoiceOver: no bullets")
    expect(NativeAutopay.planRowIsProblem(.failed(reason: nil, date: nil)) && !NativeAutopay.planRowIsProblem(.on(visa)),
           "only a failure reads as a problem")
    expect(NativeAutopayPlanStatus.on(visa).savedCard == visa && NativeAutopayPlanStatus.paused(visa).savedCard == visa
           && NativeAutopayPlanStatus.offered.savedCard == nil, "a saved card is removable when on or paused")

    let marked = snapshot([enrollment(), enrollment(id: "enr-2", plan: "plan-2")])
        .markingRemoved(enrollmentID: "enr-1", at: date("2026-11-03T00:00:00Z"))
    expect(marked.enrollments.first?.status == "revoked" && marked.enrollments.first?.revokedBy == "owner"
           && marked.enrollments.last?.status == "active", "a local remove marks only that card, as the owner")
    expect(status(offeringPlan, marked) == .removed(by: "owner", reason: nil), "after a remove the row reads removed by you")
}

// MARK: - Invoice banner

private func testInvoiceBanner() {
    let now = date("2026-10-20T12:00:00Z")
    let snap = snapshot([enrollment()])
    func banner(_ facts: NativeAutopayInvoiceFacts = invoice(), plan: NativeAutopayPlanFacts? = offeringPlan,
                status: NativeAutopayStatusSnapshot? = nil, now: Date = date("2026-10-20T12:00:00Z")) -> NativeAutopayInvoiceBanner? {
        NativeAutopay.invoiceBanner(invoice: facts, plan: plan, snapshot: status ?? snap, now: now)
    }
    let will = banner()
    expect(will?.text == "Will be charged automatically on Nov 1, 2026 (Visa •••• 4242)", "will charge (spec copy)")
    expect(will?.accessibilityText == "Will be charged automatically on Nov 1, 2026, Visa ending in 4242", "will charge, VoiceOver")
    expect(will?.isProblem == false, "will charge is informational")
    expect(NativeAutopay.invoiceBanner(invoice: invoice(), plan: offeringPlan, snapshot: nil, now: now) == nil,
           "no banner before any status read")
    expect(banner(plan: quietPlan) == nil, "no prediction when the plan stopped offering autopay")
    expect(banner(plan: nil) == nil, "no prediction without the plan row")
    expect(banner(status: snapshot([])) == nil, "no prediction without a saved card")
    expect(banner(plan: NativeAutopayPlanFacts(id: "plan-1", customerId: "cust-2", autopayEnabled: true)) == nil,
           "no prediction when the plan moved to another customer")
    expect(banner(invoice(balance: 0)) == nil, "a paid invoice has no banner")
    expect(banner(invoice(balance: 0.004)) == nil, "a half-cent residue counts as paid")
    expect(banner(invoice(plan: nil)) == nil, "a non-plan invoice has no banner")
    expect(banner(invoice(imported: true)) == nil, "an imported invoice has no banner")
    expect(banner(invoice(due: "2026-09-30"), now: date("2026-09-30T20:00:00Z")) == nil,
           "an invoice due before the card was saved isn't covered")
    expect(banner(invoice(due: "2026-10-01"), now: date("2026-10-01T20:00:00Z")) != nil,
           "an invoice due on the activation day is covered")
    expect(banner(now: date("2026-11-08T14:00:00Z")) != nil, "the window's last instant still predicts a charge")
    expect(banner(now: date("2026-11-08T14:00:01Z")) == nil, "past the 7-day window, no prediction")
    let above = banner(invoice(balance: 150))
    expect(above?.text == "Won't be charged automatically: the balance is above the $120.00 Acme Co authorized. They'll be emailed a payment link instead.",
           "a balance above the authorized amount says so")
    expect(above?.isProblem == true, "above the ceiling is a problem")
    expect(banner(invoice(balance: 120.004)) == will, "a half-cent over the ceiling still charges")

    let failed = banner(status: snapshot([enrollment()], [charge("inv-1", "failed", reason: "card_declined")]))
    expect(failed?.text == "Autopay failed: card declined. Acme Co was emailed a payment link.", "failed (spec copy)")
    expect(failed?.isProblem == true, "a failure is a problem")
    let failedNoCard = NativeAutopay.invoiceBanner(invoice: invoice(), plan: quietPlan,
                                                   snapshot: snapshot([], [charge("inv-1", "failed", reason: "expired_card")]), now: now)
    expect(failedNoCard?.text == "Autopay failed: the card has expired. Acme Co was emailed a payment link.",
           "a failure shows even after the card was removed and the offer turned off")
    let skipped = banner(status: snapshot([enrollment()], [charge("inv-1", "skipped", reason: "amount_above_authorized")]))
    expect(skipped?.text == "Autopay failed: the amount is above what the customer authorized. Acme Co was emailed a payment link.",
           "a skip names the reason")
    let unknown = banner(status: snapshot([enrollment()], [charge("inv-1", "failed", reason: "unknown")]))
    expect(unknown?.text == "Autopay couldn't confirm this charge. Check your Stripe dashboard before collecting payment.",
           "an unknown outcome sends the owner to Stripe")
    let claimed = banner(status: snapshot([enrollment()], [charge("inv-1", "claimed")]))
    expect(claimed?.text == "Autopay charge in progress (Visa •••• 4242)." && claimed?.isProblem == false, "a claimed charge")
    let succeeded = banner(status: snapshot([enrollment()], [charge("inv-1", "succeeded")]))
    expect(succeeded?.text == "Paid automatically. The payment appears here after the next sync.",
           "a charge that succeeded before the ledger synced")
    expect(banner(invoice(balance: 0), status: snapshot([enrollment()], [charge("inv-1", "failed")])) == nil,
           "a failed charge on an invoice paid since has no banner")
    expect(banner(invoice(customer: ""), status: snapshot([enrollment()], [charge("inv-1", "failed")]))?.text
           == "Autopay failed: card declined. Your customer was emailed a payment link.", "no customer name")
}

// MARK: - Plan editor

private func testEditor() {
    func availability(_ provider: String, _ connected: Bool?, _ details: Bool? = true, loading: Bool = false) -> NativeAutopayOfferAvailability {
        NativeAutopay.offerAvailability(paymentProvider: provider, stripeConnected: connected,
                                        stripeDetailsSubmitted: details, stripeStatusLoading: loading)
    }
    expect(availability("stripe", true) == .available, "Stripe connected and selected: available")
    expect(availability("paypal", true) == .needsStripe, "another provider selected: needs Stripe")
    expect(availability("stripe", false) == .needsStripe, "Stripe not connected: needs Stripe")
    expect(availability("stripe", nil, loading: true) == .checking, "status loading: checking")
    expect(availability("stripe", nil) == .needsStripe, "status unknown and not loading: needs Stripe (fail closed)")
    expect(availability("stripe", true, false) == .needsStripeSetup, "details not submitted: finish setup")
    expect(NativeAutopay.offerCaption(.needsStripe) == "Connect Stripe in Settings → Payments to offer autopay.",
           "needs-Stripe caption (spec copy)")
    expect(NativeAutopay.offerCaption(.available) == nil, "no caption when available")
    expect(NativeAutopay.turnOnMessage.hasPrefix("Your customer can choose to save a card when they pay an invoice from this plan"),
           "turn-on confirmation (spec copy)")
    expect(NativeAutopay.turnOffMessage == "Stops automatic charges for this plan. The saved card stays until you or the customer removes it.",
           "turn-off confirmation (spec copy)")

    let active = enrollment()
    expect(NativeAutopay.editNotes(active: nil, newAmount: 500, newCustomerID: "cust-9").isEmpty, "no card, no notes")
    expect(NativeAutopay.editNotes(active: active, newAmount: 120, newCustomerID: "cust-1").isEmpty, "same amount, no note")
    expect(NativeAutopay.editNotes(active: active, newAmount: 100, newCustomerID: "cust-1").isEmpty, "a lower amount needs nothing")
    expect(NativeAutopay.editNotes(active: active, newAmount: 150, newCustomerID: "cust-1").first?.hasPrefix("Above the $120.00 your customer authorized") == true,
           "a higher amount warns it needs new approval")
    expect(NativeAutopay.editNotes(active: active, newAmount: 150, newCustomerID: "cust-2").first?.hasPrefix("Changing the customer removes the saved Visa •••• 4242") == true,
           "a new customer warns the card will be removed")
    expect(NativeAutopay.removeMessage(card: visa, customerName: "Acme Co").hasPrefix("Visa •••• 4242 · exp 08/27 will be removed"),
           "the remove confirmation names the card")
}

// MARK: - Refresh rule

private func testRefreshRule() {
    let fetched = date("2026-10-20T12:00:00Z")
    expect(NativeAutopay.shouldRefresh(.foreground, lastFetchedAt: nil, now: fetched), "foreground with no read yet")
    expect(!NativeAutopay.shouldRefresh(.foreground, lastFetchedAt: fetched, now: fetched.addingTimeInterval(599)),
           "foreground within 10 minutes is skipped")
    expect(NativeAutopay.shouldRefresh(.foreground, lastFetchedAt: fetched, now: fetched.addingTimeInterval(600)),
           "foreground at 10 minutes reads again")
    expect(NativeAutopay.shouldRefresh(.foreground, lastFetchedAt: fetched, now: fetched.addingTimeInterval(-60)),
           "a clock moved backwards reads again")
    expect(NativeAutopay.shouldRefresh(.plansList, lastFetchedAt: fetched, now: fetched), "opening the plans list always reads")
    expect(NativeAutopay.shouldRefresh(.afterRemove, lastFetchedAt: fetched, now: fetched), "after a remove always reads")
}

// MARK: - Transport

private final class RecordingLoader: NativeAutopayHTTPDataLoading, @unchecked Sendable {
    var requests: [URLRequest] = []
    var status: Int
    var body: Data
    var fails = false
    init(status: Int = 200, body: Data = Data("{\"enrollments\":[],\"charges\":[]}".utf8)) {
        self.status = status
        self.body = body
    }
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        if fails { throw URLError(.notConnectedToInternet) }
        return (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

private func testTransport() async {
    let statusURL = URL(string: "https://worker.test/api/autopay/status")!
    let manageURL = URL(string: "https://worker.test/api/autopay/manage")!
    let session = Data("{\"access_token\":\"token\"}".utf8)
    func service(_ loader: RecordingLoader, status: URL = statusURL, manage: URL = manageURL) -> NativeAutopayService {
        NativeAutopayService(statusEndpoint: status, manageEndpoint: manage, loader: loader)
    }
    func error(_ body: () async throws -> Void) async -> NativeAutopayServiceError? {
        do { try await body(); return nil } catch { return error as? NativeAutopayServiceError }
    }
    func check(_ expected: NativeAutopayServiceError?, _ label: String, _ body: () async throws -> Void) async {
        let outcome = await error(body)
        expect(outcome == expected, label)
    }

    let loader = RecordingLoader(body: Data("""
    {"enrollments":[{"id":"enr-1","recurringInvoiceId":"plan-1","status":"active"}],"charges":[]}
    """.utf8))
    let read = try? await service(loader).status(sessionBytes: session)
    expect(read?.enrollments.first?.id == "enr-1", "status decodes through the transport")
    let get = loader.requests.first
    expect(get?.httpMethod == "GET" && get?.url == statusURL, "status is a GET to the status route")
    expect(get?.value(forHTTPHeaderField: "Authorization") == "Bearer token", "status carries the owner's JWT")

    let remover = RecordingLoader(body: Data("{\"ok\":true}".utf8))
    let removeError = await error { try await service(remover).removeCard(enrollmentID: "6f1c2a9e-0d3b-4e8a-9b7c-1a2b3c4d5e6f", sessionBytes: session) }
    expect(removeError == nil, "remove succeeds on 2xx")
    let post = remover.requests.first
    let sent = post?.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] }
    expect(post?.httpMethod == "POST" && post?.url == manageURL, "remove posts to the manage route")
    expect(sent == ["action": "remove", "enrollmentId": "6f1c2a9e-0d3b-4e8a-9b7c-1a2b3c4d5e6f"], "remove body is the §4.8 shape")
    expect(post?.value(forHTTPHeaderField: "Content-Type") == "application/json"
           && post?.value(forHTTPHeaderField: "Authorization") == "Bearer token", "remove headers")

    let bad = RecordingLoader()
    await check(.invalidEnrollmentID, "a malformed enrollment id is refused") { try await service(bad).removeCard(enrollmentID: "../evil", sessionBytes: session) }
    expect(bad.requests.isEmpty, "a refused id sends nothing")
    await check(.rejectedSession, "401 maps to a rejected session (the store retries once)") { _ = try await service(RecordingLoader(status: 401)).status(sessionBytes: session) }
    await check(.rejectedSession, "403 maps to a rejected session") { _ = try await service(RecordingLoader(status: 403)).status(sessionBytes: session) }
    await check(.notFound, "404 maps to not found") { try await service(RecordingLoader(status: 404)).removeCard(enrollmentID: "enr-1", sessionBytes: session) }
    await check(.unavailable, "5xx maps to unavailable") { _ = try await service(RecordingLoader(status: 500)).status(sessionBytes: session) }
    await check(.invalidResponse, "a body without the arrays is an invalid response") { _ = try await service(RecordingLoader(body: Data("{}".utf8))).status(sessionBytes: session) }
    let offline = RecordingLoader()
    offline.fails = true
    await check(.unavailable, "a network error is unavailable") { _ = try await service(offline).status(sessionBytes: session) }
    await check(.malformedSession, "a session without a token is refused") { _ = try await service(RecordingLoader()).status(sessionBytes: Data("{}".utf8)) }
    let queried = URL(string: "https://worker.test/api/autopay/status?x=1")!
    await check(.invalidConfiguration, "an endpoint with a query is refused") { _ = try await service(RecordingLoader(), status: queried).status(sessionBytes: session) }
    let plainHTTP = URL(string: "http://worker.test/api/autopay/status")!
    await check(.invalidConfiguration, "plain http off loopback is refused") { _ = try await service(RecordingLoader(), status: plainHTTP).status(sessionBytes: session) }
    let loopback = URL(string: "http://127.0.0.1:8787/api/autopay/status")!
    await check(nil, "loopback http (Debug) is allowed") { _ = try await service(RecordingLoader(), status: loopback).status(sessionBytes: session) }
}

@main
struct AutopayTests {
    static func main() async {
        testParseStatus()
        testDisplayStrings()
        testPlanStatus()
        testInvoiceBanner()
        testEditor()
        testRefreshRule()
        await testTransport()
        print(failures == 0 ? "PASS: native autopay tests" : "FAILED: \(failures) native autopay test(s)")
        if failures != 0 { exit(1) }
    }
}
