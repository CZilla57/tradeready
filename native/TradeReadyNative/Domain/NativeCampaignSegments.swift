import Foundation

// MARK: - Phase 33: campaign segments and the on-device send queue
//
// Spec `docs/superpowers/specs/2026-10-03-campaigns-tags-design.md` §5 and §7.
// Pure rules over the canonical models: who a campaign reaches (`evaluate`),
// and what each composer outcome does to the frozen recipient list
// (`NativeCampaignQueue`). Nothing here touches the snapshot, the queue or
// the disk; `AppStore` commits each change as one `campaigns` upsert
// (`NativeCampaignsStore.swift`).
//
// Dependencies: Foundation, the canonical models, `NativeCustomerTags`,
// `NativeLeadSource`, `NativeServiceHistory` (and through it `NativeSchedule`
// and `NativeCashBasis` for local-date math) and `NativeCampaignMessage`
// (first names).

/// Contact rules shared by segments, the live pre-send check and the list.
enum NativeCampaignContact {
    /// The digits of a phone number.
    static func phoneDigits(_ phone: String) -> String {
        String(phone.unicodeScalars.filter { CharacterSet.decimalDigits.contains($0) && $0.isASCII }.map(Character.init))
    }

    /// Spec §5.2 step 4: a phone counts with at least 10 digits.
    static func isTextable(_ phone: String) -> Bool { phoneDigits(phone).count >= 10 }

    /// The duplicate-contact key: the last 10 digits.
    static func phoneKey(_ phone: String) -> String? {
        let digits = phoneDigits(phone)
        return digits.count >= 10 ? String(digits.suffix(10)) : nil
    }

    /// The booking validator's `EMAIL_RE` (`/^[^\s@]+@[^\s@]+\.[^\s@]+$/`)
    /// over the trimmed address.
    static func isEmailable(_ email: String) -> Bool {
        let value = email.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.range(of: #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#, options: .regularExpression) != nil
    }

    static func emailKey(_ email: String) -> String? {
        isEmailable(email) ? email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() : nil
    }
}

/// The evaluated audience of one segment (spec §5.2).
struct NativeCampaignAudience: Equatable {
    struct Member: Equatable, Identifiable {
        var id: String { customerID }
        let customerID: String
        let name: String
        let firstName: String
        let channel: NativeCampaignSegments.Channel
        /// The live phone or email the composer will use.
        let contact: String
        let lastServiceDate: String?
        let lastJobTitle: String?
    }

    struct Exclusion: Equatable, Identifiable {
        var id: String { customerID }
        let customerID: String
        let name: String
        let reason: NativeCampaignSegments.ExclusionReason
    }

    struct Counts: Equatable {
        /// Passed the fixed exclusions and every filter.
        var matched = 0
        /// Will receive it (`byText + byEmail`).
        var reachable = 0
        var byText = 0
        var byEmail = 0
        /// Exclusions per `ExclusionReason.groupKey`.
        var excludedByReason: [String: Int] = [:]
        /// Excluded as unreachable only because email is unavailable until
        /// the Business address is set.
        var reachableOnceAddressSet = 0
    }

    var recipients: [Member]
    var exclusions: [Exclusion]
    var counts: Counts

    /// C4: more than 200 recipients cannot be frozen.
    var exceedsCap: Bool { recipients.count > NativeCampaignSegments.maxRecipients }
}

enum NativeCampaignSegments {
    /// C4: at most 200 recipients per campaign.
    static let maxRecipients = 200

    enum Service: String, CaseIterable, Equatable {
        case any
        case served
        case neverServed

        var displayName: String {
            switch self {
            case .any: "Anyone"
            case .served: "Worked for before"
            case .neverServed: "Never booked"
            }
        }
    }

    enum Referral: String, CaseIterable, Equatable {
        case any
        case cameFromReferral
        case hasReferred
    }

    enum ChannelPlan: String, CaseIterable, Equatable {
        case textFirst = "text_first"
        case emailFirst = "email_first"
        case textOnly = "text_only"
        case emailOnly = "email_only"

        var displayName: String {
            switch self {
            case .textFirst: "Text, or email if no phone"
            case .emailFirst: "Email, or text if no email"
            case .textOnly: "Text only"
            case .emailOnly: "Email only"
            }
        }

        var usesText: Bool { self != .emailOnly }
        var usesEmail: Bool { self != .textOnly }
    }

    enum Channel: String, CaseIterable, Equatable {
        case text
        case email

        var displayName: String { self == .text ? "Text" : "Email" }
    }

