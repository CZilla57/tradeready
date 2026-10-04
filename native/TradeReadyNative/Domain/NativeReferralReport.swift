import Foundation

// MARK: - Referral report (Phase 34, spec 2026-10-03-referral-program-design.md §5.7, §5.8)
//
// Pure over canonical arrays, like every Money report: no I/O, no wall clock.
// Kept out of `NativeMoneyCardModels.swift` so the coach runners can compile
// it. Every date goes through `NativeCashBasis.isInRange` (FA-039 safe).
//
// Attribution. An invoice's collected amount (`NativeCashBasis.collected` over
// `[invoice]`) counts only when the Phase 27 bucket attribution puts it in
// `referral`. It then goes to a referrer row by the same id-first /
// unique-name rule (`NativeLeadSourceReport.Attribution`), keyed on the
// customer's referrer (R1). A missing or ambiguous referrer lands in
// "Referrer not recorded"; a deleted referrer in "Former customer".
//
// Control total: Σ row.collected (both catch-all rows included) == the
// lead-source report's `referral` row for the same window, because each
// referral-bucket invoice lands in exactly one row.

enum NativeReferralRowKind: Hashable {
    case referrer(String)
    case formerCustomer
    case notRecorded
}

/// One referrer (or catch-all) row.
struct NativeReferralReportRow: Equatable, Identifiable {
    var kind: NativeReferralRowKind
    var name: String
    /// The referrer is archived (their code still attributes bookings).
    var isArchived: Bool
    /// Referred customers whose `createdAt` falls in the window.
    var newReferred: Int
    /// Referred customers, all time.
    var referredAllTime: Int
    /// Non-voided payments in the window on referral-bucket invoices.
    var collected: Decimal
    /// `NativeReferrals.creditBalance(...).owed` (0 for catch-all rows).
    var creditOwed: Decimal

    var id: String {
        switch kind {
        case let .referrer(id): "referrer:\(id)"
        case .formerCustomer: "former"
        case .notRecorded: "not_recorded"
        }
    }

    var referrerID: String? {
        if case let .referrer(id) = kind { return id }
        return nil
    }

    var isCatchAll: Bool { referrerID == nil }
}

/// One referred customer, for the "who referred whom" screen and customer
/// detail.
struct NativeReferralEntry: Equatable, Identifiable {
    var id: String
    var name: String
    /// "Joined Sep 12, 2026", nil when `createdAt` is missing or unreadable.
    var joinedText: String?
    var collected: Decimal
    var hasReward: Bool
    /// "Thanked · $25.00 credit · Oct 3" or "Not thanked yet".
    var rewardStatus: String
}

/// One section of the "who referred whom" screen.
struct NativeReferralGroup: Equatable, Identifiable {
    var row: NativeReferralReportRow
    var entries: [NativeReferralEntry]
    var id: String { row.id }
}

/// §5.7 customer-detail summary (all time).
struct NativeReferralCustomerSummary: Equatable {
    enum ReferredBy: Equatable {
        case none
        case customer(id: String, name: String, isArchived: Bool)
        /// The referrer's record was deleted.
        case formerCustomer
    }

    var referredBy: ReferredBy
    var referred: [NativeReferralEntry]
    var collectedTotal: Decimal
    var creditOwed: Decimal
    var hasCode: Bool

    /// "Referred 3 · $4,120.00 collected".
    var summaryText: String {
        "Referred \(referred.count) \u{00B7} \(NativeReferrals.money(collectedTotal)) collected"
    }
}

/// §5.8 coach row.
struct NativeReferralSnapshotRow: Equatable {
    var name: String
    var referred: Int
    var collected: Decimal
}

/// §5.8 year-to-date referral figures the coach may cite. Absent (never
/// zeroed) when no customer has a referrer.
struct NativeReferralSnapshotBlock: Equatable {
    var newReferred: Int
    var collected: Decimal
    var topReferrers: [NativeReferralSnapshotRow]
    var rewardsRecorded: Int
    var rewardsAmount: Decimal
}

