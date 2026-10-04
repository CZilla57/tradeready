import Foundation

// Phase 34 (referral program) host tests, spec
// docs/superpowers/specs/2026-10-03-referral-program-design.md §7:
// `N/Domain/NativeReferrals.swift` (codes, resolution, self-referral, links,
// copy, credits, rewards), `NativeBookingIntake.referralDecision`,
// `N/Domain/NativeReferralReport.swift` (report, control total, customer
// summary, coach block), the `referral_thanks` Today insight and the
// invoice-credit line constants. The code vectors are the fixture the Worker
// suites share (REFERRAL_CODE_VECTORS). Run with TZ=America/Phoenix: the
// day-boundary cases assume a west-of-UTC zone (FA-039).

var failures = 0
var checks = 0

func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
    checks += 1
    if !condition() {
        failures += 1
        print("FAIL: \(label)")
    }
}

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ label: String) {
    checks += 1
    if actual != expected {
        failures += 1
        print("FAIL: \(label)\n  expected: \(expected)\n  actual:   \(actual)")
    }
}

func d(_ text: String) -> Decimal { Decimal(string: text)! }

// MARK: - Fixtures

func decodeJSON<T: Decodable>(_ type: T.Type, _ fields: [String: Any]) -> T {
    let data = try! JSONSerialization.data(withJSONObject: fields)
    return try! JSONDecoder().decode(T.self, from: data)
}

func customer(
    _ id: String, _ name: String, source: String? = nil, createdAt: String? = nil, archivedAt: String? = nil,
    code: String? = nil, aliases: [String]? = nil, referrer: String? = nil, reward: [String: Any]? = nil,
    email: String = "", phone: String = ""
) -> Canonical.Customer {
    var fields: [String: Any] = ["id": id, "name": name, "email": email, "phone": phone, "address": "", "notes": ""]
    if let source { fields["leadSource"] = source }
    if let createdAt { fields["createdAt"] = createdAt }
    if let archivedAt { fields["archivedAt"] = archivedAt }
    if let code { fields["referralCode"] = code }
    if let aliases { fields["referralCodeAliases"] = aliases }
    if let referrer { fields["referredByCustomerId"] = referrer }
    if let reward { fields["referralReward"] = reward }
    return decodeJSON(Canonical.Customer.self, fields)
}

func reward(_ kind: String, _ amount: Double? = nil, on day: String = "2026-09-10") -> [String: Any] {
    var fields: [String: Any] = ["kind": kind, "recordedOn": day]
    if let amount { fields["amount"] = amount }
    return fields
}

func payment(_ id: String, _ amount: Double, _ date: String, voidedAt: String? = nil) -> [String: Any] {
    var fields: [String: Any] = ["id": id, "amount": amount, "date": date, "method": "cash"]
    if let voidedAt { fields["voidedAt"] = voidedAt }
    return fields
}

func invoice(
    _ id: String, customerId: String?, name: String, amount: Double = 1000,
    payments: [[String: Any]] = [], lines: [(String, Double, String)] = []
) -> Canonical.Invoice {
    var fields: [String: Any] = [
        "id": id, "customer": name, "number": "INV-\(id)", "amount": amount, "due": "2026-09-30",
        "email": "", "phone": "", "desc": "", "paid": false,
    ]
    if let customerId { fields["customerId"] = customerId }
    if !payments.isEmpty { fields["payments"] = payments }
    if !lines.isEmpty {
        fields["lineItems"] = lines.map { ["description": $0.0, "amount": $0.1, "category": $0.2] }
    }
    return decodeJSON(Canonical.Invoice.self, fields)
}

func request(
    _ id: String = "r1", name: String, email: String = "", phone: String = "", code: String? = nil,
    source: String? = nil, leadSource: String? = nil
) -> Canonical.BookingRequest {
    var fields: [String: Any] = [
        "id": id, "status": "new", "name": name, "phone": phone, "email": email, "address": "",
        "details": "", "preferredTiming": "", "createdAt": "2026-09-14T17:00:00.000Z",
    ]
    if let code { fields["referralCode"] = code }
    if let source { fields["source"] = source }
    if let leadSource { fields["leadSource"] = leadSource }
    return decodeJSON(Canonical.BookingRequest.self, fields)
}

func bytes(hex: String) -> [UInt8] {
    var out: [UInt8] = []
    var index = hex.startIndex
    while index < hex.endIndex {
        let next = hex.index(index, offsetBy: 2)
        out.append(UInt8(hex[index..<next], radix: 16)!)
        index = next
    }
    return out
}

/// Sep 15 2026, noon local; "this_month" is Sep 1 – Sep 30 23:59:59 local.
let sep15 = NativeCashBasis.localDate(year: 2026, month: 8, day: 15, hour: 12)
let september = NativeCashBasis.range(for: "this_month", now: sep15)

// MARK: - Shared fixture vectors (§10.3)