    enum ExclusionReason: Equatable, Hashable {
        case archived
        case optedOut
        case openWork
        case maintenancePlan
        case recentlyContacted
        case noContact
        case duplicateContact(ofCustomerID: String, ofName: String)
        case removedByOwner

        /// Groups the exclusion list ("Opted out (3)"). Duplicates group per
        /// kept customer ("Same phone or email as Dana Ortiz (1)").
        var groupKey: String {
            switch self {
            case .archived: "archived"
            case .optedOut: "opted_out"
            case .openWork: "open_work"
            case .maintenancePlan: "maintenance_plan"
            case .recentlyContacted: "recently_contacted"
            case .noContact: "no_contact"
            case let .duplicateContact(id, _): "duplicate:\(id)"
            case .removedByOwner: "removed_by_owner"
            }
        }

        var label: String {
            switch self {
            case .archived: "Archived"
            case .optedOut: "Opted out"
            case .openWork: "Open work"
            case .maintenancePlan: "On a maintenance plan"
            case .recentlyContacted: "Contacted recently"
            case .noContact: "No usable phone or email"
            case let .duplicateContact(_, name): "Same phone or email as \(name)"
            case .removedByOwner: "Removed by you"
            }
        }
    }

    // MARK: Presets (spec §5.4)

    enum Preset: String, CaseIterable, Equatable {
        case dueForMaintenance = "due_for_maintenance"
        case annualCheckIn = "annual_check_in"
        case itsBeenAWhile = "its_been_a_while"
        case everyoneServed = "everyone_served"
        case neverBooked = "never_booked"
        case custom

        var displayName: String {
            switch self {
            case .dueForMaintenance: "Due for maintenance"
            case .annualCheckIn: "Annual check-in"
            case .itsBeenAWhile: "It's been a while"
            case .everyoneServed: "Everyone I've worked for"
            case .neverBooked: "Never booked"
            case .custom: "Custom"
            }
        }

        var summary: String {
            switch self {
            case .dueForMaintenance: "Last service 6 or more months ago, nothing booked, no maintenance plan"
            case .annualCheckIn: "Last service 11 to 13 months ago"
            case .itsBeenAWhile: "Last service 18 or more months ago"
            case .everyoneServed: "Anyone you've done a job for"
            case .neverBooked: "Leads and estimates that never became work"
            case .custom: "Start from scratch"
            }
        }

        /// Every preset keeps the default-on guards (D7), except that "Never
        /// booked" starts with the open-work guard off: its leads and open
        /// estimates are the point.
        var segment: Canonical.Campaign.Segment {
            switch self {
            case .dueForMaintenance:
                return .init(service: Service.served.rawValue,
                             minMonthsSinceService: NativeServiceHistory.maintenanceDueMonths)
            case .annualCheckIn:
                return .init(service: Service.served.rawValue, minMonthsSinceService: 11, maxMonthsSinceService: 13)
            case .itsBeenAWhile:
                return .init(service: Service.served.rawValue, minMonthsSinceService: 18)
            case .everyoneServed, .custom:
                return .init(service: Service.served.rawValue)
            case .neverBooked:
                // Leads and estimates are this preset's audience, so its
                // open-work guard starts off (the other two stay on).
                return .init(service: Service.neverServed.rawValue, excludeOpenWork: false)
            }
        }

        /// The suggested campaign name for a new draft.
        var suggestedName: String { self == .custom ? "New campaign" : displayName }
    }

    /// Typed views of the canonical segment's raw strings. A value from a
    /// newer client reads as the default.
    static func service(_ segment: Canonical.Campaign.Segment) -> Service {
        Service(rawValue: segment.service) ?? .served
    }

    static func referral(_ segment: Canonical.Campaign.Segment) -> Referral {
        Referral(rawValue: segment.referral) ?? .any
    }

    static func channelPlan(_ campaign: Canonical.Campaign) -> ChannelPlan {
        ChannelPlan(rawValue: campaign.channelPlan) ?? .textFirst
    }

    // MARK: Evaluation (spec §5.2)

