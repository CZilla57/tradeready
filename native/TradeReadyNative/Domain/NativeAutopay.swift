import Foundation

/// Phase 24 §6.3 (card on file + autopay for recurring invoices): the owner
/// app's pure autopay policy. It decodes the Worker's
/// `GET /api/autopay/status` body, derives each plan's status and each plan
/// invoice's one-line banner, and owns every display string, so the views
/// only lay text out.
///
/// The server owns eligibility and charging (spec §4.6). Nothing here decides
/// whether a charge happens: the banner only predicts it from the rules the
/// owner can see (an active card, the plan offering autopay, the amount
/// ceiling, the due-date window), and a server charge row always wins.
///
/// Foundation only, so `run-autopay-tests.sh` compiles it alone.
enum NativeAutopay {
    /// The ledger's half-cent rule (`PaymentLedger.paidEpsilon`), duplicated
    /// deliberately so this file stays standalone-compilable.
    static let epsilon = Decimal(string: "0.005")!
    /// Foreground refreshes run at most this often (spec §6.3).
    static let foregroundRefreshInterval: TimeInterval = 10 * 60
    /// The sweep charges in [due 14:00 UTC, due + 7 days 14:00 UTC] (§4.6).
    static let chargeWindowDays = 7
    static let chargeWindowHourUTC = 14
}

// MARK: - Wire model (`GET /api/autopay/status`, spec §4.8)

struct NativeAutopayCard: Equatable, Sendable {
    var brand: String?
    var last4: String?
    var expMonth: Int?
    var expYear: Int?
    var wallet: String?
}

struct NativeAutopayEnrollment: Equatable, Sendable {
    /// `pending | active | revoked | replaced`; kept raw so a status added
    /// later reads as "not active" instead of failing the whole decode.
    var id: String
    var recurringInvoiceId: String
    var customerId: String?
    var status: String
    var card: NativeAutopayCard?
    var maxAmount: Decimal?
    var activatedAt: Date?
    var revokedAt: Date?
    /// `customer | owner | system`.
    var revokedBy: String?
    var revokeReason: String?

    var isActive: Bool { status == "active" }
}

struct NativeAutopayCharge: Equatable, Sendable {
    var invoiceId: String
    /// `claimed | succeeded | failed | skipped`.
    var status: String
    var amount: Decimal?
    var failureReason: String?
    var at: Date?

    var isFailure: Bool { status == "failed" || status == "skipped" }
}

struct NativeAutopayStatusSnapshot: Equatable, Sendable {
    var enrollments: [NativeAutopayEnrollment]
    var charges: [NativeAutopayCharge]

    static let empty = NativeAutopayStatusSnapshot(enrollments: [], charges: [])

    /// The plan's active enrollment. The database allows one per plan
    /// (`autopay_one_active_per_plan`); the newest activation wins if a
    /// stale response ever carried two.
    func activeEnrollment(planID: String) -> NativeAutopayEnrollment? {
        enrollments
            .filter { $0.recurringInvoiceId == planID && $0.isActive }
            .max { ($0.activatedAt ?? .distantPast) < ($1.activatedAt ?? .distantPast) }
    }

    /// The newest charge row for one invoice (v1 writes one attempt).
    func latestCharge(invoiceID: String) -> NativeAutopayCharge? {
        charges
            .filter { $0.invoiceId == invoiceID }
            .max { ($0.at ?? .distantPast) < ($1.at ?? .distantPast) }
    }

    /// The owner removed this card: the enrollment reads as revoked by the
    /// owner at once, before the refresh that follows confirms it.
    func markingRemoved(enrollmentID: String, at date: Date) -> NativeAutopayStatusSnapshot {
        var copy = self
        copy.enrollments = enrollments.map { enrollment in
            guard enrollment.id == enrollmentID, enrollment.isActive else { return enrollment }
            var revoked = enrollment
            revoked.status = "revoked"
            revoked.revokedAt = date
            revoked.revokedBy = "owner"
            revoked.revokeReason = nil
            return revoked
        }
        return copy
    }
}