func testFixtureVectors() {
    guard let path = ProcessInfo.processInfo.environment["REFERRAL_CODE_VECTORS"],
          let data = FileManager.default.contents(atPath: path),
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
        expect(false, "fixture: REFERRAL_CODE_VECTORS is readable")
        return
    }
    expectEqual(root["alphabet"] as? String, String(NativeReferrals.codeAlphabet), "fixture: alphabet")
    expectEqual(root["codeByteCount"] as? Int, NativeReferrals.codeByteCount, "fixture: byte count")
    expectEqual(root["codeLength"] as? Int, NativeReferrals.codeLength, "fixture: code length")
    expectEqual(root["pattern"] as? String, NativeReferrals.codePattern, "fixture: pattern")

    let encode = root["encode"] as? [[String: Any]] ?? []
    expect(encode.count >= 9, "fixture: encode vectors present (\(encode.count))")
    for vector in encode {
        let name = vector["name"] as? String ?? "?"
        let input = bytes(hex: vector["bytesHex"] as? String ?? "")
        let expected = vector["expect"] as? String
        expectEqual(NativeReferrals.encodeCode(input), expected, "encode vector: \(name)")
    }

    let normalize = root["normalize"] as? [[String: Any]] ?? []
    var swiftVectors = 0
    for vector in normalize where (vector["jsOnly"] as? Bool) != true {
        swiftVectors += 1
        let name = vector["name"] as? String ?? "?"
        let input = vector["input"] as? String
        let expected = vector["expect"] as? String
        expect(vector["input"] is NSNull || input != nil, "normalize vector \(name): input is a string or null")
        expectEqual(NativeReferrals.normalizeCode(input), expected, "normalize vector: \(name)")
    }
    expect(swiftVectors >= 27, "fixture: every non-jsOnly normalize vector ran (\(swiftVectors))")
}

// MARK: - Encoding and normalization (§7)

func testEncoding() {
    expectEqual(NativeReferrals.encodeCode([UInt8](repeating: 0, count: 10)), "0000000000000000", "encode: ten 0x00")
    expectEqual(NativeReferrals.encodeCode([UInt8](repeating: 0xFF, count: 10)), "zzzzzzzzzzzzzzzz", "encode: ten 0xFF")
    expectEqual(NativeReferrals.encodeCode([0x00, 0x44, 0x32, 0x14, 0xC7, 0x42, 0x54, 0xB6, 0x35, 0xCF]),
                "0123456789abcdef", "encode: first half of the alphabet")
    expectEqual(NativeReferrals.encodeCode([UInt8](repeating: 1, count: 9)), nil, "encode: 9 bytes is nil")
    expectEqual(NativeReferrals.encodeCode([UInt8](repeating: 1, count: 11)), nil, "encode: 11 bytes is nil")

    expectEqual(NativeReferrals.normalizeCode("  0123456789ABCDEF\n"), "0123456789abcdef", "normalize: trims and case-folds")
    for bad in ["0123456789abcdei", "0123456789abcdel", "0123456789abcdeo", "0123456789abcdeu",
                "0123456789abcde", "0123456789abcdef0", "", "\u{212A}123456789abcdef"] {
        expectEqual(NativeReferrals.normalizeCode(bad), nil, "normalize: rejects '\(bad)'")
    }
    expectEqual(NativeReferrals.normalizeCode(nil), nil, "normalize: nil")
}

func testMakeCode() {
    var draws: [[UInt8]] = [
        [UInt8](repeating: 0, count: 10),
        [0x00, 0x44, 0x32, 0x14, 0xC7, 0x42, 0x54, 0xB6, 0x35, 0xCF],
    ]
    var asked: [Int] = []
    let code = NativeReferrals.makeCode(existing: ["0000000000000000"]) { count in
        asked.append(count)
        return draws.isEmpty ? nil : draws.removeFirst()
    }
    expectEqual(code, "0123456789abcdef", "makeCode: a collision is retried with fresh bytes")
    expectEqual(asked, [10, 10], "makeCode: asks for 10 bytes per draw")

    var attempts = 0
    let exhausted = NativeReferrals.makeCode(existing: ["0000000000000000"]) { _ in
        attempts += 1
        return [UInt8](repeating: 0, count: 10)
    }
    expectEqual(exhausted, nil, "makeCode: nil after three collisions")
    expectEqual(attempts, 3, "makeCode: at most three draws")
    expectEqual(NativeReferrals.makeCode(existing: []) { _ in nil }, nil, "makeCode: nil when the RNG fails")
    expectEqual(NativeReferrals.makeCode(existing: []) { _ in [1, 2, 3] }, nil, "makeCode: nil on a short read")
    let fresh = NativeReferrals.makeCode(existing: []) { count in (0..<count).map { UInt8($0 * 37 % 256) } }
    expect(fresh.flatMap(NativeReferrals.normalizeCode) == fresh, "makeCode: the result is canonical")
}

// MARK: - Resolution and self-referral

func testResolution() {
    let sam = customer("c_sam", "Sam Ortiz", code: "0123456789abcdef", aliases: ["ghjkmnpqrstvwxyz"])
    let ana = customer("c_ana", "Ana Lee", archivedAt: "2026-08-01", code: "vtpvxvr024h36h2n")
    let all = [sam, ana, customer("c_x", "No Code")]
    expectEqual(NativeReferrals.resolveReferrer(code: "0123456789abcdef", customers: all)?.id, "c_sam", "resolve: by code")
    expectEqual(NativeReferrals.resolveReferrer(code: "GHJKMNPQRSTVWXYZ", customers: all)?.id, "c_sam", "resolve: by alias, any case")
    expectEqual(NativeReferrals.resolveReferrer(code: " vtpvxvr024h36h2n ", customers: all)?.id, "c_ana", "resolve: an archived referrer still resolves")
    expectEqual(NativeReferrals.resolveReferrer(code: "zzzzzzzzzzzzzzzz", customers: all)?.id, nil, "resolve: no match")
    expectEqual(NativeReferrals.resolveReferrer(code: "not a code", customers: all)?.id, nil, "resolve: unusable code")
    expectEqual(NativeReferrals.resolveReferrer(code: nil, customers: all)?.id, nil, "resolve: nil")
    let duplicate = all + [customer("c_dup", "Dup", code: "0123456789abcdef")]
    expectEqual(NativeReferrals.resolveReferrer(code: "0123456789abcdef", customers: duplicate)?.id, nil,
                "resolve: a duplicate code fails closed (R2)")
    let aliasClash = all + [customer("c_dup", "Dup", aliases: ["vtpvxvr024h36h2n"])]
    expectEqual(NativeReferrals.resolveReferrer(code: "vtpvxvr024h36h2n", customers: aliasClash)?.id, nil,
                "resolve: a code shared with another customer's alias fails closed")
    expectEqual(NativeReferrals.allCodes(in: all + [customer("c_bad", "Bad", code: "nope")]),
                ["0123456789abcdef", "ghjkmnpqrstvwxyz", "vtpvxvr024h36h2n"], "allCodes: codes and aliases, invalid skipped")
}