    /// Every stored customer is tested in order; the first failing rule is
    /// the exclusion reason. A customer who fails a filter is simply not
    /// matched. Linear: jobs are grouped by `customerId` once.
    static func evaluate(
        segment: Canonical.Campaign.Segment,
        channelPlan: ChannelPlan,
        customers: [Canonical.Customer],
        jobs: [Canonical.Job],
        recurringJobs: [Canonical.RecurringJob],
        campaigns: [Canonical.Campaign],
        manualExclusions: [String],
        canEmail: Bool,
        now: Date
    ) -> NativeCampaignAudience {
        let jobsByCustomer = NativeServiceHistory.jobsByCustomer(jobs)
        let service = service(segment)
        let referral = referral(segment)
        let keywords = segment.jobKeywords.compactMap(keywordTokens).filter { !$0.isEmpty }
        let tagsAny = Set(segment.tagsAny.map(NativeCustomerTags.key).filter { !$0.isEmpty })
        let tagsNone = Set(segment.tagsNone.map(NativeCustomerTags.key).filter { !$0.isEmpty })
        let leadSources = Set(segment.leadSources)
        let referrers = Set(customers.compactMap(referrerID))
        let lastContacted = lastSentDayByCustomer(campaigns)
        let today = NativeCashBasis.ymd(now)
        let manual = Set(manualExclusions)

        struct Candidate {
            let customer: Canonical.Customer
            let channel: Channel
            let contact: String
            let last: NativeServiceHistory.LastService?
        }

        var exclusions: [NativeCampaignAudience.Exclusion] = []
        var counts = NativeCampaignAudience.Counts()
        var candidates: [Candidate] = []

        func exclude(_ customer: Canonical.Customer, _ reason: ExclusionReason) {
            exclusions.append(.init(customerID: customer.id, name: displayName(customer), reason: reason))
        }

        for customer in customers where !customer.id.isEmpty {
            // 1. Fixed exclusions (never overridable).
            if !(customer.archivedAt ?? "").isEmpty { exclude(customer, .archived); continue }
            if customer.isMarketingOptedOut { exclude(customer, .optedOut); continue }

            // 2. Filters (AND across kinds).
            let last = NativeServiceHistory.lastService(customerID: customer.id, jobsByCustomer: jobsByCustomer)
            switch service {
            case .any:
                break
            case .served:
                guard NativeServiceHistory.hasDeliveredJob(customerID: customer.id, jobsByCustomer: jobsByCustomer)
                else { continue }
                if segment.minMonthsSinceService != nil || segment.maxMonthsSinceService != nil {
                    guard let last else { continue }
                    let months = NativeServiceHistory.monthsBetween(from: last.date, now: now)
                    if let minimum = segment.minMonthsSinceService, months < minimum { continue }
                    if let maximum = segment.maxMonthsSinceService, months > maximum { continue }
                }
            case .neverServed:
                guard !NativeServiceHistory.hasDeliveredJob(customerID: customer.id, jobsByCustomer: jobsByCustomer)
                else { continue }
            }
            if !keywords.isEmpty {
                let titles = NativeServiceHistory.deliveredTitles(customerID: customer.id, jobsByCustomer: jobsByCustomer)
                    .map(titleTokens)
                guard titles.contains(where: { title in keywords.contains { matches(title: title, keyword: $0) } })
                else { continue }
            }
            let tagKeys = Set((NativeCustomerTags.normalizeList(customer.tags) ?? []).map(NativeCustomerTags.key))
            if !tagsAny.isEmpty, tagKeys.isDisjoint(with: tagsAny) { continue }
            if !tagsNone.isEmpty, !tagKeys.isDisjoint(with: tagsNone) { continue }
            if !leadSources.isEmpty, !leadSources.contains(NativeLeadSource.bucketKey(customer.leadSource)) { continue }
            switch referral {
            case .any: break
            case .cameFromReferral:
                guard NativeLeadSource.normalize(customer.leadSource) == "referral" else { continue }
            case .hasReferred:
                guard referrers.contains(customer.id) else { continue }
            }
            counts.matched += 1

            // 3. Guards (default on, owner-toggleable).
            if segment.excludeOpenWork,
               NativeServiceHistory.hasOpenWork(customerID: customer.id, jobsByCustomer: jobsByCustomer) {
                exclude(customer, .openWork); continue
            }
            if segment.excludeMaintenancePlans,
               NativeServiceHistory.hasActiveMaintenancePlan(customerID: customer.id, recurringJobs: recurringJobs) {
                exclude(customer, .maintenancePlan); continue
            }
            if segment.excludeContactedWithinDays > 0, let sentDay = lastContacted[customer.id],
               let days = daysBetween(sentDay, today), days < segment.excludeContactedWithinDays {
                exclude(customer, .recentlyContacted); continue
            }

            // 4. Reachability under the channel plan.
            guard let choice = channel(for: customer, plan: channelPlan, canEmail: canEmail) else {
                if !canEmail, channel(for: customer, plan: channelPlan, canEmail: true) != nil {
                    counts.reachableOnceAddressSet += 1
                }
                exclude(customer, .noContact); continue
            }
            candidates.append(.init(customer: customer, channel: choice.channel, contact: choice.contact, last: last))
        }

        // 5. Duplicate contact: candidates sharing phone digits (last 10) or a
        //    lowercased email collapse to one (union by either key).
        var parent = Array(candidates.indices)
        func root(_ index: Int) -> Int {
            var node = index
            while parent[node] != node { parent[node] = parent[parent[node]]; node = parent[node] }
            return node
        }
        var ownerOfKey: [String: Int] = [:]
        for (index, candidate) in candidates.enumerated() {
            let keys = [
                NativeCampaignContact.phoneKey(candidate.customer.phone).map { "p:" + $0 },
                NativeCampaignContact.emailKey(candidate.customer.email).map { "e:" + $0 },
            ].compactMap { $0 }
            for key in keys {
                if let other = ownerOfKey[key] {
                    let a = root(index), b = root(other)
                    if a != b { parent[a] = b }
                } else {
                    ownerOfKey[key] = index
                }
            }
        }
        // The kept one: the most recent service date, then the earliest
        // `createdAt` (a missing one sorts last), then the smallest id.
        func keepsBefore(_ a: Candidate, _ b: Candidate) -> Bool {
            let aDate = a.last?.date ?? "", bDate = b.last?.date ?? ""
            if aDate != bDate { return aDate > bDate }
            let aCreated = a.customer.createdAt ?? "\u{10FFFF}", bCreated = b.customer.createdAt ?? "\u{10FFFF}"
            if aCreated != bCreated { return aCreated < bCreated }
            return a.customer.id < b.customer.id
        }
        var groups: [Int: [Int]] = [:]
        var groupOrder: [Int] = []
        for index in candidates.indices {
            let key = root(index)
            if groups[key] == nil { groupOrder.append(key) }
            groups[key, default: []].append(index)
        }
        var kept: [Candidate] = []
        for key in groupOrder {
            let ordered = (groups[key] ?? []).sorted { keepsBefore(candidates[$0], candidates[$1]) }
            guard let winnerIndex = ordered.first else { continue }
            let winner = candidates[winnerIndex]
            kept.append(winner)
            for loser in ordered.dropFirst() {
                exclude(candidates[loser].customer,
                        .duplicateContact(ofCustomerID: winner.customer.id, ofName: displayName(winner.customer)))
            }
        }

        // 6. Manual exclusions.
        var recipients: [NativeCampaignAudience.Member] = []
        for candidate in kept {
            if manual.contains(candidate.customer.id) { exclude(candidate.customer, .removedByOwner); continue }
            let name = displayName(candidate.customer)
            recipients.append(.init(
                customerID: candidate.customer.id,
                name: name,
                firstName: NativeCampaignMessage.firstName(name),
                channel: candidate.channel,
                contact: candidate.contact,
                lastServiceDate: candidate.last?.date,
                lastJobTitle: candidate.last.map(\.title).flatMap { $0.isEmpty ? nil : $0 }
            ))
        }
        recipients.sort(by: nameOrder)
        exclusions.sort { lhs, rhs in
            if lhs.reason.groupKey != rhs.reason.groupKey { return lhs.reason.groupKey < rhs.reason.groupKey }
            return nameOrder(lhs, rhs)
        }
        counts.byText = recipients.filter { $0.channel == .text }.count
        counts.byEmail = recipients.filter { $0.channel == .email }.count
        counts.reachable = recipients.count
        for exclusion in exclusions { counts.excludedByReason[exclusion.reason.groupKey, default: 0] += 1 }
        return .init(recipients: recipients, exclusions: exclusions, counts: counts)
    }