extension NativeAutopay {
    /// Decodes the status body leniently: unknown keys are ignored, a
    /// malformed entry is skipped rather than failing the rest, and only a
    /// body without both arrays is refused (nil).
    static func parseStatus(_ data: Data) -> NativeAutopayStatusSnapshot? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawEnrollments = object["enrollments"] as? [Any],
              let rawCharges = object["charges"] as? [Any]
        else { return nil }
        let enrollments = rawEnrollments.compactMap { ($0 as? [String: Any]).flatMap(enrollment) }
        let charges = rawCharges.compactMap { ($0 as? [String: Any]).flatMap(charge) }
        return NativeAutopayStatusSnapshot(enrollments: enrollments, charges: charges)
    }

    private static func enrollment(_ raw: [String: Any]) -> NativeAutopayEnrollment? {
        guard let id = string(raw["id"]), let plan = string(raw["recurringInvoiceId"]),
              let status = string(raw["status"])
        else { return nil }
        var card: NativeAutopayCard?
        if let rawCard = raw["card"] as? [String: Any] {
            card = NativeAutopayCard(
                brand: string(rawCard["brand"]),
                last4: string(rawCard["last4"]),
                expMonth: int(rawCard["expMonth"]),
                expYear: int(rawCard["expYear"]),
                wallet: string(rawCard["wallet"]))
        }
        return NativeAutopayEnrollment(
            id: id,
            recurringInvoiceId: plan,
            customerId: string(raw["customerId"]),
            status: status,
            card: card,
            maxAmount: dollars(raw["maxAmount"]),
            activatedAt: timestamp(raw["activatedAt"]),
            revokedAt: timestamp(raw["revokedAt"]),
            revokedBy: string(raw["revokedBy"]),
            revokeReason: string(raw["revokeReason"]))
    }

    private static func charge(_ raw: [String: Any]) -> NativeAutopayCharge? {
        guard let invoiceID = string(raw["invoiceId"]), let status = string(raw["status"]) else { return nil }
        return NativeAutopayCharge(
            invoiceId: invoiceID,
            status: status,
            amount: dollars(raw["amount"]),
            failureReason: string(raw["failureReason"]),
            at: timestamp(raw["at"]))
    }

    private static func string(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func int(_ value: Any?) -> Int? {
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { return number.intValue }
        if let text = value as? String { return Int(text) }
        return nil
    }

    /// Dollars, rounded to cents (a JSON double like 120.1 never leaks
    /// binary noise into a comparison or a display string).
    private static func dollars(_ value: Any?) -> Decimal? {
        let double: Double
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            double = number.doubleValue
        } else if let text = value as? String, let parsed = Double(text) {
            double = parsed
        } else {
            return nil
        }
        guard double.isFinite else { return nil }
        return Decimal(Int((double * 100).rounded())) / 100
    }

    /// ISO-8601 with or without fractional seconds (Postgres sends six
    /// digits), or a bare `YYYY-MM-DD` read as UTC midnight.
    static func timestamp(_ value: Any?) -> Date? {
        guard let text = string(value) else { return nil }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) ?? plain.date(from: text) { return date }
        // Trim fractional digits past milliseconds, then retry.
        if let dot = text.firstIndex(of: ".") {
            let digits = text[text.index(after: dot)...].prefix { $0.isNumber }
            if digits.count > 3 {
                let end = text.index(text.index(after: dot), offsetBy: digits.count)
                let trimmed = String(text[..<text.index(dot, offsetBy: 4)]) + String(text[end...])
                if let date = fractional.date(from: trimmed) { return date }
            }
        }
        return utcDay(text)
    }

    /// A strict `YYYY-MM-DD` at UTC midnight.
    static func utcDay(_ ymd: String) -> Date? {
        let parts = ymd.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2])
        else { return nil }
        var components = DateComponents()
        components.year = year; components.month = month; components.day = day
        guard let date = utcCalendar.date(from: components),
              utcCalendar.component(.day, from: date) == day,
              utcCalendar.component(.month, from: date) == month
        else { return nil }
        return date
    }

    static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
}

// MARK: - Display strings

extension NativeAutopay {
    /// Stripe's `card.brand` values, named the way cards print them.
    static func brandName(_ raw: String?) -> String {
        switch raw?.lowercased() {
        case "visa": "Visa"
        case "mastercard": "Mastercard"
        case "amex", "american_express": "Amex"
        case "discover": "Discover"
        case "diners", "diners_club": "Diners Club"
        case "jcb": "JCB"
        case "unionpay": "UnionPay"
        case "eftpos_au": "eftpos"
        case "cartes_bancaires": "Cartes Bancaires"
        case "interac": "Interac"
        default: "Card"
        }
    }