struct NativeReferralReport: Equatable {
    /// Collected descending, then new referred descending, then name; the two
    /// catch-all rows last (Former customer, then Referrer not recorded).
    var rows: [NativeReferralReportRow]
    /// Rewards whose `recordedOn` falls in the window (R1 referrals only).
    var rewardsRecorded: Int
    var rewardsAmount: Decimal

    var totalCollected: Decimal { rows.reduce(Decimal.zero) { $0 + $1.collected } }
    var newReferred: Int { rows.reduce(0) { $0 + $1.newReferred } }

    static let snapshotReferrerLimit = 3

    private static let formerKey = "\u{1}former"
    private static let notRecordedKey = "\u{1}none"
    private static let notReferralKey = "\u{1}other"
    private static let referrerPrefix = "ref:"

    /// The row key of a customer: `ref:<id>` for a live referrer, the
    /// Former customer key for a dangling one, Referrer not recorded for a
    /// referral without a valid referrer, and a non-referral key otherwise.
    private static func referrerKey(_ customer: Canonical.Customer, liveIDs: Set<String>) -> String {
        guard NativeReferrals.isReferralSource(customer.leadSource) else { return notReferralKey }
        guard let referrer = NativeReferrals.validReferrerID(of: customer) else { return notRecordedKey }
        return liveIDs.contains(referrer) ? referrerPrefix + referrer : formerKey
    }

