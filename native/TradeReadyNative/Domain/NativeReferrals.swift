import Foundation

/// Phase 34 (referral program, spec
/// `docs/superpowers/specs/2026-10-03-referral-program-design.md` §2, §5.1,
/// §10.3): pure referral rules. Depends on `CanonicalModels` and
/// `NativeLeadSource` only, and randomness is injected, so every runner that
/// compiles a capture point (booking intake, the editor, merge, reports,
/// insights) can include it.
///
/// A referral code is an attribution hint, never a capability: 80 random bits
/// as 16 lowercase Crockford base32 characters, stored on the customer the
/// first time the owner shares their link. The Worker only format-checks it;
/// the device resolves it at intake against the customers it already holds.
enum NativeReferrals {
    static let codeAlphabet = Array("0123456789abcdefghjkmnpqrstvwxyz")
    static let codeByteCount = 10            // 80 bits
    static let codeLength = 16
    static let codePattern = "^[0-9a-hjkmnp-tv-z]{16}$"
    static let creditLineCategory = "referral_credit"
    static let creditLineDescription = "Referral credit \u{2014} thank you!"
    static let thanksWindowDays = 60
    static let rewardNoteMaxLength = 200
    /// `generateCode` gives up (fails closed) after this many collisions.
    static let maxCodeAttempts = 3
    /// The Phase 27 preset key every referral carries (`NativeLeadSource`).
    static let referralSourceKey = "referral"
    /// Report row label for a referrer whose record was deleted.
    static let formerCustomerName = "Former customer"
    /// Report row label for a referral whose referrer is missing or ambiguous.
    static let notRecordedName = "Referrer not recorded"

    private static let alphabetSet = Set(codeAlphabet)

    // MARK: - Codes

    /// Exactly 10 bytes → 16 characters, most significant bit first (5 bits
    /// per character). Any other count is nil.
    static func encodeCode(_ bytes: [UInt8]) -> String? {
        guard bytes.count == codeByteCount else { return nil }
        var buffer: UInt32 = 0
        var bits = 0
        var out: [Character] = []
        out.reserveCapacity(codeLength)
        for byte in bytes {
            buffer = (buffer << 8) | UInt32(byte)
            bits += 8
            while bits >= 5 {
                bits -= 5
                out.append(codeAlphabet[Int((buffer >> UInt32(bits)) & 31)])
            }
            buffer &= (UInt32(1) << UInt32(bits)) - 1
        }
        return String(out)
    }

    /// `.whitespacesAndNewlines` without U+200B ZERO WIDTH SPACE: Apple's
    /// Foundation trims it but JavaScript's `trim()` does not, and the shared
    /// vectors require it to be rejected (§10.2 item 2).
    private static let codeTrimSet = CharacterSet.whitespacesAndNewlines
        .subtracting(CharacterSet(charactersIn: "\u{200B}"))