    /// "Visa •••• 4242".
    static func cardShort(_ card: NativeAutopayCard?) -> String {
        let brand = brandName(card?.brand)
        guard let last4 = validLast4(card?.last4) else { return brand == "Card" ? "Saved card" : "\(brand) card" }
        return "\(brand) •••• \(last4)"
    }

    /// "Visa •••• 4242 · exp 08/27", plus the wallet when the card came from
    /// one ("Visa •••• 4242 (Apple Pay) · exp 08/27").
    static func cardDisplay(_ card: NativeAutopayCard?) -> String {
        var text = cardShort(card)
        if let wallet = walletName(card?.wallet) { text += " (\(wallet))" }
        if let expiry = expiry(card) { text += " · exp \(expiry)" }
        return text
    }

    /// The VoiceOver form: "Visa ending in 4242, expires 08/27". The bullets
    /// read as "bullet" four times, so they never reach VoiceOver.
    static func cardAccessibilityText(_ card: NativeAutopayCard?, includeExpiry: Bool = true) -> String {
        let brand = brandName(card?.brand)
        var text = validLast4(card?.last4).map { "\(brand) ending in \($0)" }
            ?? (brand == "Card" ? "Saved card" : "\(brand) card")
        if let wallet = walletName(card?.wallet) { text += ", \(wallet)" }
        if includeExpiry, let expiry = expiry(card) { text += ", expires \(expiry)" }
        return text
    }

    private static func validLast4(_ value: String?) -> String? {
        guard let value, value.count == 4, value.allSatisfy(\.isNumber) else { return nil }
        return value
    }

    private static func walletName(_ raw: String?) -> String? {
        switch raw?.lowercased() {
        case "apple_pay": "Apple Pay"
        case "google_pay": "Google Pay"
        case "link": "Link"
        default: nil
        }
    }

    /// "08/27".
    static func expiry(_ card: NativeAutopayCard?) -> String? {
        guard let month = card?.expMonth, (1...12).contains(month), let year = card?.expYear, year > 0 else { return nil }
        return String(format: "%02d/%02d", month, year % 100)
    }

    /// A charge failure or skip, as a short lowercase phrase that fits both
    /// "Autopay failed Nov 1: card declined" and the invoice banner. The
    /// Worker sends the build record's §13.1 `failureReason` list; raw Stripe
    /// decline codes are mapped too, and anything else reads "card declined".
    static func failureReasonText(_ raw: String?) -> String {
        switch raw?.lowercased() {
        case "authentication_required": "the bank asked the customer to confirm the payment"
        case "expired_card": "the card has expired"
        case "insufficient_funds": "insufficient funds"
        case "amount_above_authorized": "the amount is above what the customer authorized"
        case "payment_method_missing": "the saved card is no longer available"
        case "lost_card", "stolen_card", "pickup_card", "restricted_card", "invalid_account":
            "the card can't be used"
        case "incorrect_cvc", "invalid_cvc", "incorrect_number", "invalid_number", "invalid_expiry_month",
             "invalid_expiry_year":
            "the card details were rejected"
        case "processing_error": "a processing error"
        case "unknown": "the result couldn't be confirmed"
        default: "card declined"
        }
    }

    /// Who turned a card off, for the plan row. `revokeReason` values are
    /// the build record's §13.1 list; any other reads as a generic removal.
    static func removalText(by: String?, reason: String?) -> String {
        if by == "customer" { return "your customer turned it off" }
        if by == "owner" { return "you removed the card" }
        switch reason {
        case "hard_decline": return "the card was declined and removed"
        case "payment_method_missing": return "the card is no longer available"
        case "plan_removed": return "the card was removed when the plan changed"
        case "stripe_disconnected": return "Stripe was disconnected"
        default: return "the card was removed"
        }
    }

    /// "Nov 1" in the device zone (a charge time is an instant).
    static func shortDate(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "MMM d"
        return formatter.string(from: date)
    }