func testSelfReferral() {
    let sam = customer("c_sam", "Sam Ortiz", email: "Sam@Example.com", phone: "(602) 555-0142")
    expect(NativeReferrals.isSelfReferral(referrer: sam, matchedCustomerID: "c_sam", email: "", phone: ""), "self: by name-matched id")
    expect(NativeReferrals.isSelfReferral(referrer: sam, matchedCustomerID: nil, email: "  sam@example.COM ", phone: ""), "self: by email, any case")
    expect(NativeReferrals.isSelfReferral(referrer: sam, matchedCustomerID: nil, email: "", phone: "+1 602.555.0142"), "self: by phone, any formatting")
    expect(!NativeReferrals.isSelfReferral(referrer: sam, matchedCustomerID: "c_other", email: "alex@example.com", phone: "602-555-0199"),
           "self: someone else")
    let shortPhone = customer("c_s", "Short", phone: "555-012")
    expect(!NativeReferrals.isSelfReferral(referrer: shortPhone, matchedCustomerID: nil, email: "", phone: "555012"),
           "self: a phone under 7 digits is ignored")
    expect(!NativeReferrals.isSelfReferral(referrer: customer("c_e", "E"), matchedCustomerID: nil, email: "", phone: ""),
           "self: blank email and phone never match")
}

// MARK: - Links and copy

func testLinks() {
    let token = String(repeating: "ab", count: 24)
    guard let booking = NativeBookingAdministrationService.bookingURL(token: token) else {
        expect(false, "links: booking URL builds"); return
    }
    let link = NativeReferrals.referralURL(bookingURL: booking, code: "0123456789abcdef")
    expectEqual(link?.absoluteString, "https://gettradereadyapp.com/book.html?b=\(token)&r=0123456789abcdef", "links: r is appended and b kept")
    expect(link.map { NativeBookingAdministrationService.isValidBookingURL($0, token: token) } == true,
           "links: isValidBookingURL still accepts a referral link")
    expectEqual(NativeReferrals.referralURL(bookingURL: booking, code: "0123456789ABCDEF"), nil, "links: a non-canonical code is refused")
    expectEqual(NativeReferrals.referralURL(bookingURL: booking, code: "0123456789abcdei"), nil, "links: an invalid code is refused")
    expectEqual(NativeReferrals.referralURL(bookingURL: URL(string: "https://gettradereadyapp.com/book.html")!, code: "0123456789abcdef"),
                nil, "links: a URL without b is refused")
    expectEqual(NativeReferrals.referralURL(bookingURL: link!, code: "ghjkmnpqrstvwxyz"), nil, "links: a URL that already has r is refused")
}

func testCopy() {
    let link = URL(string: "https://gettradereadyapp.com/book.html?b=t&r=0123456789abcdef")!
    expectEqual(
        NativeReferrals.renderShareMessage(customerName: "Sam", businessName: "Ortiz Plumbing", link: link),
        "Hi Sam, thanks again for choosing Ortiz Plumbing! If you know anyone who needs a hand, here's a booking link you can pass along: https://gettradereadyapp.com/book.html?b=t&r=0123456789abcdef\nWhen they book through it, we'll know they came from you.",
        "copy: share message"
    )
    expect(NativeReferrals.renderShareMessage(customerName: " ", businessName: "", link: link)
        .hasPrefix("Hi there, thanks again for choosing us! "), "copy: blank name and business fall back")
    let base = "Thanks for choosing us! Leave a review: https://g.page/r/x  \n"
    let appended = NativeReferrals.appendingReferralParagraph(to: base, link: link)
    expectEqual(appended,
                "Thanks for choosing us! Leave a review: https://g.page/r/x\n\nKnow someone who could use a hand? Pass along your personal booking link: https://gettradereadyapp.com/book.html?b=t&r=0123456789abcdef",
                "copy: review paragraph appended after a blank line")
    expectEqual(NativeReferrals.appendingReferralParagraph(to: appended, link: link), appended, "copy: appending twice is a no-op")
    expectEqual(NativeReferrals.appendingReferralParagraph(to: "  ", link: link), NativeReferrals.referralParagraph(link: link),
                "copy: an empty message becomes the paragraph")
    expectEqual(NativeReferralLinkState.bookingLinkOff.message,
                "Turn on your booking link in Settings \u{2192} Booking link to share referral links.", "copy: booking link off")
    expectEqual(NativeReferralLinkState.unverified.message,
                "Couldn't verify your booking link. Check your connection and try again.", "copy: unverified")
    expectEqual(NativeReferralLinkState.ready(link).message, nil, "copy: ready shows no notice")
}

// MARK: - Intake decision (§5.3)

