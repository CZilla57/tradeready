import Foundation

/// Phase 18 (Tap to Pay on iPhone, spec 2026-10-03 §3, §4.1, §5): the pure
/// rules. Foundation + the canonical model only, so the host harness compiles
/// it alone.
///
/// MONEY RULES
/// - Amounts are INTEGER CENTS everywhere in the native app. Dollars appear
///   exactly once, at the transport edge (`NativeTerminalService`), where the
///   Worker's contract wants dollars.
/// - A charge never exceeds the invoice's live balance (`validate`), and the
///   amount the Worker echoes back must equal what was asked for.
/// - The ledger entry is byte-identical to the Worker webhook's copy.
enum NativeCardPresentPayment {
    /// The ledger `method`. Never a new value (spec §3): `stripe` is already
    /// "money that arrived through Stripe".
    static let method = "stripe"
    static let channel = "card_present"
    static let idPrefix = "stripe_"
    /// Stripe's USD ceiling for one charge ($999,999.99); the Worker enforces
    /// the same bound.
    static let maxChargeCents = 99_999_999
    /// Stripe's USD floor for one charge ($0.50); the Worker enforces the same
    /// bound (`below_minimum`). USD is the spec's only currency.
    static let minimumChargeCents = 50

    // MARK: - Eligibility

    enum Ineligibility: Equatable {
        /// The capability flag is off (build flag, SDK, device or owner opt-in).
        case featureUnavailable
        case stripeNotConnected
        /// Onboarding is incomplete, or the Worker predates `charges_enabled`.
        case chargesNotEnabled
        case invoicePaid
    }

    /// Why Tap to Pay cannot be offered right now, or nil when it can. The
    /// Stripe status must positively say charges are enabled: an unknown value
    /// (an older Worker) is never treated as enabled.
    static func ineligibility(
        capabilityAvailable: Bool,
        status: NativeStripeConnectStatus?,
        invoiceBalanceCents: Int
    ) -> Ineligibility? {
        guard capabilityAvailable else { return .featureUnavailable }
        guard let status, status.connected else { return .stripeNotConnected }
        guard status.detailsSubmitted, status.chargesEnabled == true else { return .chargesNotEnabled }
        if let capability = status.cardPaymentsCapability, capability != "active" { return .chargesNotEnabled }
        guard invoiceBalanceCents > 0 else { return .invoicePaid }
        return nil
    }

    // MARK: - Amount

    enum AmountCheck: Equatable {
        case ok
        case notPositive
        case exceedsBalance(balanceCents: Int)
        /// Under Stripe's minimum: too small to take by card at all.
        case belowMinimum
        case tooLarge
    }

    /// `minimum <= amount <= balance` (and Stripe's ceiling). A partial amount
    /// is allowed (deposits and part payments, D10). A balance under the
    /// minimum cannot be taken by card at all.
    static func validate(amountCents: Int, balanceCents: Int) -> AmountCheck {
        if amountCents <= 0 { return .notPositive }
        if amountCents > balanceCents { return .exceedsBalance(balanceCents: max(0, balanceCents)) }
        if amountCents < minimumChargeCents { return .belowMinimum }
        if amountCents > maxChargeCents { return .tooLarge }
        return .ok
    }

    /// Whole cents from a typed dollar amount, or nil when it is not an exact
    /// number of cents (so `12.345` is refused rather than rounded into a
    /// charge the owner did not type).
    static func cents(fromDollars dollars: Double) -> Int? {
        guard dollars.isFinite, dollars >= 0, dollars < 10_000_000 else { return nil }
        let scaled = dollars * 100
        let rounded = scaled.rounded()
        guard abs(scaled - rounded) < 1e-6 else { return nil }
        return Int(rounded)
    }

    /// The dollars an integer-cent amount displays as. Display only; never
    /// feed this back into a charge.
    static func dollars(fromCents cents: Int) -> Double { Double(cents) / 100 }

    // MARK: - Identifiers

    /// One per sheet. A retry after a network error reuses it so Stripe's
    /// idempotency key returns the same PaymentIntent. Matches the Worker's
    /// `[A-Za-z0-9_-]{8,64}`.
    static func newOperationID() -> String {
        "ttp_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    static func isValidOperationID(_ value: String) -> Bool {
        (8...64).contains(value.count) && value.unicodeScalars.allSatisfy {
            ($0.value >= 48 && $0.value <= 57) || ($0.value >= 65 && $0.value <= 90)
                || ($0.value >= 97 && $0.value <= 122) || $0 == "_" || $0 == "-"
        }
    }