    /// The channel and live contact a customer gets under `plan`, or `nil`.
    static func channel(
        for customer: Canonical.Customer,
        plan: ChannelPlan,
        canEmail: Bool
    ) -> (channel: Channel, contact: String)? {
        let phone = NativeCampaignContact.isTextable(customer.phone)
            ? customer.phone.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        let email = canEmail && NativeCampaignContact.isEmailable(customer.email)
            ? customer.email.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        switch plan {
        case .textFirst:
            if let phone { return (.text, phone) }
            if let email { return (.email, email) }
        case .emailFirst:
            if let email { return (.email, email) }
            if let phone { return (.text, phone) }
        case .textOnly:
            if let phone { return (.text, phone) }
        case .emailOnly:
            if let email { return (.email, email) }
        }
        return nil
    }

    // MARK: Job-type keywords (spec §5.1, D5)

    /// Spec §5.1: the 20 most frequent words in delivered job titles, stop
    /// words and words under 3 characters removed, as one-tap chips.
    static func keywordSuggestions(jobs: [Canonical.Job], limit: Int = 20) -> [String] {
        var counts: [String: Int] = [:]
        for job in jobs where NativeServiceHistory.deliveredStatuses.contains(job.status) {
            for word in Set(titleTokens(job.title)) where word.count >= 3 && !stopWords.contains(word) {
                guard !word.allSatisfy(\.isNumber) else { continue }
                counts[word, default: 0] += 1
            }
        }
        return counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(limit).map(\.key)
    }