func testReferralDecision() {
    let sam = customer("c_sam", "Sam Ortiz", source: "google", code: "0123456789abcdef",
                       email: "sam@example.com", phone: "602-555-0142")
    let customers = [sam, customer("c_dup1", "Dup One", code: "zzzzzzzzzzzzzzzz"), customer("c_dup2", "Dup Two", code: "zzzzzzzzzzzzzzzz")]
    typealias Decision = NativeBookingIntake.ReferralDecision
    func decide(_ r: Canonical.BookingRequest) -> Decision { NativeBookingIntake.referralDecision(for: r, customers: customers) }

    expectEqual(decide(request(name: "Alex", code: "0123456789abcdef", source: "portal")),
                Decision(leadSource: nil, referredByCustomerId: nil), "decision: a portal request ignores a code")
    expectEqual(decide(request(name: "Alex")), Decision(leadSource: "booking_link", referredByCustomerId: nil),
                "decision: no code keeps the Phase 27 default")
    expectEqual(decide(request(name: "Alex", leadSource: "nextdoor")), Decision(leadSource: "nextdoor", referredByCustomerId: nil),
                "decision: no code keeps ?src=")
    expectEqual(decide(request(name: "Alex", code: "ILOU456789abcdef", leadSource: "nextdoor")),
                Decision(leadSource: "nextdoor", referredByCustomerId: nil), "decision: a code the device rejects is no code")
    expectEqual(decide(request(name: " sam ortiz ", code: "0123456789abcdef")),
                Decision(leadSource: "booking_link", referredByCustomerId: nil), "decision: self-referral by name")
    expectEqual(decide(request(name: "S. Ortiz", email: "SAM@example.com", code: "0123456789abcdef")),
                Decision(leadSource: "booking_link", referredByCustomerId: nil), "decision: self-referral by email")
    expectEqual(decide(request(name: "S. Ortiz", phone: "(602) 555 0142", code: "0123456789abcdef")),
                Decision(leadSource: "booking_link", referredByCustomerId: nil), "decision: self-referral by phone")
    expectEqual(decide(request(name: "Alex Kim", code: "0123456789abcdef", leadSource: "nextdoor")),
                Decision(leadSource: "referral", referredByCustomerId: "c_sam"), "decision: a code wins over ?src=")
    expectEqual(decide(request(name: "Alex Kim", code: " 0123456789ABCDEF ")),
                Decision(leadSource: "referral", referredByCustomerId: "c_sam"), "decision: an older Worker's raw code is re-normalized")
    expectEqual(decide(request(name: "Alex Kim", code: "ghjkmnpqrstvwxyz")),
                Decision(leadSource: "referral", referredByCustomerId: nil), "decision: an unknown code is a referral with no referrer")
    expectEqual(decide(request(name: "Alex Kim", code: "zzzzzzzzzzzzzzzz")),
                Decision(leadSource: "referral", referredByCustomerId: nil), "decision: an ambiguous code is a referral with no referrer")
}

// MARK: - Credit balance (§5.1)

func testCreditBalance() {
    let customers = [
        customer("c_sam", "Sam Ortiz"),
        customer("c_alex", "Alex Kim", source: "referral", referrer: "c_sam", reward: reward("invoice_credit", 25)),
        customer("c_bea", "Bea Ray", source: "Word of mouth", referrer: "c_sam", reward: reward("invoice_credit", 10)),
        customer("c_cal", "Cal Ng", source: "referral", referrer: "c_sam", reward: reward("gift_card", 50)),
        customer("c_dee", "Dee Fox", source: "referral", referrer: "c_sam", reward: reward("thank_you")),
        // R1 violator: not a referral, so the promise does not count.
        customer("c_hal", "Hal Bo", source: "google", referrer: "c_sam", reward: reward("invoice_credit", 99)),
        customer("c_twin1", "Twin"), customer("c_twin2", "twin "),
    ]
    func balance(_ invoices: [Canonical.Invoice]) -> NativeReferrals.CreditBalance {
        NativeReferrals.creditBalance(referrerID: "c_sam", customers: customers, invoices: invoices)
    }
    let none = balance([])
    expectEqual(none.promised, 35, "credit: promised sums invoice_credit rewards only (R1)")
    expectEqual(none.applied, 0, "credit: nothing applied")
    expectEqual(none.owed, 35, "credit: owed is promised minus applied")

    let full = invoice("i1", customerId: "c_sam", name: "Sam Ortiz", amount: 975,
                       lines: [("Labor", 1000, "labor"), (NativeReferrals.creditLineDescription, -25, "referral_credit")])
    expectEqual(balance([full]).applied, 25, "credit: an applied line counts")
    expectEqual(balance([full]).owed, 10, "credit: owed after one credit")
    let partial = invoice("i2", customerId: nil, name: " sam ortiz", lines: [("Referral credit", -5, "referral_credit")])
    expectEqual(balance([full, partial]).owed, 5, "credit: a name-only invoice counts by unique name")
    let other = invoice("i3", customerId: "c_alex", name: "Alex Kim", lines: [("Referral credit", -10, "referral_credit")])
    expectEqual(balance([other]).applied, 0, "credit: another customer's credit line is not this referrer's")
    let ambiguous = invoice("i4", customerId: nil, name: "Twin", lines: [("Referral credit", -10, "referral_credit")])
    expectEqual(NativeReferrals.creditBalance(referrerID: "c_twin1", customers: customers, invoices: [ambiguous]).applied, 0,
                "credit: an ambiguous name is not guessed")
    expectEqual(balance([full]).owed, 10, "credit: deleting the second invoice re-opens its credit")
    let over = invoice("i5", customerId: "c_sam", name: "Sam Ortiz", lines: [("Referral credit", -100, "referral_credit")])
    expectEqual(balance([over]).owed, 0, "credit: owed never goes negative")
    expectEqual(NativeReferrals.appliedCredit(on: full), 25, "credit: appliedCredit reads the negative line")
    expectEqual(NativeReferrals.creditBalance(referrerID: "", customers: customers, invoices: [full]).owed, 0, "credit: blank referrer")
}

