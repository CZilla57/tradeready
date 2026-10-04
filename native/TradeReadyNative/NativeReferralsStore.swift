import Foundation
#if canImport(Security)
import Security
#endif

/// Phase 34 (referral program): the `AppStore` API customer detail, the share
/// sheet, the review request, the reward sheet, invoice-from-job and the Money
/// referrals screen build on. Spec:
/// `docs/superpowers/specs/2026-10-03-referral-program-design.md` §5.2, §5.6,
/// §5.7.
///
/// Every write re-reads the stored customer by id, changes only the referral
/// field it owns and commits through `commitCanonicalCustomers` (durable save,
/// publish, then one `customers` upsert). Unknown and preserved fields ride
/// along on the struct copy. Nothing is ever sent from here: sharing goes
/// through the system composer the owner reviews.
extension AppStore {
    // MARK: - Reads

    /// The customer's stored code, when it is a valid one.
    func referralCode(customerID: String) -> String? {
        NativeReferrals.normalizeCode(canonicalCustomers.first { $0.id == customerID }?.referralCode)
    }

    /// §5.7 customer-detail summary (all time).
    func referralSummary(customerID: String) -> NativeReferralCustomerSummary? {
        NativeReferralReport.customerSummary(
            customerID: customerID, customers: canonicalCustomers, invoices: canonicalInvoices
        )
    }

    /// The referral credit still owed to the customer an invoice resolves to
    /// (id first, then a unique name). 0 when it resolves to nobody.
    func referralCreditOwed(customerId: String?, name: String) -> Decimal {
        let customers = canonicalCustomers
        guard let referrerID = NativeReferrals.CustomerResolver(customers: customers)
            .customerID(customerId: customerId, name: name)
        else { return 0 }
        return NativeReferrals.creditBalance(referrerID: referrerID, customers: customers, invoices: canonicalInvoices).owed
    }

    /// The "who referred whom" sections for one Money date filter.
    func referralGroups(filter: NativeMoneyDateFilter, now: Date = Date()) -> [NativeReferralGroup] {
        let range = NativeCashBasis.range(for: filter.rawValue, now: now)
        return NativeReferralReport.groups(
            customers: canonicalCustomers, invoices: canonicalInvoices, start: range.start, end: range.end
        )
    }

    // MARK: - Codes (§5.2)

    /// The existing code, or a fresh collision-checked one written to the
    /// customer. Call it only after the booking link verifies
    /// (`referralShareLink`), so codes never exist for customers who were
    /// never shared. Nil when the customer is gone, the RNG fails, every
    /// draw collides, or the save fails.
    @discardableResult
    func ensureReferralCode(
        customerID: String,
        randomBytes: (Int) -> [UInt8]? = NativeReferralRandom.systemBytes
    ) -> String? {
        guard var customer = canonicalCustomers.first(where: { $0.id == customerID }) else { return nil }
        if let existing = NativeReferrals.normalizeCode(customer.referralCode) { return existing }
        guard let code = NativeReferrals.makeCode(
            existing: NativeReferrals.allCodes(in: canonicalCustomers), randomBytes: randomBytes
        ) else { return nil }
        customer.referralCode = code
        return commitCanonicalCustomers(
            [customer], failureMessage: "The referral link could not be saved. Nothing was changed."
        ) ? code : nil
    }

    /// "Reset referral link": a new code replaces the old one, which is
    /// dropped, not aliased (D3), so bookings through links already shared
    /// count as "referral, referrer not recorded". False when the customer has
    /// no code, is gone, or the save fails.
    @discardableResult
    func resetReferralCode(
        customerID: String,
        randomBytes: (Int) -> [UInt8]? = NativeReferralRandom.systemBytes
    ) -> Bool {
        guard var customer = canonicalCustomers.first(where: { $0.id == customerID }),
              let old = NativeReferrals.normalizeCode(customer.referralCode)
        else { return false }
        var existing = NativeReferrals.allCodes(in: canonicalCustomers)
        existing.insert(old)
        guard let code = NativeReferrals.makeCode(existing: existing, randomBytes: randomBytes) else {
            migrationMessage = "A new referral link couldn't be created. The current link still works."
            return false
        }
        customer.referralCode = code
        return commitCanonicalCustomers(
            [customer], failureMessage: "The referral link could not be reset. The current link still works."
        )
    }

    /// The customer's referral link, only after a fresh verified booking-link
    /// status read (the booking settings screen's rule): a nil status is
    /// `.unverified`; no share URL or a disabled link is `.bookingLinkOff`;
    /// otherwise the code is ensured and the link returned.
    func referralShareLink(
        customerID: String,
        adminService: NativeBookingAdministrationService? = nil,
        sessionBytes: Data? = nil,
        randomBytes: (Int) -> [UInt8]? = NativeReferralRandom.systemBytes
    ) async -> NativeReferralLinkState {
        guard canonicalCustomers.contains(where: { $0.id == customerID }) else { return .unavailable }
        let reconciled = await reconcileBookingLinkForSharing(adminService: adminService, sessionBytes: sessionBytes)
        guard let status = reconciled.status else { return .unverified }
        guard let bookingURL = reconciled.shareURL, status.enabled else { return .bookingLinkOff }
        guard let code = ensureReferralCode(customerID: customerID, randomBytes: randomBytes),
              let url = NativeReferrals.referralURL(bookingURL: bookingURL, code: code)
        else { return .unavailable }
        return .ready(url)
    }

    // MARK: - Rewards (§5.6)

    /// Records (or replaces) the owner's thank-you for this referral. Refused
    /// unless the customer has a referrer (R3: a reward belongs to a
    /// referral). A record only: nothing is sent, paid or credited here.
    @discardableResult
    func recordReferralReward(referredCustomerID: String, reward: Canonical.Customer.ReferralReward) -> Bool {
        guard var customer = canonicalCustomers.first(where: { $0.id == referredCustomerID }),
              NativeReferrals.validReferrerID(of: customer) != nil
        else { return false }
        customer.referralReward = reward
        return commitCanonicalCustomers(
            [customer], failureMessage: "The thank-you could not be saved. Nothing was changed."
        )
    }

    /// "Remove record". True when there is nothing left to remove.
    @discardableResult
    func removeReferralReward(referredCustomerID: String) -> Bool {
        guard var customer = canonicalCustomers.first(where: { $0.id == referredCustomerID }) else { return false }
        guard customer.referralReward != nil else { return true }
        customer.referralReward = nil
        return commitCanonicalCustomers(
            [customer], failureMessage: "The thank-you record could not be removed. Nothing was changed."
        )
    }

    /// The stored reward on a referred customer, for the reward sheet.
    func referralReward(referredCustomerID: String) -> Canonical.Customer.ReferralReward? {
        canonicalCustomers.first { $0.id == referredCustomerID }?.referralReward
    }
}

/// `SecRandomCopyBytes`, the `NativeAppleSignInNonce` pattern. Nil when the
/// system RNG fails, which `NativeReferrals.makeCode` treats as fail closed.
enum NativeReferralRandom {
    static func systemBytes(_ count: Int) -> [UInt8]? {
        #if canImport(Security)
        var bytes = [UInt8](repeating: 0, count: count)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
        return bytes
        #else
        return nil
        #endif
    }
}