    static func isValidPaymentIntentID(_ value: String) -> Bool {
        guard value.hasPrefix("pi_"), value.count > 3, value.count <= 255 else { return false }
        return value.unicodeScalars.allSatisfy {
            ($0.value >= 48 && $0.value <= 57) || ($0.value >= 65 && $0.value <= 90)
                || ($0.value >= 97 && $0.value <= 122) || $0 == "_"
        }
    }

    /// The invoice number as it goes into the PaymentIntent description: one
    /// clean line of at most 64 characters, or nil. Frozen with the operation
    /// (the description is part of Stripe's idempotency parameters, so it must
    /// not change between retries).
    static func cleanInvoiceNumber(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty,
              trimmed.count <= 64,
              !trimmed.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 })
        else { return nil }
        return trimmed
    }

    static func ledgerID(paymentIntentID: String) -> String { idPrefix + paymentIntentID }

    /// The device-local calendar day, `YYYY-MM-DD` (D5). The Worker carries the
    /// same string in PaymentIntent metadata for its copy.
    static func localDate(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    // MARK: - Ledger entry

    enum EntryError: Error, Equatable { case invalidPaymentIntentID, invalidAmount, invalidDate, encoding }

    /// The canonical payment for an approved card-present charge. Exactly
    /// `id, amount, date, method, stripePaymentIntentId, channel`: no `note`
    /// and no `voidedAt` nulls, so the device and webhook copies are
    /// byte-identical and the union trigger's id collision is a no-op.
    static func ledgerEntry(paymentIntentId: String, amountCents: Int, localDate: String) throws -> Canonical.Payment {
        guard isValidPaymentIntentID(paymentIntentId) else { throw EntryError.invalidPaymentIntentID }
        guard amountCents > 0, amountCents <= maxChargeCents else { throw EntryError.invalidAmount }
        guard isValidLocalDate(localDate) else { throw EntryError.invalidDate }
        let fields: [String: Canonical.JSONValue] = [
            "id": .string(ledgerID(paymentIntentID: paymentIntentId)),
            "amount": .number(Decimal(amountCents) / 100),
            "date": .string(localDate),
            "method": .string(method),
            "stripePaymentIntentId": .string(paymentIntentId),
            "channel": .string(channel),
        ]
        do {
            return try JSONDecoder().decode(Canonical.Payment.self, from: JSONEncoder().encode(fields))
        } catch {
            throw EntryError.encoding
        }
    }

    static func isValidLocalDate(_ value: String) -> Bool {
        let pieces = value.split(separator: "-", omittingEmptySubsequences: false)
        guard pieces.count == 3, pieces[0].count == 4, pieces[1].count == 2, pieces[2].count == 2,
              let y = Int(pieces[0]), let m = Int(pieces[1]), let d = Int(pieces[2]),
              (1...12).contains(m), (1...31).contains(d) else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        let parts = DateComponents(calendar: calendar, year: y, month: m, day: d)
        guard let date = calendar.date(from: parts) else { return false }
        let back = calendar.dateComponents([.year, .month, .day], from: date)
        return back.year == y && back.month == m && back.day == d
    }

    // MARK: - Display and copy

    /// The label for a stored `(method, channel)` pair (spec §3, D6). The PDF
    /// is unchanged: it prints "Card" for both.
    static func displayLabel(method: String, channel: String?) -> String {
        guard method.lowercased() == "stripe" else { return method }
        return channel == self.channel ? "Tap to Pay" : "Card (online)"
    }

    static func isStripePayment(id: String) -> Bool { id.hasPrefix(idPrefix) }

    /// Extra sentence for the void confirmation of a Stripe payment (also link
    /// payments). Voiding moves no money (R9).
    /// The sheet's copy for an amount under Stripe's minimum (the Worker's
    /// `below_minimum`, or the same check made on the device first).
    static var belowMinimumMessage: String {
        let minimum = String(format: "$%.2f", dollars(fromCents: minimumChargeCents))
        return "That amount is too small to take by card. The minimum card payment is \(minimum)."
    }

    static let voidNotice = "Voiding only changes your records. It doesn't refund the card. Refund it in your Stripe dashboard."
}