    static func make(
        customers: [Canonical.Customer],
        invoices: [Canonical.Invoice],
        start: Date,
        end: Date
    ) -> NativeReferralReport {
        let liveIDs = Set(customers.map(\.id).filter { !$0.isEmpty })
        let byID = Dictionary(customers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let buckets = NativeLeadSourceReport.Attribution(customers: customers)
        let referrers = NativeLeadSourceReport.Attribution(customers: customers) { referrerKey($0, liveIDs: liveIDs) }
        var rows: [String: NativeReferralReportRow] = [:]

        func touch(_ key: String) {
            guard rows[key] == nil else { return }
            let kind: NativeReferralRowKind
            let name: String
            var archived = false
            var owed = Decimal.zero
            if key.hasPrefix(referrerPrefix) {
                let id = String(key.dropFirst(referrerPrefix.count))
                kind = .referrer(id)
                let referrer = byID[id]
                name = referrer?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                archived = !(referrer?.archivedAt ?? "").isEmpty
                owed = NativeReferrals.creditBalance(referrerID: id, customers: customers, invoices: invoices).owed
            } else if key == formerKey {
                kind = .formerCustomer
                name = NativeReferrals.formerCustomerName
            } else {
                kind = .notRecorded
                name = NativeReferrals.notRecordedName
            }
            rows[key] = NativeReferralReportRow(
                kind: kind, name: name, isArchived: archived, newReferred: 0,
                referredAllTime: 0, collected: 0, creditOwed: owed
            )
        }

        var rewardsRecorded = 0
        var rewardsAmount = Decimal.zero
        for customer in customers {
            let key = referrerKey(customer, liveIDs: liveIDs)
            guard key != notReferralKey else { continue }
            touch(key)
            rows[key]?.referredAllTime += 1
            if let createdAt = customer.createdAt, NativeCashBasis.isInRange(createdAt, start: start, end: end) {
                rows[key]?.newReferred += 1
            }
            if NativeReferrals.validReferrerID(of: customer) != nil, let reward = customer.referralReward,
               NativeCashBasis.isInRange(reward.recordedOn, start: start, end: end) {
                rewardsRecorded += 1
                rewardsAmount += reward.amount ?? 0
            }
        }

        for invoice in invoices {
            let collected = NativeCashBasis.collected(invoices: [invoice], start: start, end: end)
            guard collected != 0,
                  buckets.bucket(customerId: invoice.customerId, name: invoice.customer) == NativeReferrals.referralSourceKey
            else { continue }
            var key = referrers.key(customerId: invoice.customerId, name: invoice.customer) ?? notRecordedKey
            if key == notReferralKey { key = notRecordedKey }
            touch(key)
            rows[key]?.collected += collected
        }

        return NativeReferralReport(
            rows: sortRows(Array(rows.values)),
            rewardsRecorded: rewardsRecorded,
            rewardsAmount: rewardsAmount
        )
    }

    static func sortRows(_ rows: [NativeReferralReportRow]) -> [NativeReferralReportRow] {
        func catchAllRank(_ row: NativeReferralReportRow) -> Int {
            switch row.kind {
            case .referrer: 0
            case .formerCustomer: 1
            case .notRecorded: 2
            }
        }
        return rows.sorted { lhs, rhs in
            let left = catchAllRank(lhs), right = catchAllRank(rhs)
            if left != right { return left < right }
            if lhs.collected != rhs.collected { return lhs.collected > rhs.collected }
            if lhs.newReferred != rhs.newReferred { return lhs.newReferred > rhs.newReferred }
            let byName = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
            if byName != .orderedSame { return byName == .orderedAscending }
            return lhs.id < rhs.id
        }
    }

    // MARK: Who referred whom

    /// One section per row of `make`, each listing its referred customers
    /// with their collected-in-window and reward status. Entries are newest
    /// first, then by name.
    static func groups(
        customers: [Canonical.Customer],
        invoices: [Canonical.Invoice],
        start: Date,
        end: Date
    ) -> [NativeReferralGroup] {
        let report = make(customers: customers, invoices: invoices, start: start, end: end)
        let liveIDs = Set(customers.map(\.id).filter { !$0.isEmpty })
        let collected = collectedByCustomer(customers: customers, invoices: invoices, start: start, end: end)
        var entriesByRow: [String: [(createdAt: Date?, entry: NativeReferralEntry)]] = [:]
        for customer in customers where NativeReferrals.isReferralSource(customer.leadSource) {
            let rowID: String
            switch referrerKey(customer, liveIDs: liveIDs) {
            case formerKey: rowID = "former"
            case notRecordedKey: rowID = "not_recorded"
            case let key: rowID = "referrer:" + key.dropFirst(referrerPrefix.count)
            }
            entriesByRow[rowID, default: []].append((
                customer.createdAt.flatMap(NativeCashBasis.parseLocalDate),
                entry(for: customer, collected: collected[customer.id] ?? 0)
            ))
        }
        return report.rows.map { row in
            let entries = (entriesByRow[row.id] ?? []).sorted { lhs, rhs in
                let left = lhs.createdAt ?? .distantPast, right = rhs.createdAt ?? .distantPast
                if left != right { return left > right }
                let byName = lhs.entry.name.localizedCaseInsensitiveCompare(rhs.entry.name)
                if byName != .orderedSame { return byName == .orderedAscending }
                return lhs.entry.id < rhs.entry.id
            }.map(\.entry)
            return NativeReferralGroup(row: row, entries: entries)
        }
    }

    // MARK: Customer detail

    /// §5.7: who referred this customer (only when R1 holds) and everyone they
    /// referred, all time. Nil when the customer is not stored.
    static func customerSummary(
        customerID: String,
        customers: [Canonical.Customer],
        invoices: [Canonical.Invoice]
    ) -> NativeReferralCustomerSummary? {
        guard let customer = customers.first(where: { $0.id == customerID }) else { return nil }
        let referredBy: NativeReferralCustomerSummary.ReferredBy
        if let referrerID = NativeReferrals.validReferrerID(of: customer) {
            if let referrer = customers.first(where: { $0.id == referrerID }) {
                referredBy = .customer(
                    id: referrer.id,
                    name: referrer.name.trimmingCharacters(in: .whitespacesAndNewlines),
                    isArchived: !(referrer.archivedAt ?? "").isEmpty
                )
            } else {
                referredBy = .formerCustomer
            }
        } else {
            referredBy = .none
        }
        let allTime = NativeCashBasis.range(for: "all_time", now: Date(timeIntervalSince1970: 0))
        let collected = collectedByCustomer(customers: customers, invoices: invoices, start: allTime.start, end: allTime.end)
        let referred = customers
            .filter { NativeReferrals.validReferrerID(of: $0) == customerID }
            .map { (createdAt: $0.createdAt.flatMap(NativeCashBasis.parseLocalDate), entry: entry(for: $0, collected: collected[$0.id] ?? 0)) }
            .sorted { lhs, rhs in
                let left = lhs.createdAt ?? .distantPast, right = rhs.createdAt ?? .distantPast
                if left != right { return left > right }
                let byName = lhs.entry.name.localizedCaseInsensitiveCompare(rhs.entry.name)
                if byName != .orderedSame { return byName == .orderedAscending }
                return lhs.entry.id < rhs.entry.id
            }
            .map(\.entry)
        return NativeReferralCustomerSummary(
            referredBy: referredBy,
            referred: referred,
            collectedTotal: referred.reduce(Decimal.zero) { $0 + $1.collected },
            creditOwed: NativeReferrals.creditBalance(referrerID: customerID, customers: customers, invoices: invoices).owed,
            hasCode: NativeReferrals.normalizeCode(customer.referralCode) != nil
        )
    }

    // MARK: Coach (§5.8)

    /// Year to date (`NativeCashBasis.range(for: "this_year")`). Nil when no
    /// customer has a referrer, so the coach never sees a zero-filled block.
    static func snapshotBlock(
        customers: [Canonical.Customer],
        invoices: [Canonical.Invoice],
        now: Date
    ) -> NativeReferralSnapshotBlock? {
        guard NativeReferrals.anyReferrer(in: customers) else { return nil }
        let range = NativeCashBasis.range(for: "this_year", now: now)
        let report = make(customers: customers, invoices: invoices, start: range.start, end: range.end)
        return NativeReferralSnapshotBlock(
            newReferred: report.newReferred,
            collected: report.totalCollected,
            topReferrers: report.rows.filter { !$0.isCatchAll }.prefix(snapshotReferrerLimit).map {
                NativeReferralSnapshotRow(name: $0.name, referred: $0.referredAllTime, collected: $0.collected)
            },
            rewardsRecorded: report.rewardsRecorded,
            rewardsAmount: report.rewardsAmount
        )
    }

    // MARK: Helpers

    /// Collected in the window per customer id (id-first / unique name).
    static func collectedByCustomer(
        customers: [Canonical.Customer],
        invoices: [Canonical.Invoice],
        start: Date,
        end: Date
    ) -> [String: Decimal] {
        let owners = NativeLeadSourceReport.Attribution(customers: customers) { $0.id }
        var totals: [String: Decimal] = [:]
        for invoice in invoices {
            let collected = NativeCashBasis.collected(invoices: [invoice], start: start, end: end)
            guard collected != 0, let id = owners.key(customerId: invoice.customerId, name: invoice.customer) else { continue }
            totals[id, default: 0] += collected
        }
        return totals
    }

    private static func entry(for customer: Canonical.Customer, collected: Decimal) -> NativeReferralEntry {
        let reward = customer.referralReward
        return NativeReferralEntry(
            id: customer.id,
            name: customer.name.trimmingCharacters(in: .whitespacesAndNewlines),
            joinedText: joinedText(customer.createdAt),
            collected: collected,
            hasReward: reward != nil,
            rewardStatus: reward.map(NativeReferrals.rewardStatusText) ?? NativeReferrals.notThankedText
        )
    }

    /// "Joined Sep 12, 2026" on the owner's local calendar.
    static func joinedText(_ createdAt: String?) -> String? {
        guard let createdAt, let date = NativeCashBasis.parseLocalDate(createdAt) else { return nil }
        return "Joined " + joinedFormatter.string(from: date)
    }

    private static var joinedFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "MMM d, yyyy"
        return formatter
    }
}