    static let stopWords: Set<String> = [
        "the", "and", "for", "with", "from", "into", "onto", "per", "our", "your", "their", "this", "that",
        "new", "old", "job", "jobs", "work", "item", "items", "misc", "other", "general", "call", "visit",
        "quote", "estimate", "booked", "appointment", "request",
    ]

    /// Folded alphanumeric words.
    static func titleTokens(_ title: String) -> [String] {
        title.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    private static func keywordTokens(_ keyword: String) -> [String]? {
        let tokens = titleTokens(keyword)
        return tokens.isEmpty ? nil : tokens
    }

    /// The keyword's words appear contiguously in the title, each as a whole
    /// word or its plural ("furnace" matches "Furnace tune-up" and
    /// "furnaces", never "AC" inside "Back porch").
    static func matches(title: [String], keyword: [String]) -> Bool {
        guard !keyword.isEmpty, title.count >= keyword.count else { return false }
        for start in 0...(title.count - keyword.count) {
            let window = title[start..<(start + keyword.count)]
            if zip(window, keyword).allSatisfy({ word, wanted in
                word == wanted || word == wanted + "s" || word == wanted + "es"
            }) { return true }
        }
        return false
    }

    // MARK: Helpers

    static func displayName(_ customer: Canonical.Customer) -> String {
        let trimmed = customer.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Unnamed customer" : trimmed
    }

    /// Phase 34 (referrals) types `referredByCustomerId` on the customer, so
    /// it is read from the typed field (it no longer lands in the preserved
    /// unknown fields).
    static func referrerID(_ customer: Canonical.Customer) -> String? {
        guard let id = customer.referredByCustomerId, !id.isEmpty else { return nil }
        return id
    }

    /// Whether any customer carries a referrer, so the builder can offer
    /// "Has referred someone" (spec §5.2: hidden before Phase 34 data exists).
    static func referralDataAvailable(_ customers: [Canonical.Customer]) -> Bool {
        customers.contains { referrerID($0) != nil }
    }

    /// The latest local day each customer was sent any campaign.
    static func lastSentDayByCustomer(_ campaigns: [Canonical.Campaign]) -> [String: String] {
        var out: [String: String] = [:]
        for campaign in campaigns {
            for recipient in campaign.recipients ?? [] where recipient.status == NativeCampaignQueue.Status.sent.rawValue {
                guard let day = localDay(recipient.sentAt) else { continue }
                if day > (out[recipient.customerId] ?? "") { out[recipient.customerId] = day }
            }
        }
        return out
    }

    /// The device-local `YYYY-MM-DD` of an ISO instant (or a bare date).
    static func localDay(_ value: String?) -> String? {
        guard let value, !value.isEmpty, let date = NativeCashBasis.parseLocalDate(value) else { return nil }
        return NativeCashBasis.ymd(date)
    }

    /// Whole days from `from` to `to` (both local `YYYY-MM-DD`).
    static func daysBetween(_ from: String, _ to: String) -> Int? {
        guard let a = NativeSchedule.epochDays(from), let b = NativeSchedule.epochDays(to) else { return nil }
        return b - a
    }

    private static func nameOrder(_ lhs: NativeCampaignAudience.Member, _ rhs: NativeCampaignAudience.Member) -> Bool {
        let order = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
        if order != .orderedSame { return order == .orderedAscending }
        return lhs.customerID < rhs.customerID
    }

    private static func nameOrder(_ lhs: NativeCampaignAudience.Exclusion, _ rhs: NativeCampaignAudience.Exclusion) -> Bool {
        let order = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
        if order != .orderedSame { return order == .orderedAscending }
        return lhs.customerID < rhs.customerID
    }
}

// MARK: - The send queue (spec §7)

/// Typed failures for campaign writes. Nothing changes on refusal.
enum NativeCampaignError: Error, Equatable {
    case notFound
    case invalidName
    /// The message is locked after the first send (C3): duplicate to change.
    case messageLocked
    /// Freezing needs a draft.
    case notADraft
    /// The queue only runs while `sending`.
    case notSending
    case emptyAudience
    /// C4: more than 200 recipients.
    case tooManyRecipients(Int)
    /// The message has a blocking problem (`NativeCampaignMessage.validate`).
    case invalidMessage([NativeCampaignMessage.Issue])
    case recipientNotFound
    /// The recipient is not in a state this action applies to.
    case recipientNotPending
    case customerNotFound
    /// The device could not save (read-only local data or a disk failure).
    case notSaved
}

enum NativeCampaignQueue {
    enum Status: String, Equatable {
        case pending, sent, skipped, failed
    }