    /// "Nov 1, 2026" for a `YYYY-MM-DD` due date, formatted in UTC so the day
    /// never shifts with the device zone. A malformed input is returned as is.
    static func dueDisplay(_ ymd: String) -> String {
        guard let date = utcDay(ymd) else { return ymd }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.calendar = utcCalendar
        formatter.timeZone = utcCalendar.timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    static func currency(_ amount: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        return formatter.string(from: NSDecimalNumber(decimal: amount)) ?? "$\(amount)"
    }
}

// MARK: - Plan status (plan list rows, the remove action)

/// The facts about one plan that status needs.
struct NativeAutopayPlanFacts: Equatable {
    var id: String
    var customerId: String
    var autopayEnabled: Bool
}

/// The facts about one invoice that status and banners need. `balanceDue`
/// comes from the ledger (`PaymentLedger.balanceDue`).
struct NativeAutopayInvoiceFacts: Equatable {
    var id: String
    var recurringInvoiceId: String?
    var due: String
    var balanceDue: Decimal
    var customerName: String
    var isImported: Bool
}

enum NativeAutopayPlanStatus: Equatable {
    /// The plan doesn't offer autopay and no card is saved.
    case off
    /// The plan offers autopay; no card is saved yet.
    case offered
    /// A card is saved and the plan offers autopay.
    case on(NativeAutopayCard)
    /// A card is saved but the owner stopped offering autopay: nothing is
    /// charged, and the card stays until someone removes it (§6.2 copy).
    case paused(NativeAutopayCard)
    /// The plan offers autopay and its last card was turned off.
    case removed(by: String?, reason: String?)
    /// The newest autopay failure on a plan invoice that is still unpaid.
    case failed(reason: String?, date: Date?)

    /// The saved card, when there is one to remove.
    var savedCard: NativeAutopayCard? {
        switch self {
        case .on(let card), .paused(let card): card
        default: nil
        }
    }
}

extension NativeAutopay {
    /// One plan's status. `snapshot` is nil until the first status read, so
    /// rows fall back to the plan's own toggle. A failure stays the headline
    /// while its invoice is unpaid, unless a card was saved after it.
    static func planStatus(
        plan: NativeAutopayPlanFacts,
        invoices: [NativeAutopayInvoiceFacts],
        snapshot: NativeAutopayStatusSnapshot?
    ) -> NativeAutopayPlanStatus {
        guard let snapshot else { return plan.autopayEnabled ? .offered : .off }
        let active = snapshot.activeEnrollment(planID: plan.id)
        let unpaidPlanInvoices = Set(invoices
            .filter { $0.recurringInvoiceId == plan.id && $0.balanceDue > epsilon }
            .map(\.id))
        let failure = snapshot.charges
            .filter { $0.isFailure && unpaidPlanInvoices.contains($0.invoiceId) }
            .max { ($0.at ?? .distantPast) < ($1.at ?? .distantPast) }
        if let failure {
            var cardSavedSince = false
            if let activated = active?.activatedAt, let failedAt = failure.at { cardSavedSince = activated > failedAt }
            if !cardSavedSince { return .failed(reason: failure.failureReason, date: failure.at) }
        }
        if let active {
            let card = active.card ?? NativeAutopayCard()
            return plan.autopayEnabled ? .on(card) : .paused(card)
        }
        guard plan.autopayEnabled else { return .off }
        // Only a card that was actually saved counts as removed: an
        // abandoned checkout (pending, then expired) never had one.
        let removal = snapshot.enrollments
            .filter { $0.recurringInvoiceId == plan.id && $0.status == "revoked" && $0.activatedAt != nil }
            .max { ($0.revokedAt ?? .distantPast) < ($1.revokedAt ?? .distantPast) }
        if let removal { return .removed(by: removal.revokedBy, reason: removal.revokeReason) }
        return .offered
    }

    /// The plan row's line, or nil when autopay is off for the plan.
    /// "Autopay on · Visa •••• 4242", "Autopay offered",
    /// "Autopay failed Nov 1: card declined".
    static func planRowText(_ status: NativeAutopayPlanStatus, timeZone: TimeZone = .current) -> String? {
        switch status {
        case .off: return nil
        case .offered: return "Autopay offered"
        case .on(let card): return "Autopay on · \(cardShort(card))"
        case .paused(let card): return "Autopay not offered · \(cardShort(card)) still saved"
        case .removed(let by, let reason): return "Autopay offered · \(removalText(by: by, reason: reason))"
        case .failed(let reason, let date):
            let when = date.map { " " + shortDate($0, timeZone: timeZone) } ?? ""
            return "Autopay failed\(when): \(failureReasonText(reason))"
        }
    }

