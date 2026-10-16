import Foundation

// MARK: - Lead-source report (Phase 27, spec 2026-10-02-lead-source-design.md §5-§6)
//
// Pure over canonical arrays, like every Money report: no I/O, no wall clock.
// The window is the caller's `NativeMoneyDateFilter` range (or year to date for
// the coach), and every date goes through `NativeCashBasis.isInRange`, so a
// bare `YYYY-MM-DD`, a timezone-less local datetime and a UTC `…Z` stamp all
// land on the owner's local calendar (FA-039 safe).
//
// Attribution. A record belongs to the bucket of the customer it resolves to:
//  1. `customerId`, when it names a known customer (archived customers are
//     known: an archive hides a customer, it does not erase their history);
//  2. otherwise (the id is nil/empty, or dangles because the customer was
//     deleted) a normalized-name match (trim + lowercase, the
//     `NativeCustomerIdentity.normalizedName` rule, re-implemented here because
//     the Money runners do not compile that file). A name shared by customers
//     in *different* buckets is ambiguous and is not guessed;
//  3. otherwise the record is Unknown. Unknown is a real bucket, never an error,
//     so a deleted customer's payments still count toward the control total.
//
// Control total: Σ row.collected == `NativeCashBasis.collected(invoices:start:end:)`
// for the same window, because each invoice's share is exactly that function
// over `[invoice]` and every invoice lands in exactly one bucket.

/// One bucket of the report.
struct NativeLeadSourceReportRow: Equatable {
    /// `NativeLeadSource.bucketKey`: a preset key, `custom:<lowercased>` or `unknown`.
    var bucketKey: String
    /// The preset's display name, the first-seen custom spelling, or "Unknown".
    var displayName: String
    /// Customers whose `createdAt` falls in the window.
    var newCustomers: Int
    /// Jobs whose estimate send date (`estimateSentAt ?? approval.sentAt`)
    /// falls in the window.
    var estimatesSent: Int
    /// The subset of `estimatesSent` whose status is approved or later — a
    /// sent-in-period cohort, because a job carries no approval date (D4).
    var jobsWon: Int
    /// Non-voided ledger payments dated in the window (cash basis).
    var collected: Decimal

    /// won ÷ sent, `nil` when nothing was sent (shown as "—").
    var closeRate: Decimal? {
        estimatesSent > 0 ? Decimal(jobsWon) / Decimal(estimatesSent) : nil
    }

    var isUnknown: Bool { bucketKey == NativeLeadSource.unknownBucketKey }
}

/// Spec §6: one coach-block row.
struct NativeLeadSourceSnapshotRow: Equatable {
    var name: String
    var collected: Decimal
    var won: Int
    var sent: Int
    var closeRate: Decimal?
}

/// Spec §6: the year-to-date lead-source figures the coach may cite. Absent
/// (never zeroed) when no customer has a source.
struct NativeLeadSourceSnapshotBlock: Equatable {
    var rows: [NativeLeadSourceSnapshotRow]
}

struct NativeLeadSourceReport: Equatable {
    /// Collected descending, then new customers descending, then display
    /// name; Unknown always last.
    var rows: [NativeLeadSourceReportRow]
    /// At least one customer has a source. When false only Unknown can appear,
    /// and the Money card shows its setup hint.
    var hasAnySource: Bool

    var totalCollected: Decimal { rows.reduce(Decimal.zero) { $0 + $1.collected } }

    /// Coach block size (spec §6): the top sources by collected, plus Unknown.
    static let snapshotSourceLimit = 6

    /// Which rows exist: every bucket at least one customer belongs to (so a
    /// source that brought nothing this period still reads as zero), plus
    /// Unknown whenever an unattributable record had activity in the window.
    static func make(
        customers: [Canonical.Customer],
        jobs: [Canonical.Job],
        invoices: [Canonical.Invoice],
        start: Date,
        end: Date
    ) -> NativeLeadSourceReport {
        let attribution = Attribution(customers: customers)
        var rows: [String: NativeLeadSourceReportRow] = [:]

        func touch(_ key: String) {
            guard rows[key] == nil else { return }
            rows[key] = NativeLeadSourceReportRow(
                bucketKey: key,
                displayName: attribution.displayNames[key] ?? NativeLeadSource.unknownDisplayName,
                newCustomers: 0, estimatesSent: 0, jobsWon: 0, collected: 0
            )
        }

        for customer in customers {
            let key = NativeLeadSource.bucketKey(customer.leadSource)
            touch(key)
            if let createdAt = customer.createdAt,
               NativeCashBasis.isInRange(createdAt, start: start, end: end) {
                rows[key]?.newCustomers += 1
            }
        }

        let approvedOrdinal = NativeMoneyReports.statusOrdinal["approved"] ?? 2
        for job in jobs {
            // The estimate send date wins even when malformed, exactly like
            // `NativeEstimateFollowUp` (`approval.sentAt` only when it is nil).
            guard let sentAt = job.estimateSentAt ?? job.approval?.sentAt,
                  NativeCashBasis.isInRange(sentAt, start: start, end: end)
            else { continue }
            let key = attribution.bucket(customerId: job.customerId, name: job.customerName)
            touch(key)
            rows[key]?.estimatesSent += 1
            if (NativeMoneyReports.statusOrdinal[job.status] ?? -1) >= approvedOrdinal {
                rows[key]?.jobsWon += 1
            }
        }

        for invoice in invoices {
            let collected = NativeCashBasis.collected(invoices: [invoice], start: start, end: end)
            guard collected != 0 else { continue }
            let key = attribution.bucket(customerId: invoice.customerId, name: invoice.customer)
            touch(key)
            rows[key]?.collected += collected
        }

        let sorted = rows.values.sorted { lhs, rhs in
            if lhs.isUnknown != rhs.isUnknown { return rhs.isUnknown }
            if lhs.collected != rhs.collected { return lhs.collected > rhs.collected }
            if lhs.newCustomers != rhs.newCustomers { return lhs.newCustomers > rhs.newCustomers }
            let byName = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
            if byName != .orderedSame { return byName == .orderedAscending }
            return lhs.bucketKey < rhs.bucketKey
        }
        return NativeLeadSourceReport(
            rows: sorted,
            hasAnySource: customers.contains { NativeLeadSource.normalize($0.leadSource) != nil }
        )
    }