    enum CampaignStatus: String, Equatable {
        case draft, sending, done
    }

    enum SkipReason: String, Equatable, CaseIterable {
        case optedOut = "opted_out"
        case archived
        case noContact = "no_contact"
        case deleted
        case owner
        case ended

        var displayName: String {
            switch self {
            case .optedOut: "opted out"
            case .archived: "archived"
            case .noContact: "no phone or email"
            case .deleted: "customer deleted"
            case .owner: "skipped"
            case .ended: "campaign ended"
            }
        }
    }

    /// The composer outcome the queue reacts to (spec §7.3), the same cases
    /// as `NativeMessageComposeOutcome`.
    enum Outcome: Equatable {
        case sent, cancelled, saved, failed
    }

    struct OutcomeResult: Equatable {
        var campaign: Canonical.Campaign
        /// Open the next composer automatically (only after `.sent`, when the
        /// owner's toggle is on).
        var advances: Bool
        var notice: String?
    }

    static let savedDraftNotice =
        "Saved as a draft in Mail. It wasn't sent. Use Mark as sent after you send it."
    static let failedNotice = "The message didn't send. Retry when you're ready."

    static func status(_ recipient: Canonical.Campaign.Recipient) -> Status {
        Status(rawValue: recipient.status) ?? .pending
    }

    static func campaignStatus(_ campaign: Canonical.Campaign) -> CampaignStatus {
        CampaignStatus(rawValue: campaign.status) ?? .draft
    }

    static func channel(_ recipient: Canonical.Campaign.Recipient) -> NativeCampaignSegments.Channel {
        NativeCampaignSegments.Channel(rawValue: recipient.channel) ?? .text
    }

    // MARK: Freeze (spec §7.1)

    /// "Start sending": the audience becomes the recipient list, the campaign
    /// becomes `sending`. Refused for an empty or over-cap audience and for a
    /// message with a blocking issue.
    static func freeze(
        _ campaign: Canonical.Campaign,
        audience: NativeCampaignAudience,
        blockingIssues: [NativeCampaignMessage.Issue],
        today: String
    ) throws -> Canonical.Campaign {
        guard campaignStatus(campaign) == .draft else { throw NativeCampaignError.notADraft }
        guard blockingIssues.isEmpty else { throw NativeCampaignError.invalidMessage(blockingIssues) }
        guard !audience.recipients.isEmpty else { throw NativeCampaignError.emptyAudience }
        guard !audience.exceedsCap else { throw NativeCampaignError.tooManyRecipients(audience.recipients.count) }
        var frozen = campaign
        frozen.recipients = audience.recipients.map {
            .init(customerId: $0.customerID, name: $0.name, channel: $0.channel.rawValue)
        }
        frozen.frozenOn = today
        frozen.status = CampaignStatus.sending.rawValue
        return frozen
    }

    // MARK: Progress and resume (spec §7.2)

    struct Progress: Equatable {
        var total = 0
        var sent = 0
        var skipped = 0
        var failed = 0
        var pending = 0
        var replied = 0
        var skippedByReason: [String: Int] = [:]

        var isFinished: Bool { pending == 0 && failed == 0 }
    }

    static func progress(_ campaign: Canonical.Campaign) -> Progress {
        var out = Progress()
        for recipient in campaign.recipients ?? [] {
            out.total += 1
            switch status(recipient) {
            case .pending: out.pending += 1
            case .sent: out.sent += 1
            case .failed: out.failed += 1
            case .skipped:
                out.skipped += 1
                out.skippedByReason[recipient.skipReason ?? SkipReason.owner.rawValue, default: 0] += 1
            }
            if !(recipient.repliedOn ?? "").isEmpty { out.replied += 1 }
        }
        return out
    }

    /// Resume opens at the first `pending` recipient.
    static func nextPendingIndex(_ campaign: Canonical.Campaign) -> Int? {
        campaign.recipients?.firstIndex { status($0) == .pending }
    }

    // MARK: Live re-validation (spec §7.3)

    enum LiveCheck: Equatable {
        /// Present the composer to this live contact.
        case ready(contact: String)
        case skip(SkipReason)
    }