    /// The same line for VoiceOver (no bullets).
    static func planRowAccessibilityText(_ status: NativeAutopayPlanStatus, timeZone: TimeZone = .current) -> String? {
        switch status {
        case .on(let card): return "Autopay on, \(cardAccessibilityText(card, includeExpiry: false))"
        case .paused(let card): return "Autopay not offered, \(cardAccessibilityText(card, includeExpiry: false)) still saved"
        default: return planRowText(status, timeZone: timeZone)
        }
    }

    /// Whether the row's line reports a problem (drawn in the warning color,
    /// but the words carry the meaning on their own).
    static func planRowIsProblem(_ status: NativeAutopayPlanStatus) -> Bool {
        if case .failed = status { return true }
        return false
    }
}

// MARK: - Invoice banner (invoice detail)

struct NativeAutopayInvoiceBanner: Equatable {
    var text: String
    var accessibilityText: String
    var isProblem: Bool
}

extension NativeAutopay {
    /// The one-line banner on a plan invoice's detail, or nil. A server
    /// charge row always wins over the prediction.
    static func invoiceBanner(
        invoice: NativeAutopayInvoiceFacts,
        plan: NativeAutopayPlanFacts?,
        snapshot: NativeAutopayStatusSnapshot?,
        now: Date
    ) -> NativeAutopayInvoiceBanner? {
        guard let snapshot, let planID = invoice.recurringInvoiceId, !invoice.isImported,
              invoice.balanceDue > epsilon
        else { return nil }
        let active = snapshot.activeEnrollment(planID: planID)
        if let charge = snapshot.latestCharge(invoiceID: invoice.id) {
            switch charge.status {
            case "failed", "skipped":
                let text: String
                if charge.failureReason?.lowercased() == "unknown" {
                    text = "Autopay couldn't confirm this charge. Check your Stripe dashboard before collecting payment."
                } else {
                    let customer = invoice.customerName.isEmpty ? "Your customer" : invoice.customerName
                    text = "Autopay failed: \(failureReasonText(charge.failureReason)). \(customer) was emailed a payment link."
                }
                return NativeAutopayInvoiceBanner(text: text, accessibilityText: text, isProblem: true)
            case "claimed":
                let card = active?.card
                return NativeAutopayInvoiceBanner(
                    text: "Autopay charge in progress\(card.map { " (\(cardShort($0)))" } ?? "").",
                    accessibilityText: "Autopay charge in progress\(card.map { ", \(cardAccessibilityText($0, includeExpiry: false))" } ?? "").",
                    isProblem: false)
            case "succeeded":
                let text = "Paid automatically. The payment appears here after the next sync."
                return NativeAutopayInvoiceBanner(text: text, accessibilityText: text, isProblem: false)
            default:
                break
            }
        }
        guard let plan, plan.id == planID, plan.autopayEnabled, let active,
              active.customerId == nil || active.customerId == plan.customerId,
              let dueDay = utcDay(invoice.due)
        else { return nil }
        // Consent covers invoices coming due on or after the activation day.
        if let activated = active.activatedAt,
           dueDay < utcCalendar.startOfDay(for: activated) { return nil }
        // Past the sweep's window, the invoice follows the normal link path.
        guard let windowStart = utcCalendar.date(byAdding: .hour, value: chargeWindowHourUTC, to: dueDay),
              let windowEnd = utcCalendar.date(byAdding: .day, value: chargeWindowDays, to: windowStart),
              now <= windowEnd
        else { return nil }
        if let ceiling = active.maxAmount, invoice.balanceDue > ceiling + epsilon {
            let customer = invoice.customerName.isEmpty ? "your customer" : invoice.customerName
            let text = "Won't be charged automatically: the balance is above the \(currency(ceiling)) \(customer) authorized. They'll be emailed a payment link instead."
            return NativeAutopayInvoiceBanner(text: text, accessibilityText: text, isProblem: true)
        }
        let due = dueDisplay(invoice.due)
        return NativeAutopayInvoiceBanner(
            text: "Will be charged automatically on \(due) (\(cardShort(active.card)))",
            accessibilityText: "Will be charged automatically on \(due), \(cardAccessibilityText(active.card, includeExpiry: false))",
            isProblem: false)
    }
}

// MARK: - Plan editor ("Payment" section, spec §6.2)

enum NativeAutopayOfferAvailability: Equatable {
    case available
    case checking
    case needsStripe
    case needsStripeSetup
}

extension NativeAutopay {
    /// "Offer autopay" can be turned on only with Stripe connected and
    /// selected (pay links are Stripe pay-page links). Turning it off is
    /// always allowed.
    static func offerAvailability(
        paymentProvider: String,
        stripeConnected: Bool?,
        stripeDetailsSubmitted: Bool?,
        stripeStatusLoading: Bool
    ) -> NativeAutopayOfferAvailability {
        guard paymentProvider == "stripe" else { return .needsStripe }
        guard let stripeConnected else { return stripeStatusLoading ? .checking : .needsStripe }
        guard stripeConnected else { return .needsStripe }
        return stripeDetailsSubmitted == false ? .needsStripeSetup : .available
    }