// MARK: - Rewards

func testRewards() {
    let credit = try? NativeReferrals.makeReward(kind: .invoiceCredit, amount: 25, note: "  Thanks!  ", recordedOn: "2026-10-03")
    expectEqual(credit?.kind, "invoice_credit", "reward: kind")
    expectEqual(credit?.amount, 25, "reward: amount")
    expectEqual(credit?.note, "Thanks!", "reward: note trimmed")
    expectEqual(credit.map(NativeReferrals.rewardStatusText), "Thanked \u{00B7} $25.00 credit \u{00B7} Oct 3", "reward: status text")
    func issue(_ body: () throws -> Canonical.Customer.ReferralReward) -> NativeReferrals.RewardIssue? {
        do { _ = try body(); return nil } catch { return error as? NativeReferrals.RewardIssue }
    }
    expectEqual(issue { try NativeReferrals.makeReward(kind: .invoiceCredit, amount: nil, note: nil, recordedOn: "2026-10-03") },
                .amountRequired, "reward: a credit needs an amount")
    expectEqual(issue { try NativeReferrals.makeReward(kind: .invoiceCredit, amount: 0, note: nil, recordedOn: "2026-10-03") },
                .amountRequired, "reward: a zero credit is no credit")
    expectEqual(issue { try NativeReferrals.makeReward(kind: .giftCard, amount: -5, note: nil, recordedOn: "2026-10-03") },
                .invalidAmount, "reward: a negative amount is refused")
    expectEqual(issue { try NativeReferrals.makeReward(kind: .other, amount: nil, note: nil, recordedOn: "10/03/2026") },
                .invalidDate, "reward: the date is a local YYYY-MM-DD")
    let note = try? NativeReferrals.makeReward(kind: .thankYou, amount: 40, note: String(repeating: "x", count: 250), recordedOn: "2026-09-28")
    expectEqual(note?.amount, nil, "reward: a thank-you note drops any amount")
    expectEqual(note?.note?.count, 200, "reward: notes cap at 200 characters")
    expectEqual(note.map(NativeReferrals.rewardStatusText), "Thanked \u{00B7} note \u{00B7} Sep 28", "reward: note status")
    let gift = try? NativeReferrals.makeReward(kind: .giftCard, amount: nil, note: " ", recordedOn: "2026-09-28")
    expectEqual(gift?.amount, nil, "reward: a gift card amount is optional")
    expectEqual(gift?.note, nil, "reward: a blank note is dropped")
    // The wire shape round-trips, unknown keys included.
    let wire = customer("c", "C", reward: ["kind": "gift_card", "amount": 30, "recordedOn": "2026-09-01", "vendor": "Cafe"])
    let reencoded = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(wire)) as! [String: Any]
    let rewardObject = reencoded["referralReward"] as? [String: Any]
    expectEqual(rewardObject?["vendor"] as? String, "Cafe", "reward: unknown keys survive a round trip")
    expectEqual(NativeReferrals.RewardKind.allCases.map(\.displayName),
                ["Thank-you note", "Gift card", "Credit on their next invoice", "Other"], "reward: picker labels")
}

// MARK: - Invoice credit line (§5.6)

func testCreditLineConstants() {
    expectEqual(JobInvoiceDomain.referralCreditCategory, NativeReferrals.creditLineCategory, "credit line: category matches")
    expectEqual(JobInvoiceDomain.referralCreditDescription, NativeReferrals.creditLineDescription, "credit line: description matches")
    expectEqual(NativeReferrals.creditLineDescription, "Referral credit \u{2014} thank you!", "credit line: spec copy")
}

// MARK: - Report (§5.7)

let reportCustomers: [Canonical.Customer] = [
    customer("c_sam", "Sam Ortiz", source: "google", createdAt: "2025-05-01", code: "0123456789abcdef"),
    customer("c_ana", "Ana Lee", source: "yelp", createdAt: "2025-06-01", archivedAt: "2026-08-01"),
    customer("c_alex", "Alex Kim", source: "referral", createdAt: "2026-09-02", referrer: "c_sam",
             reward: reward("invoice_credit", 25, on: "2026-09-10")),
    // 05:00Z on Oct 1 is 22:00 on Sep 30 in Phoenix: a September customer.
    customer("c_bea", "Bea Ray", source: "Word of mouth", createdAt: "2026-10-01T05:00:00.000Z", referrer: "c_sam"),
    customer("c_cal", "Cal Ng", source: "referral", createdAt: "2026-03-01", referrer: "c_ana",
             reward: reward("gift_card", 40, on: "2026-08-30")),
    customer("c_dee", "Dee Fox", source: "referral", createdAt: "2026-09-05", referrer: "c_gone"),
    customer("c_eve", "Eve Gold", source: "referral", createdAt: "2026-09-06"),
    // Same name, different referrers: a name-only invoice is ambiguous.
    customer("c_gus1", "Gus Pine", source: "referral", referrer: "c_sam"),
    customer("c_gus2", "gus pine", source: "referral", referrer: "c_ana"),
    // R1 violator: a referrer without a Referral source is ignored.
    customer("c_hal", "Hal Bo", source: "google", createdAt: "2026-09-07", referrer: "c_sam",
             reward: reward("invoice_credit", 99)),
    // Self-reference: "Referrer not recorded".
    customer("c_ivy", "Ivy Moss", source: "referral", referrer: "c_ivy"),
]