    /// §10.3 device rule: trim whitespace and newlines, require every scalar
    /// to be ASCII **before** lowercasing (U+212A KELVIN SIGN lowercases to
    /// `k`), lowercase, then match `^[0-9a-hjkmnp-tv-z]{16}$`. Anything else
    /// is nil.
    static func normalizeCode(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: codeTrimSet)
        guard trimmed.unicodeScalars.allSatisfy(\.isASCII) else { return nil }
        let lowered = trimmed.lowercased()
        guard lowered.count == codeLength, lowered.allSatisfy({ alphabetSet.contains($0) }) else { return nil }
        return lowered
    }

    /// A fresh code that collides with nothing in `existing`. At most
    /// `maxCodeAttempts` draws; nil when the RNG fails (nil or the wrong byte
    /// count) or every draw collides, so a caller never stores a duplicate.
    static func makeCode(existing: Set<String>, randomBytes: (Int) -> [UInt8]?) -> String? {
        for _ in 0..<maxCodeAttempts {
            guard let bytes = randomBytes(codeByteCount), let code = encodeCode(bytes) else { return nil }
            if !existing.contains(code) { return code }
        }
        return nil
    }

    /// Every stored code and alias (normalized; invalid values skipped).
    static func allCodes(in customers: [Canonical.Customer]) -> Set<String> {
        var codes = Set<String>()
        for customer in customers {
            for value in [customer.referralCode] + (customer.referralCodeAliases ?? []).map(Optional.some) {
                if let code = normalizeCode(value) { codes.insert(code) }
            }
        }
        return codes
    }

    /// The customer whose code or alias is exactly `code` (after
    /// normalization). Archived customers resolve. Nil for an unusable code,
    /// no match, or more than one matching customer (R2: fail closed).
    static func resolveReferrer(code: String?, customers: [Canonical.Customer]) -> Canonical.Customer? {
        guard let code = normalizeCode(code) else { return nil }
        let matches = customers.filter { customer in
            normalizeCode(customer.referralCode) == code
                || (customer.referralCodeAliases ?? []).contains { normalizeCode($0) == code }
        }
        guard matches.count == 1 else { return nil }
        return matches[0]
    }

    /// D5: the booker *is* the referrer when the name-matched customer is the
    /// referrer, the trimmed lowercased emails match (non-empty), or the phone
    /// digits match (last 10, at least 7 digits).
    static func isSelfReferral(
        referrer: Canonical.Customer,
        matchedCustomerID: String?,
        email: String,
        phone: String
    ) -> Bool {
        if let matchedCustomerID, !matchedCustomerID.isEmpty, matchedCustomerID == referrer.id { return true }
        let bookerEmail = emailKey(email)
        if !bookerEmail.isEmpty, bookerEmail == emailKey(referrer.email) { return true }
        let bookerPhone = phoneKey(phone)
        if !bookerPhone.isEmpty, bookerPhone == phoneKey(referrer.phone) { return true }
        return false
    }

    static func emailKey(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Digits only, the last 10, and empty when fewer than 7 digits remain.
    static func phoneKey(_ value: String) -> String {
        let digits = value.unicodeScalars.filter { (48...57).contains(Int($0.value)) }.map(String.init).joined()
        guard digits.count >= 7 else { return "" }
        return String(digits.suffix(10))
    }

    // MARK: - Links and copy

    /// The booking URL plus `r=<code>`. Requires a `b` item and no existing
    /// `r`, and a code that is already canonical.
    static func referralURL(bookingURL: URL, code: String) -> URL? {
        guard normalizeCode(code) == code,
              var components = URLComponents(url: bookingURL, resolvingAgainstBaseURL: false)
        else { return nil }
        var items = components.queryItems ?? []
        guard items.contains(where: { $0.name == "b" && !($0.value ?? "").isEmpty }),
              !items.contains(where: { $0.name == "r" })
        else { return nil }
        items.append(URLQueryItem(name: "r", value: code))
        components.queryItems = items
        return components.url
    }

    /// §5.5 share message. A blank name reads "Hi there"; a blank business
    /// name reads "us".
    static func renderShareMessage(customerName: String, businessName: String, link: URL) -> String {
        let name = customerName.trimmingCharacters(in: .whitespacesAndNewlines)
        let business = businessName.trimmingCharacters(in: .whitespacesAndNewlines)
        return "Hi \(name.isEmpty ? "there" : name), thanks again for choosing \(business.isEmpty ? "us" : business)! "
            + "If you know anyone who needs a hand, here's a booking link you can pass along: \(link.absoluteString)"
            + "\nWhen they book through it, we'll know they came from you."
    }

    static func referralParagraph(link: URL) -> String {
        "Know someone who could use a hand? Pass along your personal booking link: \(link.absoluteString)"
    }

    /// Adds the review-request paragraph once: a message that already holds
    /// the link is returned unchanged.
    static func appendingReferralParagraph(to message: String, link: URL) -> String {
        guard !message.contains(link.absoluteString) else { return message }
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let paragraph = referralParagraph(link: link)
        return trimmed.isEmpty ? paragraph : trimmed + "\n\n" + paragraph
    }

    // MARK: - Link state copy (§5.5, shared by the share view and the review sheet)

    static let checkingLinkText = "Checking your booking link\u{2026}"
    static let bookingLinkOffText = "Turn on your booking link in Settings \u{2192} Booking link to share referral links."
    static let unverifiedText = "Couldn't verify your booking link. Check your connection and try again."
    static let unavailableText = "This customer's referral link couldn't be created. Try again."

    // MARK: - Attribution (R1)

    static func isReferralSource(_ leadSource: String?) -> Bool {
        NativeLeadSource.normalize(leadSource) == referralSourceKey
    }

    /// R1: the referrer id only while it is set, the source is `referral`
    /// and it is not the customer itself. Everything that reads a referral
    /// (reports, the insight, the detail section) goes through this.
    static func validReferrerID(of customer: Canonical.Customer) -> String? {
        guard let referrer = customer.referredByCustomerId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !referrer.isEmpty, referrer != customer.id, isReferralSource(customer.leadSource)
        else { return nil }
        return referrer
    }

    /// The editor/merge rule: the candidate survives only under R1.
    static func sanitizedReferrer(_ candidate: String?, customerID: String, leadSource: String?) -> String? {
        guard let candidate = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
              !candidate.isEmpty, candidate != customerID, isReferralSource(leadSource)
        else { return nil }
        return candidate
    }

    /// True when at least one customer has a recorded referrer (R1), live or
    /// dangling. Gates the Money card and the coach block.
    static func anyReferrer(in customers: [Canonical.Customer]) -> Bool {
        customers.contains { validReferrerID(of: $0) != nil }
    }

    /// The lead-source report's id-first / unique-name rule keyed on the
    /// customer id: `customerId` when it names a known customer, else the one
    /// customer with that normalized name, else nil (missing or ambiguous).
    struct CustomerResolver {
        private var ids: Set<String> = []
        private var idsByName: [String: Set<String>] = [:]

        init(customers: [Canonical.Customer]) {
            for customer in customers where !customer.id.isEmpty {
                ids.insert(customer.id)
                let name = NativeReferrals.normalizedName(customer.name)
                if !name.isEmpty { idsByName[name, default: []].insert(customer.id) }
            }
        }

        func customerID(customerId: String?, name: String) -> String? {
            if let customerId, !customerId.isEmpty, ids.contains(customerId) { return customerId }
            let key = NativeReferrals.normalizedName(name)
            guard !key.isEmpty, let matches = idsByName[key], matches.count == 1 else { return nil }
            return matches.first
        }
    }

    static func normalizedName(_ value: String?) -> String {
        (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// The first word of a trimmed name, for "Thank Sam for referring Alex".
    static func firstName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? trimmed
    }

    // MARK: - Credits (derived, never stored)

    struct CreditBalance: Equatable {
        /// Σ `invoice_credit` reward amounts over customers this referrer referred.
        var promised: Decimal
        /// Σ −amount of `referral_credit` lines on invoices attributed to the referrer.
        var applied: Decimal
        var owed: Decimal { max(0, promised - applied) }
    }

    static func creditBalance(
        referrerID: String,
        customers: [Canonical.Customer],
        invoices: [Canonical.Invoice]
    ) -> CreditBalance {
        guard !referrerID.isEmpty else { return CreditBalance(promised: 0, applied: 0) }
        var promised = Decimal.zero
        for customer in customers where validReferrerID(of: customer) == referrerID {
            guard let reward = customer.referralReward, reward.kind == RewardKind.invoiceCredit.rawValue,
                  let amount = reward.amount, amount > 0
            else { continue }
            promised += amount
        }
        let resolver = CustomerResolver(customers: customers)
        var applied = Decimal.zero
        for invoice in invoices where resolver.customerID(customerId: invoice.customerId, name: invoice.customer) == referrerID {
            applied += appliedCredit(on: invoice)
        }
        return CreditBalance(promised: promised, applied: applied)
    }

    /// Σ −amount of the invoice's `referral_credit` lines (a positive figure).
    static func appliedCredit(on invoice: Canonical.Invoice) -> Decimal {
        (invoice.lineItems ?? []).reduce(Decimal.zero) { total, line in
            line.category == creditLineCategory ? total - line.amount : total
        }
    }

    // MARK: - Rewards (§5.6)

    enum RewardKind: String, CaseIterable, Identifiable {
        case thankYou = "thank_you"
        case giftCard = "gift_card"
        case invoiceCredit = "invoice_credit"
        case other

        var id: String { rawValue }

        /// The picker label.
        var displayName: String {
            switch self {
            case .thankYou: "Thank-you note"
            case .giftCard: "Gift card"
            case .invoiceCredit: "Credit on their next invoice"
            case .other: "Other"
            }
        }

        /// The status-line label ("Thanked · $25.00 credit · Oct 3").
        var statusLabel: String {
            switch self {
            case .thankYou: "note"
            case .giftCard: "gift card"
            case .invoiceCredit: "credit"
            case .other: "other"
            }
        }

        var takesAmount: Bool { self != .thankYou }
        var requiresAmount: Bool { self == .invoiceCredit }
    }

    enum RewardIssue: Error, Equatable {
        case amountRequired
        case invalidAmount
        case invalidDate
    }

    /// A validated reward record. A thank-you note drops any amount; a credit
    /// needs one > 0; gift card and other take an optional amount > 0. The
    /// note is trimmed, capped at 200 characters and dropped when blank.
    static func makeReward(
        kind: RewardKind,
        amount: Decimal?,
        note: String?,
        recordedOn: String
    ) throws -> Canonical.Customer.ReferralReward {
        guard isLocalDate(recordedOn) else { throw RewardIssue.invalidDate }
        var fields: [String: Canonical.JSONValue] = [
            "kind": .string(kind.rawValue), "recordedOn": .string(recordedOn),
        ]
        if kind.takesAmount, let amount, amount != 0 {
            guard amount > 0 else { throw RewardIssue.invalidAmount }
            fields["amount"] = .number(amount)
        } else if kind.requiresAmount {
            throw RewardIssue.amountRequired
        }
        let trimmed = String((note ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(rewardNoteMaxLength))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { fields["note"] = .string(trimmed) }
        let data = try JSONEncoder().encode(fields)
        return try JSONDecoder().decode(Canonical.Customer.ReferralReward.self, from: data)
    }

    /// "Thanked · $25.00 credit · Oct 3", "Thanked · note · Oct 3".
    static func rewardStatusText(_ reward: Canonical.Customer.ReferralReward) -> String {
        let kind = RewardKind(rawValue: reward.kind)
        var parts = ["Thanked"]
        if let amount = reward.amount, amount > 0 {
            parts.append("\(money(amount)) \(kind?.statusLabel ?? "reward")")
        } else {
            parts.append(kind?.statusLabel ?? "reward")
        }
        if let day = shortDate(reward.recordedOn) { parts.append(day) }
        return parts.joined(separator: " \u{00B7} ")
    }

    static let notThankedText = "Not thanked yet"

    // MARK: - Formatting (pure; no Money-card dependency)

    private static let monthAbbreviations = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
                                             "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    static func isLocalDate(_ value: String) -> Bool {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard value.count == 10, parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              Int(parts[0]) != nil, let month = Int(parts[1]), let day = Int(parts[2])
        else { return false }
        return (1...12).contains(month) && (1...31).contains(day)
    }

    /// "Oct 3" for `2026-10-03` (string math only, FA-039 safe).
    static func shortDate(_ ymd: String) -> String? {
        guard isLocalDate(ymd) else { return nil }
        let parts = ymd.split(separator: "-")
        guard let month = Int(parts[1]), let day = Int(parts[2]) else { return nil }
        return "\(monthAbbreviations[month - 1]) \(day)"
    }

    /// "$1,240.00".
    static func money(_ value: Decimal) -> String {
        moneyFormatter.string(from: NSDecimalNumber(decimal: value)) ?? "$0.00"
    }

    private static let moneyFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.locale = Locale(identifier: "en_US")
        formatter.currencyCode = "USD"
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter
    }()
}

/// What `AppStore.referralShareLink(customerID:)` found (§5.2).
enum NativeReferralLinkState: Equatable {
    case ready(URL)
    /// No verified share URL, or the link is turned off: a disabled link would
    /// show the new customer "This link is invalid."
    case bookingLinkOff
    /// The status read failed (offline, signed out, server error).
    case unverified
    /// The customer is gone, or no code could be generated.
    case unavailable

    var message: String? {
        switch self {
        case .ready: nil
        case .bookingLinkOff: NativeReferrals.bookingLinkOffText
        case .unverified: NativeReferrals.unverifiedText
        case .unavailable: NativeReferrals.unavailableText
        }
    }
}