    static func offerCaption(_ availability: NativeAutopayOfferAvailability) -> String? {
        switch availability {
        case .available: nil
        case .checking: "Checking your Stripe connection…"
        case .needsStripe: "Connect Stripe in Settings → Payments to offer autopay."
        case .needsStripeSetup: "Finish your Stripe setup in Settings → Payments to offer autopay."
        }
    }

    static let offerExplanation = "Customers can save a card when they pay an invoice from this plan. Later invoices are charged on their due date, never above the plan amount."

    static let turnOnTitle = "Offer autopay?"
    static let turnOnMessage = "Your customer can choose to save a card when they pay an invoice from this plan, or from their portal. Later invoices are then charged on their due date, up to the plan amount. They can turn it off any time."
    static let turnOffTitle = "Stop offering autopay?"
    static let turnOffMessage = "Stops automatic charges for this plan. The saved card stays until you or the customer removes it."

    /// Notes for an edit that changes what a saved card covers: a higher
    /// amount needs the customer's new approval (§2.2), and the sweep
    /// removes a card whose plan moved to another customer (§4.6).
    static func editNotes(
        active: NativeAutopayEnrollment?,
        newAmount: Decimal?,
        newCustomerID: String
    ) -> [String] {
        guard let active else { return [] }
        var notes: [String] = []
        if let customer = active.customerId, !newCustomerID.isEmpty, customer != newCustomerID {
            notes.append("Changing the customer removes the saved \(cardShort(active.card)). The new customer can set up autopay themselves.")
        } else if let ceiling = active.maxAmount, let newAmount, newAmount > ceiling + epsilon {
            notes.append("Above the \(currency(ceiling)) your customer authorized. Their invoices won't be charged automatically until they approve the new amount when they next pay.")
        }
        return notes
    }
}

// MARK: - Remove saved card (plan actions, spec §6.3)

extension NativeAutopay {
    static let removeTitle = "Remove saved card?"

    static func removeMessage(card: NativeAutopayCard?, customerName: String) -> String {
        let customer = customerName.isEmpty ? "Your customer" : customerName
        return "\(cardDisplay(card)) will be removed and future invoices won't be charged automatically. \(customer) gets an email saying you turned automatic payments off, and can set them up again from their portal."
    }

    static let removeFailedTitle = "Couldn't remove the card"
}

// MARK: - Refresh policy (spec §6.3)

enum NativeAutopayRefreshTrigger: Equatable {
    /// Foreground activation: at most every 10 minutes.
    case foreground
    /// Opening the plans list: always.
    case plansList
    /// After a remove: always.
    case afterRemove
}

extension NativeAutopay {
    static func shouldRefresh(_ trigger: NativeAutopayRefreshTrigger, lastFetchedAt: Date?, now: Date) -> Bool {
        switch trigger {
        case .plansList, .afterRemove:
            return true
        case .foreground:
            guard let lastFetchedAt else { return true }
            let elapsed = now.timeIntervalSince(lastFetchedAt)
            // A clock moved backwards reads as stale, never as fresh forever.
            return elapsed < 0 || elapsed >= foregroundRefreshInterval
        }
    }
}
