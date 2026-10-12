import Foundation

// Phase 18 (Tap to Pay on iPhone, spec 2026-10-03 §9) host tests: eligibility,
// the amount rules, the ledger entry (the Worker's exact bytes), the transport
// (dollars exactly once, errors, an echoed amount that differs), the capability
// gate, the payment sheet's state machine over `NativeFakeCardReader`, and the
// AppStore's `recordCardPresentPayment` (dedupe, round trip, labels, cash-basis
// and accountant-package inclusion). No network, no SDK. Run with
// TZ=America/Phoenix (the runner defaults it).

// MARK: - Harness

@MainActor var failures = 0
@MainActor var checks = 0

@MainActor
func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
    checks += 1
    if !condition() { failures += 1; print("FAIL: \(label)") }
}

@MainActor
func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ label: String) {
    checks += 1
    if actual != expected { failures += 1; print("FAIL: \(label)\n  expected: \(expected)\n  actual:   \(actual)") }
}

// MARK: - Fakes

final class FakeTerminalService: NativeTerminalServicing, @unchecked Sendable {
    struct Call: Equatable { var invoiceID: String; var amountCents: Int; var localDate: String; var operationID: String; var invoiceNumber: String? = nil }
    private(set) var calls: [Call] = []
    /// Consumed one per call; empty = succeed with a fresh PI for the asked amount.
    var failures: [NativeTerminalError] = []
    var echoAmountOffset = 0
    var intentID = "pi_3Fake000000000001"

    func connectionToken() async throws -> String { "pst_test_token" }
    func locationStatus() async throws -> NativeTerminalLocation { NativeTerminalLocation(locationID: "tml_1") }
    func ensureLocation(displayName: String, address: NativeTerminalAddress) async throws -> NativeTerminalLocation {
        NativeTerminalLocation(locationID: "tml_1")
    }
    /// Set to hold the next `createPaymentIntent` open until `release()` (the
    /// sheet is closed while "Preparing").
    var suspendNext = false
    // `createPaymentIntent` runs off the main actor while the test polls and
    // releases from it, so the suspended flag and the continuation are one
    // locked unit: `isSuspended` is true only once the continuation is stored
    // (otherwise `release()` could find no waiter and the test hangs).
    private let gate = NSLock()
    private var suspended = false
    private var waiter: CheckedContinuation<Void, Never>?
    var isSuspended: Bool { gate.lock(); defer { gate.unlock() }; return suspended }
    func release() {
        gate.lock(); let w = waiter; waiter = nil; suspended = false; gate.unlock()
        w?.resume()
    }

    func createPaymentIntent(invoiceID: String, amountCents: Int, localDate: String, operationID: String, invoiceNumber: String?) async throws -> NativeTerminalPaymentIntent {
        calls.append(Call(invoiceID: invoiceID, amountCents: amountCents, localDate: localDate, operationID: operationID, invoiceNumber: invoiceNumber))
        if suspendNext {
            suspendNext = false
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                gate.lock(); waiter = c; suspended = true; gate.unlock()
            }
        }
        if !failures.isEmpty { throw failures.removeFirst() }
        return NativeTerminalPaymentIntent(
            paymentIntentID: intentID, clientSecret: "\(intentID)_secret_x", amountCents: amountCents + echoAmountOffset)
    }
}

