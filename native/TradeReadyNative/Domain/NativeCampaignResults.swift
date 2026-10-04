import Foundation

// MARK: - Phase 33: campaign results and attribution (spec §8, D10)
//
// Derived, never stored. A job is attributed to at most one campaign:
// - explicitly, through the campaign's booking link (`job.campaignId`, set by
//   booking intake from the `?c=` code), which also counts new people who used
//   a forwarded link;
// - else by window: a non-archived, non-recurring job for a `sent` recipient
//   whose `createdAt` local date is within [sent date, sent date + 30]. With
//   several sends to that customer, the latest send on or before the job's
//   date wins (last touch).
// Won = attributed jobs at `approved` or later (`NativeMoneyReports.statusOrdinal`).
// Collected = non-voided payments to date on the attributed jobs' invoices
// (`job.invoiceId`), the `NativeCashBasis.collected` math over all time.

struct NativeCampaignResults: Equatable {
    static let windowDays = 30
    static let footer =
        "Counts jobs booked through this campaign's link, or created for someone within 30 days of their message."

    struct RecipientRow: Equatable, Identifiable {
        var id: String { customerID }
        let customerID: String
        let name: String
        let channel: NativeCampaignSegments.Channel
        let status: NativeCampaignQueue.Status
        let skipReason: NativeCampaignQueue.SkipReason?
        let sentAt: String?
        let manual: Bool
        let repliedOn: String?
        /// Local `YYYY-MM-DD` of the earliest job attributed to this
        /// recipient by this campaign ("Booked Oct 12").
        let bookedOn: String?
    }

    var sent = 0
    var replied = 0
    /// `bookedViaLink + bookedInWindow`.
    var booked = 0
    var bookedViaLink = 0
    var won = 0
    var collected: Decimal = 0
    /// The attributed job ids, sorted.
    var jobIDs: [String] = []
    var rows: [RecipientRow] = []

    /// "Sent 31 · Replied 4 · Booked 6 (2 via link) · Won 5 · $3,140.00 collected".
    func headline(formatMoney: (Decimal) -> String) -> String {
        var parts = ["Sent \(sent)", "Replied \(replied)"]
        parts.append(bookedViaLink > 0 ? "Booked \(booked) (\(bookedViaLink) via link)" : "Booked \(booked)")
        parts.append("Won \(won)")
        parts.append("\(formatMoney(collected)) collected")
        return parts.joined(separator: " · ")
    }

    static func make(
        campaign: Canonical.Campaign,
        campaigns: [Canonical.Campaign],
        jobs: [Canonical.Job],
        invoices: [Canonical.Invoice],
        customers: [Canonical.Customer],
        now: Date
    ) -> NativeCampaignResults {
        let attribution = attribute(campaigns: campaigns.contains { $0.id == campaign.id } ? campaigns : campaigns + [campaign],
                                    jobs: jobs)
        let mine = jobs.filter { attribution[$0.id]?.campaignID == campaign.id }
        var out = NativeCampaignResults()
        out.jobIDs = mine.map(\.id).sorted()
        out.bookedViaLink = mine.filter { attribution[$0.id]?.viaLink == true }.count
        out.booked = mine.count
        out.won = mine.filter {
            (NativeMoneyReports.statusOrdinal[$0.status] ?? -1) >= (NativeMoneyReports.statusOrdinal["approved"] ?? 2)
        }.count
        let invoiceIDs = Set(mine.compactMap(\.invoiceId).filter { !$0.isEmpty })
        let linked = invoices.filter { invoiceIDs.contains($0.id) }
        let allTime = NativeCashBasis.range(for: "all_time", now: now)
        out.collected = NativeCashBasis.collected(invoices: linked, start: allTime.start, end: allTime.end)

        let names = Dictionary(customers.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        var bookedOn: [String: String] = [:]
        for job in mine {
            guard let day = NativeCampaignSegments.localDay(job.createdAt) else { continue }
            if let existing = bookedOn[job.customerId], existing <= day { continue }
            bookedOn[job.customerId] = day
        }
        for recipient in campaign.recipients ?? [] {
            let status = NativeCampaignQueue.status(recipient)
            if status == .sent { out.sent += 1 }
            if !(recipient.repliedOn ?? "").isEmpty { out.replied += 1 }
            let liveName = names[recipient.customerId]?.trimmingCharacters(in: .whitespacesAndNewlines)
            out.rows.append(RecipientRow(
                customerID: recipient.customerId,
                name: (liveName?.isEmpty == false ? liveName : nil) ?? recipient.name,
                channel: NativeCampaignQueue.channel(recipient),
                status: status,
                skipReason: recipient.skipReason.flatMap(NativeCampaignQueue.SkipReason.init(rawValue:)),
                sentAt: recipient.sentAt,
                manual: recipient.manual == true,
                repliedOn: recipient.repliedOn,
                bookedOn: status == .sent ? bookedOn[recipient.customerId] : nil
            ))
        }
        return out
    }

    struct Attribution: Equatable {
        let campaignID: String
        let viaLink: Bool
    }

    /// Job id → the one campaign it is attributed to, across all campaigns.
    static func attribute(campaigns: [Canonical.Campaign], jobs: [Canonical.Job]) -> [String: Attribution] {
        let knownIDs = Set(campaigns.map(\.id))
        // Every send per customer: (local day, instant, campaign id).
        var sends: [String: [(day: String, at: String, campaignID: String)]] = [:]
        for campaign in campaigns {
            for recipient in campaign.recipients ?? [] where NativeCampaignQueue.status(recipient) == .sent {
                guard let at = recipient.sentAt, let day = NativeCampaignSegments.localDay(at) else { continue }
                sends[recipient.customerId, default: []].append((day, at, campaign.id))
            }
        }
        var out: [String: Attribution] = [:]
        for job in jobs {
            if let explicit = job.campaignId, !explicit.isEmpty {
                // Explicitly attributed: to that campaign when it exists, and
                // never to another one by window.
                if knownIDs.contains(explicit) { out[job.id] = .init(campaignID: explicit, viaLink: true) }
                continue
            }
            guard (job.archivedAt ?? "").isEmpty, job.recurringJobId == nil,
                  let created = NativeCampaignSegments.localDay(job.createdAt),
                  let candidates = sends[job.customerId]
            else { continue }
            let onOrBefore = candidates.filter { $0.day <= created }
            guard let latest = onOrBefore.max(by: { lhs, rhs in
                if lhs.day != rhs.day { return lhs.day < rhs.day }
                if lhs.at != rhs.at { return lhs.at < rhs.at }
                return lhs.campaignID < rhs.campaignID
            }), let days = NativeCampaignSegments.daysBetween(latest.day, created), days <= windowDays
            else { continue }
            out[job.id] = .init(campaignID: latest.campaignID, viaLink: false)
        }
        return out
    }
}