    /// Before each composer opens: the customer exists, is not archived, is
    /// not opted out, and the channel's contact is still usable. The
    /// composer always uses the live contact, never a snapshot.
    static func liveCheck(
        _ recipient: Canonical.Campaign.Recipient,
        customers: [Canonical.Customer]
    ) -> LiveCheck {
        guard let customer = customers.first(where: { $0.id == recipient.customerId }) else { return .skip(.deleted) }
        if !(customer.archivedAt ?? "").isEmpty { return .skip(.archived) }
        if customer.isMarketingOptedOut { return .skip(.optedOut) }
        switch channel(recipient) {
        case .text:
            guard NativeCampaignContact.isTextable(customer.phone) else { return .skip(.noContact) }
            return .ready(contact: customer.phone.trimmingCharacters(in: .whitespacesAndNewlines))
        case .email:
            guard NativeCampaignContact.isEmailable(customer.email) else { return .skip(.noContact) }
            return .ready(contact: customer.email.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    // MARK: Outcomes (spec §7.3)

    /// The outcome table: `.sent` sends (and locks the message on the first
    /// send), `.cancelled` keeps the card, `.saved` keeps it with a notice,
    /// `.failed` marks it failed (Retry makes it pending again).
    static func apply(
        _ outcome: Outcome,
        to campaign: Canonical.Campaign,
        customerID: String,
        autoAdvance: Bool,
        nowISO: String
    ) throws -> OutcomeResult {
        guard campaignStatus(campaign) == .sending else { throw NativeCampaignError.notSending }
        guard let index = campaign.recipients?.firstIndex(where: { $0.customerId == customerID }) else {
            throw NativeCampaignError.recipientNotFound
        }
        guard var recipients = campaign.recipients, status(recipients[index]) == .pending else {
            throw NativeCampaignError.recipientNotPending
        }
        var updated = campaign
        switch outcome {
        case .sent:
            recipients[index].status = Status.sent.rawValue
            recipients[index].sentAt = nowISO
            recipients[index].skipReason = nil
            updated.recipients = recipients
            if updated.message.lockedAt == nil { updated.message.lockedAt = nowISO }
            return .init(campaign: completedIfFinished(updated, nowISO: nowISO), advances: autoAdvance, notice: nil)
        case .cancelled:
            return .init(campaign: campaign, advances: false, notice: nil)
        case .saved:
            return .init(campaign: campaign, advances: false, notice: savedDraftNotice)
        case .failed:
            recipients[index].status = Status.failed.rawValue
            updated.recipients = recipients
            return .init(campaign: updated, advances: false, notice: failedNotice)
        }
    }

    /// "Mark as sent" (copy-and-paste or URL-scheme fallback): `manual`. A
    /// failed recipient can be marked too (it may have gone out by hand).
    static func markSent(_ campaign: Canonical.Campaign, customerID: String, nowISO: String) throws -> Canonical.Campaign {
        var source = campaign
        if let index = source.recipients?.firstIndex(where: { $0.customerId == customerID }),
           let recipient = source.recipients?[index], status(recipient) == .failed {
            source.recipients?[index].status = Status.pending.rawValue
        }
        var updated = try apply(.sent, to: source, customerID: customerID, autoAdvance: false, nowISO: nowISO).campaign
        if let index = updated.recipients?.firstIndex(where: { $0.customerId == customerID }) {
            updated.recipients?[index].manual = true
        }
        return updated
    }

    /// "Skip", "They asked to stop" and the live-check auto-skip.
    static func skip(
        _ campaign: Canonical.Campaign,
        customerID: String,
        reason: SkipReason,
        nowISO: String
    ) throws -> Canonical.Campaign {
        guard campaignStatus(campaign) == .sending else { throw NativeCampaignError.notSending }
        guard var recipients = campaign.recipients,
              let index = recipients.firstIndex(where: { $0.customerId == customerID })
        else { throw NativeCampaignError.recipientNotFound }
        guard [.pending, .failed].contains(status(recipients[index])) else { throw NativeCampaignError.recipientNotPending }
        recipients[index].status = Status.skipped.rawValue
        recipients[index].skipReason = reason.rawValue
        var updated = campaign
        updated.recipients = recipients
        return completedIfFinished(updated, nowISO: nowISO)
    }

    /// "Retry" on a failed recipient.
    static func retry(_ campaign: Canonical.Campaign, customerID: String) throws -> Canonical.Campaign {
        guard campaignStatus(campaign) == .sending else { throw NativeCampaignError.notSending }
        guard var recipients = campaign.recipients,
              let index = recipients.firstIndex(where: { $0.customerId == customerID })
        else { throw NativeCampaignError.recipientNotFound }
        guard status(recipients[index]) == .failed else { throw NativeCampaignError.recipientNotPending }
        recipients[index].status = Status.pending.rawValue
        var updated = campaign
        updated.recipients = recipients
        return updated
    }

    /// "End campaign": every remaining pending (or failed) recipient becomes
    /// `skipped`/`ended` and the campaign is done.
    static func end(_ campaign: Canonical.Campaign, nowISO: String) throws -> Canonical.Campaign {
        guard campaignStatus(campaign) == .sending else { throw NativeCampaignError.notSending }
        var updated = campaign
        updated.recipients = campaign.recipients?.map { recipient in
            guard [.pending, .failed].contains(status(recipient)) else { return recipient }
            var ended = recipient
            ended.status = Status.skipped.rawValue
            ended.skipReason = SkipReason.ended.rawValue
            return ended
        }
        updated.status = CampaignStatus.done.rawValue
        updated.endedAt = nowISO
        return updated
    }

    /// Marks the campaign done once nobody is pending or failed.
    static func completedIfFinished(_ campaign: Canonical.Campaign, nowISO: String) -> Canonical.Campaign {
        guard campaignStatus(campaign) == .sending, progress(campaign).isFinished else { return campaign }
        var done = campaign
        done.status = CampaignStatus.done.rawValue
        return done
    }

    /// "Replied" on a sent recipient (owner-marked); `nil` clears it.
    static func markReplied(_ campaign: Canonical.Campaign, customerID: String, on day: String?) throws -> Canonical.Campaign {
        guard var recipients = campaign.recipients,
              let index = recipients.firstIndex(where: { $0.customerId == customerID })
        else { throw NativeCampaignError.recipientNotFound }
        guard status(recipients[index]) == .sent else { throw NativeCampaignError.recipientNotPending }
        recipients[index].repliedOn = day
        var updated = campaign
        updated.recipients = recipients
        return updated
    }

    /// "Duplicate campaign": an editable draft copy with the same audience
    /// rules and message, a new id and code, and no recipients (C3, D12).
    static func duplicate(
        _ campaign: Canonical.Campaign,
        id: String,
        code: String,
        createdAt: String
    ) -> Canonical.Campaign {
        var message = campaign.message
        message.lockedAt = nil
        let name = String("\(campaign.name) (copy)".prefix(NativeCampaignMessage.nameMaxLength))
        return Canonical.Campaign(
            id: id, name: name, code: code, createdAt: createdAt,
            status: CampaignStatus.draft.rawValue, segment: campaign.segment,
            channelPlan: campaign.channelPlan, message: message,
            manualExclusions: campaign.manualExclusions
        )
    }

    // MARK: Quiet hours (spec §7.3, D14)

    /// Outside 8:00–20:00 device-local time: a warning, never a block. The
    /// owner's timezone stands in for the customers'.
    static func quietHoursWarning(now: Date, calendar: Calendar = .current) -> String? {
        let parts = calendar.dateComponents([.hour, .minute], from: now)
        let hour = parts.hour ?? 12
        guard hour < 8 || hour >= 20 else { return nil }
        let minute = parts.minute ?? 0
        let twelve = hour % 12 == 0 ? 12 : hour % 12
        let clock = String(format: "%d:%02d %@", twelve, minute, hour < 12 ? "AM" : "PM")
        return hour >= 20
            ? "It's \(clock). Many states restrict marketing texts in the evening. Consider resuming tomorrow."
            : "It's \(clock). Many states restrict marketing texts early in the morning. Consider waiting until 8 AM."
    }

    /// Spec §7.1: the carrier-filter hint for large text sends.
    static func largeTextSendHint(textCount: Int) -> String? {
        textCount > 50
            ? "Sending many identical texts from a personal number can trip carrier spam filters. Personalized messages help, and you can pause and finish tomorrow."
            : nil
    }

    /// "Sent 31 · Skipped 3: 2 opted out, 1 no phone or email".
    static func summary(_ campaign: Canonical.Campaign) -> String {
        let progress = progress(campaign)
        var text = "Sent \(progress.sent)"
        if progress.skipped > 0 {
            let reasons = SkipReason.allCases.compactMap { reason -> String? in
                guard let count = progress.skippedByReason[reason.rawValue], count > 0 else { return nil }
                return "\(count) \(reason.displayName)"
            }
            text += " · Skipped \(progress.skipped)" + (reasons.isEmpty ? "" : ": " + reasons.joined(separator: ", "))
        }
        if progress.failed > 0 { text += " · Failed \(progress.failed)" }
        return text
    }
}