let reportInvoices: [Canonical.Invoice] = [
    invoice("i_alex", customerId: "c_alex", name: "Alex Kim", payments: [
        payment("p1", 600, "2026-09-03"),
        payment("p2", 100, "2026-09-04", voidedAt: "2026-09-05"),
        // 06:30Z on Oct 1 is 23:30 on Sep 30 in Phoenix: in September.
        payment("p3", 50, "2026-10-01T06:30:00Z"),
        payment("p4", 75, "2026-10-01"),
    ]),
    invoice("i_bea", customerId: nil, name: "bea ray ", payments: [payment("p5", 300, "2026-09-20")]),
    invoice("i_cal", customerId: "c_cal", name: "Cal Ng", payments: [payment("p6", 200, "2026-09-12")]),
    invoice("i_dee", customerId: "c_dee", name: "Dee Fox", payments: [payment("p7", 120, "2026-09-13")]),
    invoice("i_eve", customerId: "c_eve", name: "Eve Gold", payments: [payment("p8", 80, "2026-09-14")]),
    invoice("i_gus", customerId: nil, name: "Gus Pine", payments: [payment("p9", 60, "2026-09-15")]),
    invoice("i_hal", customerId: "c_hal", name: "Hal Bo", payments: [payment("p10", 500, "2026-09-16")]),
    invoice("i_ivy", customerId: "c_ivy", name: "Ivy Moss", payments: [payment("p11", 10, "2026-09-17")]),
    invoice("i_sam", customerId: "c_sam", name: "Sam Ortiz", payments: [payment("p12", 900, "2026-09-18")],
            lines: [("Labor", 925, "labor"), ("Referral credit", -25, "referral_credit")]),
]

func testReport() {
    let report = NativeReferralReport.make(customers: reportCustomers, invoices: reportInvoices,
                                           start: september.start, end: september.end)
    expectEqual(report.rows.map(\.id), ["referrer:c_sam", "referrer:c_ana", "former", "not_recorded"],
                "report: referrers by collected, then Former customer, then Referrer not recorded")
    let sam = report.rows.first { $0.id == "referrer:c_sam" }
    expectEqual(sam?.name, "Sam Ortiz", "report: referrer name")
    expectEqual(sam?.collected, 950, "report: Sam = Alex 600 + 50 (23:30 local on the last day) + Bea 300 by unique name; voided and next-day payments out")
    expectEqual(sam?.newReferred, 2, "report: Alex and Bea joined in September (Phoenix day)")
    expectEqual(sam?.referredAllTime, 3, "report: Alex, Bea and one Gus; the R1 violator Hal is not counted")
    expectEqual(sam?.creditOwed, 0, "report: Alex's $25 credit was applied on Sam's invoice")
    let ana = report.rows.first { $0.id == "referrer:c_ana" }
    expectEqual(ana?.collected, 200, "report: Ana = Cal")
    expectEqual(ana?.isArchived, true, "report: an archived referrer is labelled")
    expectEqual(ana?.newReferred, 0, "report: Cal joined in March")
    let former = report.rows.first { $0.id == "former" }
    expectEqual(former?.name, "Former customer", "report: a deleted referrer's row")
    expectEqual(former?.collected, 120, "report: Dee's payments go to Former customer")
    let notRecorded = report.rows.first { $0.id == "not_recorded" }
    expectEqual(notRecorded?.name, "Referrer not recorded", "report: catch-all name")
    expectEqual(notRecorded?.collected, 150, "report: Eve (missing) + Gus (ambiguous name) + Ivy (self-reference)")
    expectEqual(notRecorded?.referredAllTime, 2, "report: Eve and Ivy have no valid referrer")
    expectEqual(report.rewardsRecorded, 1, "report: one reward recorded in September (Alex); Cal's was in August; Hal breaks R1")
    expectEqual(report.rewardsAmount, 25, "report: reward amounts in the window")

    // Control total (§5.7): Σ rows == the lead-source `referral` row.
    let leadSources = NativeLeadSourceReport.make(customers: reportCustomers, jobs: [], invoices: reportInvoices,
                                                  start: september.start, end: september.end)
    let referralRow = leadSources.rows.first { $0.bucketKey == "referral" }
    expectEqual(report.totalCollected, referralRow?.collected ?? -1, "report: control total equals the lead-source referral row")
    expectEqual(report.totalCollected, 1420, "report: control total value")

    let august = NativeCashBasis.range(for: "this_month", now: NativeCashBasis.localDate(year: 2026, month: 7, day: 15))
    let augustReport = NativeReferralReport.make(customers: reportCustomers, invoices: reportInvoices,
                                                 start: august.start, end: august.end)
    expectEqual(augustReport.rewardsRecorded, 1, "report: Cal's reward lands in August")
    expectEqual(augustReport.rewardsAmount, 40, "report: August reward amount")
    expectEqual(augustReport.totalCollected, 0, "report: nothing collected in August")

    // Attribution parity: the referral rule and the generalized lead-source rule agree.
    let resolver = NativeReferrals.CustomerResolver(customers: reportCustomers)
    let attribution = NativeLeadSourceReport.Attribution(customers: reportCustomers) { $0.id }
    for invoice in reportInvoices {
        expectEqual(resolver.customerID(customerId: invoice.customerId, name: invoice.customer),
                    attribution.key(customerId: invoice.customerId, name: invoice.customer),
                    "attribution parity: \(invoice.id)")
    }
    // The default-key Attribution still buckets exactly as before.
    expectEqual(NativeLeadSourceReport.Attribution(customers: reportCustomers).bucket(customerId: nil, name: "Gus Pine"), "referral",
                "attribution: same-bucket duplicates still resolve by name")
}