struct StubLoader: NativeStripeConnectHTTPDataLoading {
    let status: Int
    let body: String
    let capture: @Sendable (URLRequest) -> Void
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        capture(request)
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

final class Captured: @unchecked Sendable { var requests: [URLRequest] = [] }

func service(status: Int = 200, body: String, captured: Captured = Captured(), session: Data? = Data(#"{"access_token":"tok"}"#.utf8)) -> NativeTerminalService {
    NativeTerminalService(
        connectionTokenEndpoint: URL(string: "https://worker.test/api/terminal/connection-token")!,
        locationEndpoint: URL(string: "https://worker.test/api/terminal/location")!,
        paymentIntentEndpoint: URL(string: "https://worker.test/api/terminal/payment-intent")!,
        sessionProvider: { session },
        loader: StubLoader(status: status, body: body, capture: { captured.requests.append($0) }))
}

func jsonObject(_ data: Data) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
}

func entryJSON(_ entry: Canonical.Payment) -> [String: Canonical.JSONValue] {
    guard let data = try? JSONEncoder().encode(entry),
          case let .object(fields)? = try? JSONDecoder().decode(Canonical.JSONValue.self, from: data) else { return [:] }
    return fields
}

/// The Worker webhook's entry for the same payment
/// (`backend-workers/tests/terminal.test.cjs`, "exact entry shape").
let webhookEntry: [String: Canonical.JSONValue] = [
    "id": .string("stripe_pi_tap_1"), "amount": .number(120), "date": .string("2026-10-13"),
    "method": .string("stripe"), "stripePaymentIntentId": .string("pi_tap_1"), "channel": .string("card_present"),
]

// MARK: - Pure rules

@MainActor
func pureRules() {
    let connected = NativeStripeConnectStatus(connected: true, detailsSubmitted: true, displayName: "Acme", chargesEnabled: true, cardPaymentsCapability: "active")
    func inel(_ available: Bool = true, _ status: NativeStripeConnectStatus? = connected, _ balance: Int = 12000) -> NativeCardPresentPayment.Ineligibility? {
        NativeCardPresentPayment.ineligibility(capabilityAvailable: available, status: status, invoiceBalanceCents: balance)
    }
    expect(inel() == nil, "eligible: flag on, connected, charges enabled, balance due")
    expectEqual(inel(false), .featureUnavailable, "flag off is never eligible")
    expectEqual(inel(true, nil), .stripeNotConnected, "no status yet")
    expectEqual(inel(true, NativeStripeConnectStatus(connected: false, detailsSubmitted: false, displayName: nil)), .stripeNotConnected, "not connected")
    expectEqual(inel(true, NativeStripeConnectStatus(connected: true, detailsSubmitted: false, displayName: nil, chargesEnabled: true)), .chargesNotEnabled, "details not submitted")
    expectEqual(inel(true, NativeStripeConnectStatus(connected: true, detailsSubmitted: true, displayName: nil)), .chargesNotEnabled, "charges_enabled unknown (older Worker) is not enabled")
    expectEqual(inel(true, NativeStripeConnectStatus(connected: true, detailsSubmitted: true, displayName: nil, chargesEnabled: false)), .chargesNotEnabled, "charges disabled")
    expectEqual(inel(true, NativeStripeConnectStatus(connected: true, detailsSubmitted: true, displayName: nil, chargesEnabled: true, cardPaymentsCapability: "pending")), .chargesNotEnabled, "card_payments capability pending")
    expectEqual(inel(true, connected, 0), .invoicePaid, "a paid invoice has no balance to charge")

    typealias P = NativeCardPresentPayment
    expectEqual(P.validate(amountCents: 12000, balanceCents: 12000), .ok, "the full balance is allowed")
    expectEqual(P.validate(amountCents: 50, balanceCents: 12000), .ok, "a partial amount is allowed (D10), down to the 50-cent minimum")
    expectEqual(P.validate(amountCents: 49, balanceCents: 12000), .belowMinimum, "49 cents is under Stripe's minimum")
    expectEqual(P.validate(amountCents: 1, balanceCents: 12000), .belowMinimum, "one cent is under Stripe's minimum")
    expectEqual(P.validate(amountCents: 30, balanceCents: 30), .belowMinimum, "a balance under 50 cents cannot be taken by card, even in full")
    expectEqual(P.validate(amountCents: 50, balanceCents: 50), .ok, "exactly the minimum, in full")
    expectEqual(P.minimumChargeCents, 50, "USD minimum is 50 cents")
    expect(P.belowMinimumMessage.contains("too small to take by card") && P.belowMinimumMessage.contains("$0.50"), "below-minimum copy")
    expectEqual(P.cleanInvoiceNumber("  INV-0042 "), "INV-0042", "invoice number is trimmed")
    expect(P.cleanInvoiceNumber(nil) == nil && P.cleanInvoiceNumber("  ") == nil && P.cleanInvoiceNumber("a\nb") == nil && P.cleanInvoiceNumber(String(repeating: "x", count: 65)) == nil, "blank, multi-line and oversized numbers are dropped")
    expectEqual(P.validate(amountCents: 12001, balanceCents: 12000), .exceedsBalance(balanceCents: 12000), "one cent over the balance is refused")
    expectEqual(P.validate(amountCents: 0, balanceCents: 12000), .notPositive, "zero refused")
    expectEqual(P.validate(amountCents: -500, balanceCents: 12000), .notPositive, "negative refused")
    expectEqual(P.validate(amountCents: 100, balanceCents: 0), .exceedsBalance(balanceCents: 0), "nothing due refuses any amount")
    expectEqual(P.validate(amountCents: P.maxChargeCents + 1, balanceCents: P.maxChargeCents + 100), .tooLarge, "Stripe's ceiling")

    expectEqual(P.cents(fromDollars: 125.5), 12550, "125.50 is 12550 cents")
    expectEqual(P.cents(fromDollars: 0.1 + 0.2), 30, "float noise from sums reads as whole cents")
    expectEqual(P.cents(fromDollars: 19.99), 1999, "19.99")
    expect(P.cents(fromDollars: 12.345) == nil, "a fractional cent is refused, not rounded into a charge")
    expect(P.cents(fromDollars: -1) == nil && P.cents(fromDollars: .nan) == nil, "negative and NaN refused")

    let op = P.newOperationID()
    expect(P.isValidOperationID(op) && op.count == 36, "minted operation id matches the Worker's [A-Za-z0-9_-]{8,64}")
    expect(!P.isValidOperationID("short") && !P.isValidOperationID("has space in it 12"), "bad operation ids rejected")
    expect(P.newOperationID() != op, "operation ids are unique")
    expect(P.isValidPaymentIntentID("pi_3Q4abc") && !P.isValidPaymentIntentID("cs_123") && !P.isValidPaymentIntentID("pi_"), "payment intent id shape")

    var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(identifier: "UTC")!
    var phoenix = Calendar(identifier: .gregorian); phoenix.timeZone = TimeZone(identifier: "America/Phoenix")!
    let lateEvening = ISO8601DateFormatter().date(from: "2026-10-14T03:30:00Z")!  // Oct 13, 8:30 PM in Phoenix
    expectEqual(P.localDate(lateEvening, calendar: phoenix), "2026-10-13", "the payment date is the device's local day (D5)")
    expectEqual(P.localDate(lateEvening, calendar: utc), "2026-10-14", "...not the UTC day")
    expect(P.isValidLocalDate("2026-10-13") && !P.isValidLocalDate("2026-02-30") && !P.isValidLocalDate("2026-1-13"), "local date shape")
}

// MARK: - Ledger entry

@MainActor
func ledgerEntry() {
    typealias P = NativeCardPresentPayment
    do {
        let entry = try P.ledgerEntry(paymentIntentId: "pi_tap_1", amountCents: 12000, localDate: "2026-10-13")
        expectEqual(entryJSON(entry), webhookEntry, "the device entry equals the Worker webhook's entry (byte-identical fields)")
        expectEqual(Set(entryJSON(entry).keys), ["id", "amount", "date", "method", "stripePaymentIntentId", "channel"], "exactly the six keys: no note or voidedAt nulls")
        let fractional = try P.ledgerEntry(paymentIntentId: "pi_3Q4", amountCents: 41250, localDate: "2026-10-14")
        expectEqual(entryJSON(fractional)["amount"], .number(Decimal(string: "412.5")!), "41250 cents is exactly 412.5")
        expectEqual(entryJSON(fractional)["id"], .string("stripe_pi_3Q4"), "ledger id is stripe_<pi>")
        let text = String(decoding: try JSONEncoder().encode(fractional), as: UTF8.self)
        expect(text.contains("412.5") && !text.contains("41250"), "the encoded amount is dollars, written exactly")
    } catch { expect(false, "ledger entry threw \(error)") }
    for (label, make) in [
        ("bad intent id", { try P.ledgerEntry(paymentIntentId: "cs_1", amountCents: 100, localDate: "2026-10-13") }),
        ("zero amount", { try P.ledgerEntry(paymentIntentId: "pi_1", amountCents: 0, localDate: "2026-10-13") }),
        ("bad date", { try P.ledgerEntry(paymentIntentId: "pi_1", amountCents: 100, localDate: "13/10/2026") }),
    ] as [(String, () throws -> Canonical.Payment)] {
        expect((try? make()) == nil, "ledger entry refuses a \(label)")
    }

    expectEqual(P.displayLabel(method: "stripe", channel: "card_present"), "Tap to Pay", "label: Tap to Pay")
    expectEqual(P.displayLabel(method: "stripe", channel: nil), "Card (online)", "label: link payment")
    expectEqual(P.displayLabel(method: "cash", channel: nil), "cash", "label: other methods unchanged")
    expectEqual(NativeInvoicePDFDocument.methodLabel("stripe"), "Card", "PDF label stays Card for a Stripe payment")
    expect(P.isStripePayment(id: "stripe_pi_1") && !P.isStripePayment(id: "pay_1"), "void notice applies to stripe_ ids")
    expect(P.voidNotice.contains("doesn't refund"), "void copy says voiding is not a refund")
}

// MARK: - Transport

@MainActor
func transport() async {
    let captured = Captured()
    let ok = service(body: #"{"paymentIntentId":"pi_3Q4","clientSecret":"pi_3Q4_secret_a","amount":412.5,"amountCents":41250}"#, captured: captured)
    do {
        let intent = try await ok.createPaymentIntent(invoiceID: "inv1", amountCents: 41250, localDate: "2026-10-14", operationID: "ttp_abcdefgh12345678", invoiceNumber: " INV-0042 ")
        expectEqual(intent, NativeTerminalPaymentIntent(paymentIntentID: "pi_3Q4", clientSecret: "pi_3Q4_secret_a", amountCents: 41250), "intent decodes")
        let request = captured.requests.first
        expectEqual(request?.httpMethod, "POST", "POST")
        expectEqual(request?.value(forHTTPHeaderField: "Authorization"), "Bearer tok", "bearer token")
        let raw = String(decoding: request?.httpBody ?? Data(), as: UTF8.self)
        expect(raw.contains("\"amount\":412.5"), "amount goes out as exact DOLLARS (412.5), converted once: \(raw)")
        expect(!raw.contains("41250"), "no cents value leaks into the body")
        let body = jsonObject(request?.httpBody ?? Data())
        expectEqual(body["invoiceId"] as? String, "inv1", "invoiceId")
        expectEqual(body["operationId"] as? String, "ttp_abcdefgh12345678", "operationId")
        expectEqual(body["localDate"] as? String, "2026-10-14", "localDate")
        expectEqual(Set(body.keys), ["invoiceId", "amount", "localDate", "operationId", "invoiceNumber"], "no client-authored metadata or account id")
        expectEqual(body["invoiceNumber"] as? String, "INV-0042", "the frozen invoice number goes out clean")
    } catch { expect(false, "payment intent threw \(error)") }

    let small = Captured()
    _ = try? await service(body: #"{"paymentIntentId":"pi_1","clientSecret":"s","amountCents":5}"#, captured: small)
        .createPaymentIntent(invoiceID: "i", amountCents: 5, localDate: "2026-10-14", operationID: "ttp_abcdefgh12345678", invoiceNumber: nil)
    let smallBody = String(decoding: small.requests.first?.httpBody ?? Data(), as: UTF8.self)
    expect(smallBody.contains("\"amount\":0.05"), "5 cents is 0.05 dollars")
    expect(!smallBody.contains("invoiceNumber"), "no invoice number key when there is none")

    func failure(_ svc: NativeTerminalService, amount: Int = 100, op: String = "ttp_abcdefgh12345678", date: String = "2026-10-14") async -> NativeTerminalError? {
        do { _ = try await svc.createPaymentIntent(invoiceID: "inv1", amountCents: amount, localDate: date, operationID: op, invoiceNumber: nil); return nil }
        catch { return error as? NativeTerminalError }
    }
    expectEqual(await failure(service(body: #"{"paymentIntentId":"pi_1","clientSecret":"s","amountCents":101}"#)), .amountMismatch, "an echoed amount that differs is refused")
    expectEqual(await failure(service(body: #"{"paymentIntentId":"cs_1","clientSecret":"s","amountCents":100}"#)), .invalidResponse, "a non-PaymentIntent id is refused")
    expectEqual(await failure(service(body: "{}")), .invalidResponse, "an empty body is refused")
    expectEqual(await failure(service(status: 401, body: #"{"code":"unauthorized"}"#)), .rejectedSession, "401 -> rejectedSession")
    expectEqual(await failure(service(status: 422, body: #"{"code":"not_synced"}"#)), .notSynced, "422 not_synced")
    expectEqual(await failure(service(status: 422, body: #"{"code":"no_connected_account"}"#)), .noConnectedAccount, "422 no_connected_account")
    expectEqual(await failure(service(status: 404, body: #"{"code":"not_found"}"#)), .notFound, "404")
    expectEqual(await failure(service(status: 400, body: #"{"code":"below_minimum","minimum":0.5}"#)), .belowMinimum, "400 below_minimum")
    expectEqual(await failure(service(status: 409, body: #"{"code":"operation_conflict"}"#)), .operationConflict, "409")
    expectEqual(await failure(service(status: 429, body: #"{"code":"rate_limited"}"#)), .rateLimited, "429")
    expectEqual(await failure(service(status: 400, body: #"{"code":"amount_exceeds_balance","balance":80.5}"#)), .amountExceedsBalance(balanceCents: 8050), "400 amount_exceeds_balance carries the balance in cents")
    expectEqual(await failure(service(status: 500, body: "boom")), .serverError, "500")
    expectEqual(await failure(service(body: "{}", session: nil)), .malformedSession, "no session")
    expectEqual(await failure(service(body: "{}"), amount: 0), .invalidRequest, "zero amount never leaves the device")
    expectEqual(await failure(service(body: "{}"), op: "bad"), .invalidRequest, "bad operation id never leaves the device")
    expectEqual(await failure(service(body: "{}"), date: "tomorrow"), .invalidRequest, "bad date never leaves the device")

    if let token = try? await service(body: #"{"secret":"pst_test_x"}"#).connectionToken() { expectEqual(token, "pst_test_x", "connection token") }
    else { expect(false, "connection token threw") }
    let loc = Captured()
    let location = try? await service(body: #"{"locationId":"tml_9","address":null}"#, captured: loc)
        .ensureLocation(displayName: "Acme", address: NativeTerminalAddress(line1: "1 Main", line2: nil, city: "Phoenix", state: "AZ", postalCode: "85001"))
    expectEqual(location?.locationID, "tml_9", "location ensure decodes")
    let locBody = jsonObject(loc.requests.first?.httpBody ?? Data())
    expectEqual(locBody["action"] as? String, "ensure", "location action")
    expectEqual((locBody["address"] as? [String: Any])?["country"] as? String, "US", "location country")
    expectEqual((locBody["address"] as? [String: Any])?["postal_code"] as? String, "85001", "location postal_code key")

    // The connect-status additive fields.
    let status = try? await NativeStripeConnectService(
        statusEndpoint: URL(string: "https://worker.test/api/stripe/connect-status")!,
        connectEndpoint: URL(string: "https://worker.test/api/stripe/create-connect-account")!,
        disconnectEndpoint: URL(string: "https://worker.test/api/stripe/disconnect")!,
        loader: StubLoader(status: 200, body: #"{"connected":true,"details_submitted":true,"display_name":"Acme","charges_enabled":true,"card_payments_capability":"active"}"#, capture: { _ in })
    ).status(sessionBytes: Data(#"{"access_token":"tok"}"#.utf8))
    expectEqual(status?.chargesEnabled, true, "connect-status charges_enabled decodes")
    expectEqual(status?.cardPaymentsCapability, "active", "connect-status card_payments_capability decodes")
}

// MARK: - Capability

@MainActor
func capability() {
    typealias C = NativeTapToPayCapability
    func cap(_ flag: Bool, _ sdk: Bool, _ device: Bool, _ owner: Bool) -> Bool {
        C(buildFlagEnabled: flag, sdkLinked: sdk, deviceSupported: device, ownerEnabled: owner).isAvailable
    }
    var combos = 0
    for mask in 0..<16 {
        let flags = (0..<4).map { mask & (1 << $0) != 0 }
        combos += 1
        expectEqual(cap(flags[0], flags[1], flags[2], flags[3]), mask == 15, "available only when all four hold (mask \(mask))")
    }
    expectEqual(combos, 16, "all 16 capability combinations covered")
    expect(!C.buildFlag(infoDictionary: nil) && !C.buildFlag(infoDictionary: [:]), "an absent Info.plist key means off")
    expect(C.buildFlag(infoDictionary: ["TradeReadyTapToPayEnabled": true]) && C.buildFlag(infoDictionary: ["TradeReadyTapToPayEnabled": "YES"]), "YES enables")
    expect(!C.buildFlag(infoDictionary: ["TradeReadyTapToPayEnabled": "NO"]) && !C.buildFlag(infoDictionary: ["TradeReadyTapToPayEnabled": 7]), "NO and junk stay off")
    expect(!C.sdkLinkedInThisBuild, "no SDK is linked in this build")
    let defaults = UserDefaults(suiteName: "tap-to-pay-tests-\(UUID().uuidString)")!
    let preference = NativeTapToPayPreference(defaults: defaults)
    expect(!preference.isEnabled, "the owner opt-in defaults to off")
    preference.isEnabled = true
    expect(NativeTapToPayPreference(defaults: defaults).isEnabled, "the opt-in persists")
    let live = C.current(reader: NativeUnavailableCardReader(), preference: preference, infoDictionary: ["TradeReadyTapToPayEnabled": "YES"])
    expect(!live.isAvailable && !live.sdkLinked && !live.deviceSupported, "this build is never available: no SDK, unsupported reader")
}

// MARK: - Sheet state machine

@MainActor
final class FlowRig {
    let service = FakeTerminalService()
    let reader = NativeFakeCardReader()
    var balance: Int? = 12000
    var saved: [Canonical.Payment] = []
    var saveSucceeds = true
    var operationCounter = 0
    var number: String? = "INV-0042"
    lazy var flow = NativeTapToPayFlow(
        invoiceID: "inv1", service: service, reader: reader,
        balanceCents: { [unowned self] in self.balance },
        record: { [unowned self] entry in
            if self.saveSucceeds { self.saved.append(entry) }
            return self.saveSucceeds
        },
        invoiceNumber: { [unowned self] in self.number },
        today: { "2026-10-13" },
        makeOperationID: { [unowned self] in self.operationCounter += 1; return "ttp_operation_\(self.operationCounter)" })
}

@MainActor
func sheetStateMachine() async {
    do { // Approved
        let r = FlowRig(); r.reader.approveAmountCents = 12000
        await r.flow.start(amountCents: 12000)
        expectEqual(r.flow.phase, .approved(.init(paymentIntentID: "pi_3Fake000000000001", amountCents: 12000, recorded: true, amountDiffersFromRequest: false)), "approved and recorded")
        expectEqual(r.saved.count, 1, "one ledger entry saved")
        expectEqual(entryJSON(r.saved[0])["id"], .string("stripe_pi_3Fake000000000001"), "saved under stripe_<pi>")
        expectEqual(entryJSON(r.saved[0])["date"], .string("2026-10-13"), "saved with the operation's local day")
        expectEqual(r.service.calls, [.init(invoiceID: "inv1", amountCents: 12000, localDate: "2026-10-13", operationID: "ttp_operation_1", invoiceNumber: "INV-0042")], "one PaymentIntent request")
        expectEqual(r.reader.collectedSecrets, ["pi_3Fake000000000001_secret_x"], "the reader got the client secret")
        await r.flow.start(amountCents: 12000)
        expectEqual(r.service.calls.count, 1, "an approved flow is terminal: a second tap does not charge again")
        expectEqual(r.reader.collectedSecrets.count, 1, "...and the reader is not asked again")
    }
    do { // Partial amount
        let r = FlowRig(); r.reader.approveAmountCents = 5000
        await r.flow.start(amountCents: 5000)
        if case .approved(let a) = r.flow.phase { expectEqual(a.amountCents, 5000, "a deposit books the partial amount") } else { expect(false, "partial approved") }
    }
    do { // Declined, then retry reuses the operation id
        let r = FlowRig(); r.reader.approveAmountCents = 12000
        r.reader.outcomes = [.result(.declined(reason: "card_declined"))]
        await r.flow.start(amountCents: 12000)
        expectEqual(r.flow.phase, .declined(reason: "card_declined"), "declined")
        expectEqual(r.saved.count, 0, "a decline books nothing")
        await r.flow.start(amountCents: 12000)
        expectEqual(r.service.calls.map(\.operationID), ["ttp_operation_1", "ttp_operation_1"], "a retry reuses the operation id")
        expectEqual(r.operationCounter, 1, "no second operation minted")
        if case .approved = r.flow.phase { expect(true, "retry approved") } else { expect(false, "retry approved") }
        expectEqual(r.saved.count, 1, "booked once after the retry")
    }
    do { // Canceled and timed out
        let r = FlowRig()
        r.reader.outcomes = [.result(.canceled), .result(.timedOut)]
        await r.flow.start(amountCents: 12000); expectEqual(r.flow.phase, .canceled, "canceled")
        await r.flow.start(amountCents: 12000); expectEqual(r.flow.phase, .timedOut, "timed out")
        expectEqual(r.saved.count, 0, "neither books anything")
    }
    do { // A changed amount mints a new operation (the Worker refuses one id with new details)
        let r = FlowRig(); r.reader.outcomes = [.result(.canceled)]; r.reader.approveAmountCents = 4000
        await r.flow.start(amountCents: 12000)
        await r.flow.start(amountCents: 4000)
        expectEqual(r.service.calls.map(\.operationID), ["ttp_operation_1", "ttp_operation_2"], "a new amount mints a new operation id")
    }
    do { // Network failure before collect
        let r = FlowRig(); r.service.failures = [.unavailable]; r.reader.approveAmountCents = 12000
        await r.flow.start(amountCents: 12000)
        expectEqual(r.flow.phase, .failed(.network), "network failure before collect")
        expectEqual(r.reader.collectedSecrets.count, 0, "nothing was collected")
        await r.flow.start(amountCents: 12000)
        expectEqual(r.service.calls.map(\.operationID), ["ttp_operation_1", "ttp_operation_1"], "the retry after a network error reuses the operation id")
        if case .approved = r.flow.phase { expect(true, "retry approved") } else { expect(false, "retry approved") }
    }
    do { // Server refusals map to owner-facing failures and never reach the reader
        let r = FlowRig()
        for (error, expected) in [
            (NativeTerminalError.notSynced, NativeTapToPayFlow.Failure.notSynced),
            (.rejectedSession, .sessionExpired),
            (.noConnectedAccount, .stripeNotConnected),
            (.amountExceedsBalance(balanceCents: 8000), .amountExceedsBalance(balanceCents: 8000)),
            (.amountMismatch, .amountMismatch),
            (.serverError, .server),
        ] {
            r.service.failures = [error]
            await r.flow.start(amountCents: 12000)
            expectEqual(r.flow.phase, .failed(expected), "server error \(error) -> \(expected)")
        }
        expectEqual(r.reader.collectedSecrets.count, 0, "no refusal reaches the reader")
    }
    do { // Money guards
        let r = FlowRig(); r.reader.approveAmountCents = 12001
        await r.flow.start(amountCents: 12001)
        expectEqual(r.flow.phase, .failed(.amountExceedsBalance(balanceCents: 12000)), "more than the balance is refused before any request")
        expectEqual(r.service.calls.count, 0, "no PaymentIntent was requested")
        await r.flow.start(amountCents: 0); expectEqual(r.flow.phase, .failed(.amountNotPositive), "zero refused")
        r.balance = nil; await r.flow.start(amountCents: 100); expectEqual(r.flow.phase, .failed(.invoiceMissing), "a deleted invoice")
        r.balance = 0; await r.flow.start(amountCents: 100); expectEqual(r.flow.phase, .failed(.amountExceedsBalance(balanceCents: 0)), "a paid invoice")
        expectEqual(r.service.calls.count, 0, "still no request")

        let drift = FlowRig(); drift.service.echoAmountOffset = 1
        await drift.flow.start(amountCents: 12000)
        expectEqual(drift.flow.phase, .failed(.amountMismatch), "an intent for a different amount is never collected")
        expectEqual(drift.reader.collectedSecrets.count, 0, "...the reader is not called")

        // The balance falls (webhook copy arrived) while the PaymentIntent is created:
        // the first read (before the request) is 12000, the second (before the tap) is 3000.
        let late = FlowRig()
        var reads = 0
        let flow2 = NativeTapToPayFlow(
            invoiceID: "inv1", service: late.service, reader: late.reader,
            balanceCents: { reads += 1; return reads == 1 ? 12000 : 3000 }, record: { _ in true })
        await flow2.start(amountCents: 12000)
        expectEqual(flow2.phase, .failed(.balanceChanged(balanceCents: 3000)), "a balance that fell during PaymentIntent creation stops the charge")
        expectEqual(late.reader.collectedSecrets.count, 0, "...before the card is read")
    }
    do { // Reader not ready / unsupported / throws
        let r = FlowRig(); r.reader.state = .preparing(progress: 0.4)
        await r.flow.start(amountCents: 100); expectEqual(r.flow.phase, .failed(.readerNotReady), "preparing reader is not ready")
        r.reader.state = .unsupported
        await r.flow.start(amountCents: 100); expectEqual(r.flow.phase, .failed(.readerUnavailable), "unsupported reader")
        r.reader.state = .ready; r.reader.outcomes = [.failure(NativeCardReaderError(message: "Reader busy"))]
        r.reader.statusOutcomes = [.requiresPaymentMethod]
        await r.flow.start(amountCents: 100); expectEqual(r.flow.phase, .failed(.reader("Reader busy")), "a reader error, once Stripe says nothing was charged, surfaces its message")
        expectEqual(r.service.calls.count, 1, "the failed collect did request one intent")
        let unavailable = NativeUnavailableCardReader()
        expectEqual(unavailable.state, .unsupported, "the unavailable reader is unsupported")
        let refused = try? await unavailable.collect(clientSecret: "x")
        expect(refused == nil, "the unavailable reader refuses to collect")
        let probe = NativeTerminalPaymentIntent(paymentIntentID: "pi_1", clientSecret: "pi_1_secret_x", amountCents: 100)
        expectEqual(await unavailable.status(of: probe), .unknown, "the unavailable reader can never claim an intent was not charged")
    }
    do { // Approved but the local save failed: charged, not lost
        let r = FlowRig(); r.reader.approveAmountCents = 12000; r.saveSucceeds = false
        await r.flow.start(amountCents: 12000)
        expectEqual(r.flow.phase, .approved(.init(paymentIntentID: "pi_3Fake000000000001", amountCents: 12000, recorded: false, amountDiffersFromRequest: false)), "approved, save pending")
        r.saveSucceeds = true
        r.flow.retryRecording()
        expectEqual(r.saved.count, 1, "retryRecording saves the entry")
        if case .approved(let a) = r.flow.phase { expect(a.recorded, "recorded after the retry") } else { expect(false, "still approved") }
    }
    do { // The reader collected a different amount than requested: book what was charged
        let r = FlowRig(); r.reader.approveAmountCents = 11000
        await r.flow.start(amountCents: 12000)
        if case .approved(let a) = r.flow.phase {
            expectEqual(a.amountCents, 11000, "books the amount Stripe collected")
            expect(a.amountDiffersFromRequest, "flags the difference")
        } else { expect(false, "approved") }
        expectEqual(entryJSON(r.saved[0])["amount"], .number(110), "the entry carries the collected amount")
    }
    await ambiguousReaderFailures()
}

/// Review findings 1-4 and 6 (Phase 18 stage A): the amount and the operation
/// lock once a collect starts; a reader failure is resolved by asking Stripe
/// before anything else; a gone sheet never collects; a reader that reports
/// another intent is never booked; the description is frozen with the
/// operation; amounts under the minimum are refused.
@MainActor
func ambiguousReaderFailures() async {
    let readerStopped = NativeCardReaderError(message: "Reader busy")

    do { // 1a. The first charge actually succeeded: exactly one booking, no second intent
        let r = FlowRig(); r.reader.approveAmountCents = 4000
        r.reader.outcomes = [.failure(readerStopped)]
        r.reader.statusOutcomes = [.succeeded(amountCents: 12000)]
        await r.flow.start(amountCents: 12000)
        expectEqual(r.flow.phase, .approved(.init(paymentIntentID: "pi_3Fake000000000001", amountCents: 12000, recorded: true, amountDiffersFromRequest: false)),
                    "a reader error whose charge succeeded is booked from the status read")
        expectEqual(r.reader.statusChecks, ["pi_3Fake000000000001"], "the status of the intent that was collected was read")
        await r.flow.start(amountCents: 4000)  // the owner types a different amount afterwards
        expectEqual(r.service.calls.count, 1, "no second PaymentIntent after a charge that succeeded")
        expectEqual(r.reader.collectedSecrets.count, 1, "the reader is not asked again")
        expectEqual(r.saved.count, 1, "booked exactly once")
        expect(r.flow.isAmountLocked, "an approved flow keeps the amount locked")
    }
    do { // 1b. Status unknown: locked, "Checking payment", never a new charge, until it resolves
        let r = FlowRig()
        r.reader.outcomes = [.failure(readerStopped)]
        r.reader.statusOutcomes = [.unknown, .unknown, .succeeded(amountCents: 12000)]
        await r.flow.start(amountCents: 12000)
        expectEqual(r.flow.phase, .paymentUnconfirmed, "an unreadable outcome stays unconfirmed")
        expect(r.flow.isAmountLocked && r.flow.lockedAmountCents == 12000, "the amount is locked at what was being charged")
        expect(!r.flow.isBusy, "unconfirmed is not busy (Close and Check again stay available)")
        await r.flow.start(amountCents: 4000)  // a different amount must not charge anything
        expectEqual(r.flow.phase, .paymentUnconfirmed, "still unconfirmed after another start with a different amount")
        expectEqual(r.service.calls.count, 1, "no new PaymentIntent while the outcome is unknown")
        expectEqual(r.reader.collectedSecrets.count, 1, "no new collection while the outcome is unknown")
        expectEqual(r.reader.statusChecks.count, 2, "start re-checks the status instead of charging")
        expectEqual(r.saved.count, 0, "nothing booked while unknown")
        await r.flow.checkAgain()
        expectEqual(r.flow.phase, .approved(.init(paymentIntentID: "pi_3Fake000000000001", amountCents: 12000, recorded: true, amountDiffersFromRequest: false)), "Check again books it once the status is known")
        expectEqual(r.saved.count, 1, "booked exactly once")
        expectEqual(r.service.calls.count, 1, "still one intent")
        await r.flow.checkAgain()
        expectEqual(r.saved.count, 1, "a further check after approval books nothing")
    }
    do { // 1c. Definitively not charged (requires_payment_method): retry with the SAME operation; the amount stays locked
        let r = FlowRig(); r.reader.approveAmountCents = 12000
        r.reader.outcomes = [.failure(readerStopped)]
        r.reader.statusOutcomes = [.requiresPaymentMethod]
        await r.flow.start(amountCents: 12000)
        expectEqual(r.flow.phase, .failed(.reader("Reader busy")), "not charged: the reader's message, retry allowed")
        expect(r.flow.isAmountLocked && r.flow.lockedAmountCents == 12000, "the intent is still open, so the amount stays locked")
        await r.flow.start(amountCents: 4000)  // a different amount is ignored: the locked one is charged
        expectEqual(r.service.calls.map(\.amountCents), [12000, 12000], "the retry charges the locked amount, not the edited one")
        expectEqual(r.service.calls.map(\.operationID), ["ttp_operation_1", "ttp_operation_1"], "the retry reuses the operation id")
        expectEqual(r.operationCounter, 1, "no second operation minted while the old intent is alive")
        if case .approved(let a) = r.flow.phase { expectEqual(a.amountCents, 12000, "retry approved at the locked amount") } else { expect(false, "retry approved") }
        expectEqual(r.saved.count, 1, "booked once")
    }
    do { // 1d. Known dead (canceled): unlocked, and the next start mints a NEW operation, even for the same amount
        let r = FlowRig(); r.reader.approveAmountCents = 4000
        r.reader.outcomes = [.failure(readerStopped)]
        r.reader.statusOutcomes = [.canceled]
        await r.flow.start(amountCents: 12000)
        expectEqual(r.flow.phase, .failed(.reader("Reader busy")), "a canceled intent: not charged")
        expect(!r.flow.isAmountLocked && r.flow.lockedAmountCents == nil, "a dead intent unlocks the amount")
        await r.flow.start(amountCents: 4000)
        expectEqual(r.service.calls.map(\.operationID), ["ttp_operation_1", "ttp_operation_2"], "a new operation is minted only after the old intent is dead")
        expectEqual(r.service.calls.map(\.amountCents), [12000, 4000], "the new operation takes the new amount")

        let same = FlowRig(); same.reader.outcomes = [.failure(readerStopped)]; same.reader.statusOutcomes = [.canceled]
        await same.flow.start(amountCents: 12000)
        await same.flow.start(amountCents: 12000)
        expectEqual(same.service.calls.map(\.operationID), ["ttp_operation_1", "ttp_operation_2"], "the old operation id would return the dead intent: a new one is minted")
    }
    do { // A clear card outcome is a known outcome: no lock
        let r = FlowRig(); r.reader.outcomes = [.result(.declined(reason: "card_declined"))]
        await r.flow.start(amountCents: 12000)
        expect(!r.flow.isAmountLocked && r.flow.lockedAmountCents == nil, "a decline unlocks the amount")
        expectEqual(r.reader.statusChecks.count, 0, "no status read for a clear card outcome")
    }

    do { // 2. Close while Preparing: the sheet is gone, so the reader is never asked
        let r = FlowRig(); r.reader.approveAmountCents = 12000
        r.service.suspendNext = true
        let task = Task { await r.flow.start(amountCents: 12000) }
        while !r.service.isSuspended { await Task.yield() }
        expectEqual(r.flow.phase, .preparing, "preparing while the intent is created")
        expect(r.flow.isBusy, "preparing is busy, so Close is disabled")
        r.flow.close()
        r.service.release()
        await task.value
        expectEqual(r.reader.collectedSecrets.count, 0, "a dismissed sheet never starts a collection")
        expectEqual(r.saved.count, 0, "and books nothing")
        await r.flow.start(amountCents: 12000)
        expectEqual(r.service.calls.count, 1, "a closed flow cannot start again")
        let cancelled = FlowRig(); cancelled.service.suspendNext = true
        let task2 = Task { await cancelled.flow.start(amountCents: 12000) }
        while !cancelled.service.isSuspended { await Task.yield() }
        task2.cancel(); cancelled.service.release(); await task2.value
        expectEqual(cancelled.reader.collectedSecrets.count, 0, "a cancelled start never reaches the reader either")
    }

    do { // 3a. The reader reports another PaymentIntent's id: never booked, locked
        let r = FlowRig(); r.reader.approvePaymentIntentID = "pi_3Other000000000009"; r.reader.approveAmountCents = 12000
        r.reader.statusOutcomes = [.requiresPaymentMethod, .succeeded(amountCents: 12000)]
        await r.flow.start(amountCents: 12000)
        expectEqual(r.flow.phase, .paymentUnconfirmed, "an id mismatch goes to the locked Checking payment state")
        expectEqual(r.saved.count, 0, "the reader's id is never booked")
        expect(r.flow.isAmountLocked, "locked")
        await r.flow.checkAgain()
        expectEqual(r.flow.phase, .paymentUnconfirmed, "our intent looking uncharged does not clear a mismatch: another intent may have been charged")
        await r.flow.start(amountCents: 4000)
        expectEqual(r.service.calls.count, 1, "no new charge after a mismatch")
        await r.flow.checkAgain()
        if case .approved(let a) = r.flow.phase { expectEqual(a.paymentIntentID, "pi_3Fake000000000001", "only the intent this flow created is ever booked") } else { expect(false, "approved after our intent succeeded") }
        expectEqual(r.saved.map { entryJSON($0)["id"] }, [.string("stripe_pi_3Fake000000000001")], "booked under OUR intent id, once")
    }
    do { // 3b. A ledger entry that cannot be built is surfaced, not a dead Save button
        let r = FlowRig(); r.reader.approveAmountCents = 0  // collected 0: nothing valid to book
        await r.flow.start(amountCents: 12000)
        guard case .approved(let a) = r.flow.phase else { expect(false, "approved"); return }
        expect(!a.recorded && a.entryUnbuildable, "charged but unbuildable is flagged, so the sheet shows an error and no Save button")
        r.flow.retryRecording()
        expectEqual(r.saved.count, 0, "retry cannot invent an entry")
        // A save that merely failed stays retryable and rebuilds the entry.
        let t = FlowRig(); t.reader.approveAmountCents = 12000; t.saveSucceeds = false
        await t.flow.start(amountCents: 12000)
        if case .approved(let b) = t.flow.phase { expect(!b.recorded && !b.entryUnbuildable, "a failed save is retryable, not unbuildable") } else { expect(false, "approved") }
        t.saveSucceeds = true; t.flow.retryRecording()
        expectEqual(t.saved.count, 1, "the retry saves it")
    }

    do { // 4. The invoice number is frozen with the operation
        let r = FlowRig(); r.reader.approveAmountCents = 12000
        r.reader.outcomes = [.result(.declined(reason: "card_declined"))]
        await r.flow.start(amountCents: 12000)
        r.number = "INV-0042-EDITED"  // edited between retries
        await r.flow.start(amountCents: 12000)
        expectEqual(r.service.calls.map(\.invoiceNumber), ["INV-0042", "INV-0042"], "the retry sends the number frozen with the operation")
        expectEqual(r.service.calls.map(\.operationID), ["ttp_operation_1", "ttp_operation_1"], "same operation")

        let net = FlowRig(); net.service.failures = [.unavailable]
        await net.flow.start(amountCents: 12000)
        net.number = "CHANGED"
        await net.flow.start(amountCents: 12000)
        expectEqual(net.service.calls.map(\.invoiceNumber), ["INV-0042", "INV-0042"], "a retry after a network error is frozen too")

        let fresh = FlowRig(); fresh.reader.outcomes = [.result(.canceled)]; fresh.reader.approveAmountCents = 4000
        await fresh.flow.start(amountCents: 12000)
        fresh.number = "INV-NEW"
        await fresh.flow.start(amountCents: 4000)
        expectEqual(fresh.service.calls.map(\.invoiceNumber), ["INV-0042", "INV-NEW"], "a new operation reads the number afresh")
        let blank = FlowRig(); blank.number = "  "
        await blank.flow.start(amountCents: 12000)
        expectEqual(blank.service.calls.first?.invoiceNumber, nil, "a blank number is not sent")
    }

    do { // 6. Under the minimum: refused before any request, with the copy
        let r = FlowRig()
        await r.flow.start(amountCents: 49)
        expectEqual(r.flow.phase, .failed(.belowMinimum), "49 cents is too small to take by card")
        expectEqual(r.service.calls.count, 0, "no PaymentIntent requested")
        r.balance = 30
        await r.flow.start(amountCents: 30)
        expectEqual(r.flow.phase, .failed(.belowMinimum), "a 30-cent balance cannot be taken by card")
        r.balance = 12000; r.service.failures = [.belowMinimum]
        await r.flow.start(amountCents: 100)
        expectEqual(r.flow.phase, .failed(.belowMinimum), "the Worker's below_minimum maps to the same failure")
        expectEqual(NativeCardPresentPayment.belowMinimumMessage, "That amount is too small to take by card. The minimum card payment is $0.50.", "below-minimum copy")
        expect(!r.flow.isAmountLocked, "nothing locked: no collection started")
    }
}

// MARK: - AppStore

@MainActor
func storeRecording() {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tradeready-tap-to-pay-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let storeURL = dir.appendingPathComponent("store.json")
    let store = AppStore(fileURL: storeURL, seedIfMissing: false, secureSettingsStore: hostTestSecureSettingsStore())

    var invoice = Invoice()
    invoice.customer = "Delta Roofing"; invoice.number = "INV-0042"; invoice.amount = 412.5
    store.upsert(invoice)
    func canonicalInvoice() -> Canonical.Invoice? {
        let repository = Canonical.SnapshotRepository(primaryURL: storeURL)
        return (try? repository.load())??.snapshot.payload.invoices?.first { $0.id == invoice.id }
    }
    func storedPayments() -> [[String: Canonical.JSONValue]] {
        (canonicalInvoice()?.payments ?? []).map { payment in
            guard let data = try? JSONEncoder().encode(payment),
                  case let .object(fields)? = try? JSONDecoder().decode(Canonical.JSONValue.self, from: data) else { return [:] }
            return fields
        }
    }

    // A manual cash payment first, so the ledger has a pre-existing entry.
    var cash = Payment(); cash.amount = 100; cash.method = "Cash"
    if case .failure = store.recordPayment(invoiceID: invoice.id, payment: cash) { expect(false, "cash payment recorded") }

    do {
        let entry = try NativeCardPresentPayment.ledgerEntry(paymentIntentId: "pi_3Q4abc", amountCents: 20000, localDate: "2026-10-13")
        guard case .success(let after) = store.recordCardPresentPayment(invoiceID: invoice.id, entry: entry) else { expect(false, "card-present payment recorded"); return }
        expectEqual(after.amountPaid, 300, "balance math: 100 cash + 200 card")
        expectEqual(after.balance, 112.5, "balance remaining")
        let stored = storedPayments()
        expectEqual(stored.count, 2, "two ledger entries")
        let tap = stored.first { $0["id"] == .string("stripe_pi_3Q4abc") }
        expectEqual(tap, [
            "id": .string("stripe_pi_3Q4abc"), "amount": .number(200), "date": .string("2026-10-13"),
            "method": .string("stripe"), "stripePaymentIntentId": .string("pi_3Q4abc"), "channel": .string("card_present"),
        ], "the stored entry is exactly the Worker's shape: no note/voidedAt nulls, method stays stripe")
        let cashEntry = stored.first { $0["method"] == .string("cash") }
        expect(cashEntry != nil, "the cash entry is untouched")

        // Display labels.
        let row = after.effectivePayments.first { $0.id == "stripe_pi_3Q4abc" }
        expectEqual(row?.displayMethod, "Tap to Pay", "invoice row label")
        expectEqual(row?.method, "Card (online)", "method string for a Stripe payment is no longer Other/Stripe")
        expectEqual(after.effectivePayments.first { $0.id == cash.id }?.displayMethod, "Cash", "cash row label unchanged")

        // Idempotent: a retry or the webhook's copy arriving first records nothing twice.
        guard case .success(let again) = store.recordCardPresentPayment(invoiceID: invoice.id, entry: entry) else { expect(false, "retry result"); return }
        expectEqual(again.amountPaid, 300, "a second record of the same payment changes nothing")
        expectEqual(storedPayments().count, 2, "still two entries")

        // Edit round trip: another payment, then a void, then an invoice edit keep channel and the intent id.
        var second = Payment(); second.amount = 12.5; second.method = "Card"
        if case .failure = store.recordPayment(invoiceID: invoice.id, payment: second) { expect(false, "second manual payment") }
        let afterEdits = storedPayments().first { $0["id"] == .string("stripe_pi_3Q4abc") }
        expectEqual(afterEdits?["channel"], .string("card_present"), "channel survives a later payment")
        expectEqual(afterEdits?["stripePaymentIntentId"], .string("pi_3Q4abc"), "intent id survives a later payment")
        expectEqual(afterEdits?["method"], .string("stripe"), "method stays stripe through the UI round trip")
        let draft = NativeInvoiceDraft(
            customer: "Delta Roofing", customerId: "", number: "INV-0042", amount: 412.5,
            due: invoice.due.dateOnlyString, email: "", phone: "", description: "Edited description")
        if case .failure(let refusal) = store.commitInvoiceEdit(id: invoice.id, opened: store.invoices.first { $0.id == invoice.id }, draft: draft) {
            expect(false, "invoice edit \(refusal)")
        }
        let afterInvoiceEdit = storedPayments().first { $0["id"] == .string("stripe_pi_3Q4abc") }
        expectEqual(afterInvoiceEdit, afterEdits, "an invoice edit leaves the card-present entry byte-identical")
        _ = store.voidPayment(invoiceID: invoice.id, paymentID: second.id)
        expectEqual(storedPayments().first { $0["id"] == .string("stripe_pi_3Q4abc") }, afterEdits, "voiding another payment leaves it byte-identical")

        // The profit / cash-basis / accountant views see a normal non-voided stripe payment.
        if let canonical = canonicalInvoice() {
            let start = ISO8601DateFormatter().date(from: "2026-10-01T00:00:00Z")!
            let end = ISO8601DateFormatter().date(from: "2026-10-31T23:00:00Z")!
            expectEqual(NativeCashBasis.collected(invoices: [canonical], start: start, end: end) >= 200, true, "cash-basis collected includes the card-present amount")
            expectEqual(NativeAccountingPackage.paymentSource("stripe_pi_3Q4abc"), "stripe", "accountant package source is stripe by id prefix")
        } else { expect(false, "canonical invoice readable") }

        // Voiding the card-present entry restores the balance (and moves no money).
        guard case .success(let voided) = store.voidPayment(invoiceID: invoice.id, paymentID: "stripe_pi_3Q4abc") else { expect(false, "void"); return }
        expectEqual(voided.balance, 312.5, "void restores the 200 (only the 100 cash remains paid)")
        let voidedRow = storedPayments().first { $0["id"] == .string("stripe_pi_3Q4abc") }
        expect(voidedRow?["voidedAt"] != nil && voidedRow?["channel"] == .string("card_present"), "a void keeps the entry and its channel")

        // Unknown invoice.
        if case .success = store.recordCardPresentPayment(invoiceID: "nope", entry: entry) { expect(false, "unknown invoice refused") }
    } catch { expect(false, "store scenario threw \(error)") }

    // Webhook first (the server's copy pulled down), then the device records the same id: no double booking.
    var other = Invoice(); other.customer = "Echo"; other.number = "INV-0043"; other.amount = 120
    store.upsert(other)
    if let entry = try? NativeCardPresentPayment.ledgerEntry(paymentIntentId: "pi_tap_1", amountCents: 12000, localDate: "2026-10-13") {
        expectEqual(entryJSON(entry), webhookEntry, "the device entry equals the webhook entry")
        _ = store.recordCardPresentPayment(invoiceID: other.id, entry: entry)
        _ = store.recordCardPresentPayment(invoiceID: other.id, entry: entry)
        expectEqual(store.invoices.first { $0.id == other.id }?.amountPaid, 120, "recorded exactly once")
        expectEqual(store.invoices.first { $0.id == other.id }?.isPaid, true, "the invoice is paid")
    }
}

@main
struct TapToPayTests {
    static func main() async {
        await MainActor.run {
            pureRules()
            ledgerEntry()
            capability()
            storeRecording()
        }
        await transport()
        await sheetStateMachine()
        await MainActor.run {
            print("tap-to-pay: \(checks) checks, \(failures) failures")
            if failures > 0 { exit(1) }
            print("Tap to Pay tests passed")
        }
    }
}