    /// Spec §6: year to date (`NativeCashBasis.range(for: "this_year")`), the
    /// top six sources by collected, plus Unknown when it collected anything.
    /// `nil` when no customer has a source, so the coach never sees a
    /// zero-filled block.
    static func snapshotBlock(
        customers: [Canonical.Customer],
        jobs: [Canonical.Job],
        invoices: [Canonical.Invoice],
        now: Date
    ) -> NativeLeadSourceSnapshotBlock? {
        let range = NativeCashBasis.range(for: "this_year", now: now)
        let report = make(customers: customers, jobs: jobs, invoices: invoices, start: range.start, end: range.end)
        guard report.hasAnySource else { return nil }
        var picked = Array(report.rows.filter { !$0.isUnknown }.prefix(snapshotSourceLimit))
        if let unknown = report.rows.first(where: \.isUnknown), unknown.collected != 0 {
            picked.append(unknown)
        }
        return NativeLeadSourceSnapshotBlock(rows: picked.map {
            NativeLeadSourceSnapshotRow(
                name: $0.displayName, collected: $0.collected,
                won: $0.jobsWon, sent: $0.estimatesSent, closeRate: $0.closeRate
            )
        })
    }

    /// `NativeCustomerIdentity.normalizedName`: trim + lowercase.
    static func normalizedName(_ value: String?) -> String {
        (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    // MARK: Attribution

    /// The id-first / unique-name rule. Phase 34 (referrals, spec §5.7)
    /// generalized it from the lead-source bucket to any per-customer `key`
    /// (the bucket stays the default), so the referral report attributes an
    /// invoice to a referrer by exactly the rule that put it in `referral`.
    /// `key(customerId:name:)` is nil when the record resolves to no customer
    /// or to a name shared by customers with different keys.
    struct Attribution {
        var keyByCustomerId: [String: String] = [:]
        /// Normalized name → the keys of every customer with that name.
        var keysByName: [String: Set<String>] = [:]
        /// Bucket key → display name (first-seen custom spelling). Filled for
        /// the default bucket key only.
        var displayNames: [String: String] = [:]

        init(customers: [Canonical.Customer]) {
            self.init(customers: customers, key: { NativeLeadSource.bucketKey($0.leadSource) })
            for customer in customers {
                let key = NativeLeadSource.bucketKey(customer.leadSource)
                if displayNames[key] == nil {
                    displayNames[key] = NativeLeadSource.displayName(customer.leadSource)
                }
            }
        }

        init(customers: [Canonical.Customer], key: (Canonical.Customer) -> String) {
            for customer in customers {
                let value = key(customer)
                // First record wins for a duplicated id (a sync artifact; the
                // ids should be unique).
                if !customer.id.isEmpty, keyByCustomerId[customer.id] == nil {
                    keyByCustomerId[customer.id] = value
                }
                let name = NativeLeadSourceReport.normalizedName(customer.name)
                if !name.isEmpty { keysByName[name, default: []].insert(value) }
            }
        }

        func key(customerId: String?, name: String) -> String? {
            if let customerId, !customerId.isEmpty, let value = keyByCustomerId[customerId] {
                return value
            }
            let nameKey = NativeLeadSourceReport.normalizedName(name)
            if !nameKey.isEmpty, let values = keysByName[nameKey], values.count == 1, let value = values.first {
                return value
            }
            return nil
        }

        func bucket(customerId: String?, name: String) -> String {
            key(customerId: customerId, name: name) ?? NativeLeadSource.unknownBucketKey
        }
    }
}