func testGroupsAndSummary() {
    let groups = NativeReferralReport.groups(customers: reportCustomers, invoices: reportInvoices,
                                             start: september.start, end: september.end)
    expectEqual(groups.map(\.id), ["referrer:c_sam", "referrer:c_ana", "former", "not_recorded"], "groups: one section per row")
    let samEntries = groups.first?.entries ?? []
    expectEqual(samEntries.map(\.id), ["c_bea", "c_alex", "c_gus1"], "groups: newest first, a missing date last")
    expectEqual(samEntries.first { $0.id == "c_alex" }?.collected, 650, "groups: Alex's collected in the window")
    expectEqual(samEntries.first { $0.id == "c_alex" }?.rewardStatus, "Thanked \u{00B7} $25.00 credit \u{00B7} Sep 10", "groups: reward status")
    expectEqual(samEntries.first { $0.id == "c_bea" }?.rewardStatus, "Not thanked yet", "groups: no reward")
    expectEqual(samEntries.first { $0.id == "c_bea" }?.joinedText, "Joined Sep 30, 2026", "groups: joined on the local day")

    let sam = NativeReferralReport.customerSummary(customerID: "c_sam", customers: reportCustomers, invoices: reportInvoices)
    expectEqual(sam?.referredBy, NativeReferralCustomerSummary.ReferredBy.none, "summary: Sam has no referrer")
    expectEqual(sam?.referred.map(\.id), ["c_bea", "c_alex", "c_gus1"], "summary: everyone Sam referred")
    expectEqual(sam?.collectedTotal, 1025, "summary: all-time collected (Alex 725 + Bea 300; Gus is ambiguous)")
    expectEqual(sam?.summaryText, "Referred 3 \u{00B7} $1,025.00 collected", "summary: text")
    expectEqual(sam?.hasCode, true, "summary: Sam has a code")
    expectEqual(NativeReferralReport.customerSummary(customerID: "c_alex", customers: reportCustomers, invoices: reportInvoices)?.referredBy,
                .customer(id: "c_sam", name: "Sam Ortiz", isArchived: false), "summary: Alex was referred by Sam")
    expectEqual(NativeReferralReport.customerSummary(customerID: "c_cal", customers: reportCustomers, invoices: reportInvoices)?.referredBy,
                .customer(id: "c_ana", name: "Ana Lee", isArchived: true), "summary: an archived referrer")
    expectEqual(NativeReferralReport.customerSummary(customerID: "c_dee", customers: reportCustomers, invoices: reportInvoices)?.referredBy,
                .formerCustomer, "summary: a deleted referrer reads as a former customer")
    expectEqual(NativeReferralReport.customerSummary(customerID: "c_hal", customers: reportCustomers, invoices: reportInvoices)?.referredBy,
                NativeReferralCustomerSummary.ReferredBy.none, "summary: an R1 violator shows no referrer")
    expectEqual(NativeReferralReport.customerSummary(customerID: "c_missing", customers: reportCustomers, invoices: reportInvoices), nil,
                "summary: nil for an unknown customer")
}

// MARK: - Coach block (§5.8)

func testCoachBlock() {
    let block = NativeReferralSnapshotBlock(
        newReferred: 3, collected: 2400,
        topReferrers: [NativeReferralSnapshotRow(name: "Sam Ortiz", referred: 2, collected: 1800),
                       NativeReferralSnapshotRow(name: "Ana Lee", referred: 1, collected: 600)],
        rewardsRecorded: 1, rewardsAmount: 25
    )
    expectEqual(NativeCoachPrompt.referralsBlock(block),
                "REFERRALS (year to date): 3 new referred customers; $2400 collected from referred customers. Top referrers: Sam Ortiz (2 referred, $1800 collected); Ana Lee (1 referred, $600 collected). Rewards recorded: 1 ($25). These referral figures are computed from the owner's records. Cite them exactly; never estimate figures for a referrer who isn't listed. Rewards are recorded by the owner; never promise, calculate or send a reward on the owner's behalf.",
                "coach: the exact block")
    let single = NativeReferralSnapshotBlock(newReferred: 1, collected: 0, topReferrers: [], rewardsRecorded: 0, rewardsAmount: 0)
    expect(NativeCoachPrompt.referralsBlock(single).hasPrefix(
        "REFERRALS (year to date): 1 new referred customer; $0 collected from referred customers. Rewards recorded: none. "),
           "coach: singular, no top referrers, no rewards")

    let built = NativeReferralReport.snapshotBlock(customers: reportCustomers, invoices: reportInvoices, now: sep15)
    expectEqual(built?.topReferrers.map(\.name), ["Sam Ortiz", "Ana Lee"], "coach: top referrers from the year-to-date report")
    expectEqual(built?.collected, 1495, "coach: year-to-date collected from referred customers (Oct 1 is this year too)")
    expectEqual(built?.newReferred, 5, "coach: Alex, Bea, Cal, Dee and Eve joined this year")
    expectEqual(built?.rewardsRecorded, 2, "coach: Alex's and Cal's rewards this year")
    let noReferrer = [customer("c1", "A", source: "referral"), customer("c2", "B", source: "google", referrer: "c1")]
    expectEqual(NativeReferralReport.snapshotBlock(customers: noReferrer, invoices: [], now: sep15), nil,
                "coach: absent when no customer has a referrer (R1)")
}

// MARK: - Today insight (§5.7, D8)

func testThanksInsight() {
    // Sep 15 minus 60 days is Jul 17.
    let base = [
        customer("c_sam", "Sam Ortiz"),
        customer("c_alex", "Alex Kim", source: "referral", referrer: "c_sam"),
    ]
    func insights(_ customers: [Canonical.Customer], _ invoices: [Canonical.Invoice]) -> [NativeTodayInsight] {
        NativeTodayInsights.selectReferralThanks(customers: customers, invoices: invoices, now: sep15)
    }
    let inside = [invoice("i1", customerId: "c_alex", name: "Alex Kim", payments: [
        payment("p1", 1000, "2026-07-17"), payment("p2", 240, "2026-08-02"), payment("p3", 50, "2026-08-03", voidedAt: "2026-08-04"),
    ])]
    let hit = insights(base, inside)
    expectEqual(hit.count, 1, "insight: a first payment 60 days ago is inside the window")
    expectEqual(hit.first?.kind, .referralThanks, "insight: kind")
    expectEqual(hit.first?.id, "referral_thanks:c_alex", "insight: id")
    expectEqual(hit.first?.title, "Thank Sam for referring Alex", "insight: title")
    expectEqual(hit.first?.detail, "Alex has paid $1,240.00 so far.", "insight: detail excludes voided payments")
    expectEqual(hit.first?.reason, "Alex was referred by Sam and paid for the first time on Jul 17. No thank-you is recorded yet.",
                "insight: reason")
    expectEqual(hit.first?.target, .customer(customerId: "c_sam"), "insight: opens the referrer")
    expectEqual(hit.first?.coachPrompt, "Help me write a short thank-you text to Sam for referring Alex.", "insight: coach prompt")
    expectEqual(NativeInsightKind.referralThanks.rawValue, "referral_thanks", "insight: wire kind")
    expect(!NativeInsightKind.referralThanks.isInAnalyticsCatalog, "insight: kept out of the analytics catalog")
    expect(NativeInsightKind.expenseAnomaly.isInAnalyticsCatalog, "insight: catalog kinds stay in")

    // 06:30Z on Jul 17 is 23:30 on Jul 16 in Phoenix: day 61, outside.
    let boundary = [invoice("i1", customerId: "c_alex", name: "Alex Kim", payments: [payment("p1", 100, "2026-07-17T06:30:00Z")])]
    expect(insights(base, boundary).isEmpty, "insight: the Phoenix day boundary puts 23:30 local on Jul 16 outside")
    let earlier = [invoice("i1", customerId: "c_alex", name: "Alex Kim", payments: [
        payment("p0", 100, "2026-07-01"), payment("p1", 100, "2026-09-01"),
    ])]
    expect(insights(base, earlier).isEmpty, "insight: only the FIRST payment counts")
    let voidedFirst = [invoice("i1", customerId: "c_alex", name: "Alex Kim", payments: [
        payment("p0", 100, "2026-07-01", voidedAt: "2026-07-02"), payment("p1", 100, "2026-09-01"),
    ])]
    expectEqual(insights(base, voidedFirst).count, 1, "insight: a voided payment is not the first payment")
    let byName = [invoice("i1", customerId: nil, name: "alex kim", payments: [payment("p1", 100, "2026-09-01")])]
    expectEqual(insights(base, byName).count, 1, "insight: payments attribute by unique name")

    let thanked = [customer("c_sam", "Sam Ortiz"),
                   customer("c_alex", "Alex Kim", source: "referral", referrer: "c_sam", reward: reward("thank_you"))]
    expect(insights(thanked, inside).isEmpty, "insight: a recorded reward clears it")
    let dangling = [customer("c_alex", "Alex Kim", source: "referral", referrer: "c_gone")]
    expect(insights(dangling, inside).isEmpty, "insight: a dangling referrer suppresses it")
    let violator = [customer("c_sam", "Sam Ortiz"), customer("c_alex", "Alex Kim", source: "google", referrer: "c_sam")]
    expect(insights(violator, inside).isEmpty, "insight: an R1 violator is ignored")

    let three = base + [customer("c_bo", "Bo Lane", source: "referral", referrer: "c_sam"),
                        customer("c_al", "Al Bee", source: "referral", referrer: "c_sam")]
    let mixed = [
        invoice("i1", customerId: "c_alex", name: "Alex Kim", payments: [payment("p1", 100, "2026-09-10")]),
        invoice("i2", customerId: "c_bo", name: "Bo Lane", payments: [payment("p2", 100, "2026-09-12")]),
        invoice("i3", customerId: "c_al", name: "Al Bee", payments: [payment("p3", 100, "2026-09-12")]),
    ]
    let capped = insights(three, mixed)
    expectEqual(capped.map(\.id), ["referral_thanks:c_al"], "insight: one row, the most recent first payment, ties by name")
    let all = NativeTodayInsights.select(jobs: [], invoices: mixed, now: sep15, customers: three)
    expectEqual(all.last?.kind, .referralThanks, "insight: runs last in select")
}

testFixtureVectors()
testEncoding()
testMakeCode()
testResolution()
testSelfReferral()
testLinks()
testCopy()
testReferralDecision()
testCreditBalance()
testRewards()
testCreditLineConstants()
testReport()
testGroupsAndSummary()
testCoachBlock()
testThanksInsight()

if failures == 0 {
    print("referral tests: all \(checks) checks passed")
} else {
    print("referral tests: \(failures) of \(checks) checks FAILED")
    exit(1)
}
