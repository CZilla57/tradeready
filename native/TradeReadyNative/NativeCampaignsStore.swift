import Foundation

/// Phase 33 (past-customer campaigns and customer tags): the `AppStore` API the
/// customer tag and opt-out controls, the campaign list, builder, send session
/// and results build on. Spec: `docs/superpowers/specs/2026-10-03-campaigns-tags-design.md`.
///
/// Every write re-reads the stored record by id, applies one pure operation
/// (`NativeCustomerTags`, `NativeMarketingOptOut`, `NativeCampaignQueue`) and
/// commits through `commitMarketingRecords` (durable save, publish, then one
/// queue batch). Nothing is changed on refusal. Sending is always one
/// reviewed Apple composer per recipient; nothing here sends anything.
extension AppStore {
    /// The `{bookingLink}` state for this session (spec §6.1, Phase 34's states).
    enum CampaignBookingLinkState: Equatable {
        case unknown
        case off
        /// The status could not be confirmed (offline or signed out): Retry.
        case unverified
        case ready(URL)

        var url: URL? {
            if case let .ready(url) = self { return url }
            return nil
        }
    }

    // MARK: - Reads

    /// Drafts and campaigns in progress first, then done ones; newest first.
    var campaigns: [Canonical.Campaign] {
        campaignRecords.sorted { lhs, rhs in
            let lhsDone = NativeCampaignQueue.campaignStatus(lhs) == .done
            let rhsDone = NativeCampaignQueue.campaignStatus(rhs) == .done
            if lhsDone != rhsDone { return !lhsDone }
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
            return lhs.id < rhs.id
        }
    }

    func campaign(id: String) -> Canonical.Campaign? {
        campaignRecords.first { $0.id == id }
    }

    // `canonicalCustomer(id:)` is declared once, in
    // `NativePropertiesEquipmentStore.swift` (Phase 21), with the same body.

    /// Spec §3.1: the tags in use, by count.
    var customerTagVocabulary: [NativeCustomerTags.Entry] {
        NativeCustomerTags.vocabulary(canonicalCustomers)
    }

    /// The business values the merge fields and the footer read. The default
    /// placeholder name counts as unset, so Send stays blocked until the
    /// owner sets a real one.
    var campaignBusiness: NativeCampaignMessage.Business {
        let name = settings.businessName == BusinessSettings().businessName ? "" : settings.businessName
        return .init(businessName: name, ownerName: settings.contactName, phone: settings.phone, address: settings.address)
    }

    /// Spec §6.3: email needs a Business address.
    var campaignCanEmail: Bool { campaignBusiness.hasAddress }

    func campaignAudience(
        segment: Canonical.Campaign.Segment,
        channelPlan: NativeCampaignSegments.ChannelPlan,
        manualExclusions: [String],
        now: Date = .now
    ) -> NativeCampaignAudience {
        NativeCampaignSegments.evaluate(
            segment: segment,
            channelPlan: channelPlan,
            customers: canonicalCustomers,
            jobs: canonicalJobs,
            recurringJobs: recurringJobRules,
            campaigns: campaignRecords,
            manualExclusions: manualExclusions,
            canEmail: campaignCanEmail,
            now: now
        )
    }

    func campaignAudience(for campaign: Canonical.Campaign, now: Date = .now) -> NativeCampaignAudience {
        campaignAudience(
            segment: campaign.segment,
            channelPlan: NativeCampaignSegments.channelPlan(campaign),
            manualExclusions: campaign.manualExclusions ?? [],
            now: now
        )
    }

    func campaignResults(_ campaign: Canonical.Campaign, now: Date = .now) -> NativeCampaignResults {
        NativeCampaignResults.make(
            campaign: campaign, campaigns: campaignRecords, jobs: canonicalJobs,
            invoices: canonicalInvoices, customers: canonicalCustomers, now: now
        )
    }

    var campaignKeywordSuggestions: [String] {
        NativeCampaignSegments.keywordSuggestions(jobs: canonicalJobs)
    }

    /// "Has referred someone" is offered only once referral data exists.
    var campaignReferralFilterAvailable: Bool {
        NativeCampaignSegments.referralDataAvailable(canonicalCustomers)
    }

    /// The message issues for every kind the audience will receive, template
    /// problems first.
    func campaignMessageIssues(
        _ campaign: Canonical.Campaign,
        kinds: Set<NativeCampaignMessage.Kind>,
        bookingLink: CampaignBookingLinkState
    ) -> [NativeCampaignMessage.Issue] {
        var issues: [NativeCampaignMessage.Issue] = []
        for kind in NativeCampaignMessage.Kind.allCases where kinds.contains(kind) {
            let body = kind == .text ? campaign.message.text : campaign.message.emailBody
            let subject = kind == .email ? campaign.message.emailSubject : nil
            for issue in NativeCampaignMessage.validate(kind: kind, body: body, subject: subject)
                + NativeCampaignMessage.contextIssues(
                    kind: kind, body: body, subject: subject, business: campaignBusiness,
                    bookingLinkReady: bookingLink.url != nil
                ) where !issues.contains(issue) {
                issues.append(issue)
            }
        }
        return issues
    }

    /// The exact message one recipient receives.
    func renderCampaignMessage(
        _ campaign: Canonical.Campaign,
        kind: NativeCampaignMessage.Kind,
        customerID: String,
        fallbackName: String,
        bookingLink: CampaignBookingLinkState
    ) -> NativeCampaignMessage.Rendered {
        let jobsByCustomer = NativeServiceHistory.jobsByCustomer(canonicalJobs)
        let last = NativeServiceHistory.lastService(customerID: customerID, jobsByCustomer: jobsByCustomer)
        let liveName = canonicalCustomer(id: customerID)?.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let recipient = NativeCampaignMessage.Recipient(
            name: (liveName?.isEmpty == false ? liveName : nil) ?? fallbackName,
            lastJobTitle: last?.title,
            lastServiceDate: last?.date
        )
        let link = bookingLink.url.flatMap { NativeCampaignMessage.campaignLink(base: $0, code: campaign.code) }
        return NativeCampaignMessage.render(
            kind: kind,
            body: (kind == .text ? campaign.message.text : campaign.message.emailBody) ?? "",
            subject: kind == .email ? campaign.message.emailSubject : nil,
            recipient: recipient,
            business: campaignBusiness,
            bookingLink: link
        )
    }

    /// Resolves `{bookingLink}` once per session through the fresh-status
    /// check sharing already requires (`reconcileBookingLinkForSharing`).
    func resolveCampaignBookingLink() async -> CampaignBookingLinkState {
        let reconciled = await reconcileBookingLinkForSharing()
        if let status = reconciled.status, !status.enabled { return .off }
        if let url = reconciled.shareURL { return .ready(url) }
        return .unverified
    }

    /// Spec §4.3: the review-request sheet's informational line (never a block).
    func customerOptedOutOfMarketing(jobID: String) -> Bool {
        guard let customerID = canonicalJobs.first(where: { $0.id == jobID })?.customerId else { return false }
        return canonicalCustomer(id: customerID)?.isMarketingOptedOut ?? false
    }

    // MARK: - Customer tags and the marketing opt-out

    /// Spec §3.2: replaces the customer's tags (normalized; `nil` when none).
    @discardableResult
    func setCustomerTags(customerID: String, tags: [String]) -> Bool {
        guard var customer = canonicalCustomer(id: customerID) else { return false }
        let normalized = NativeCustomerTags.normalizeList(tags)
        guard normalized != customer.tags else { return true }
        customer.tags = normalized
        return commitMarketingRecords(customers: [customer], campaign: nil)
    }

    /// Spec §4.1: "Do not contact for marketing", dated today (local).
    @discardableResult
    func setMarketingOptOut(customerID: String, via: NativeMarketingOptOut.Via, on date: Date = .now) -> Bool {
        guard let customer = canonicalCustomer(id: customerID) else { return false }
        let updated = NativeMarketingOptOut.optedOut(customer, on: NativeCashBasis.ymd(date), via: via)
        guard updated.marketingOptOutOn != customer.marketingOptOutOn else { return true }
        return commitMarketingRecords(customers: [updated], campaign: nil)
    }

    /// Spec §4.1: turning it off (after the owner confirms).
    @discardableResult
    func clearMarketingOptOut(customerID: String) -> Bool {
        guard let customer = canonicalCustomer(id: customerID) else { return false }
        guard customer.isMarketingOptedOut || customer.marketingOptOutVia != nil else { return true }
        return commitMarketingRecords(customers: [NativeMarketingOptOut.cleared(customer)], campaign: nil)
    }

    // MARK: - Campaign drafts

    /// A new, unsaved draft from a preset (spec §5.4) with a fresh id and
    /// `?c=` code. The builder stores it on the first save
    /// (`saveCampaignDraft`), so opening the builder and leaving writes nothing.
    func makeCampaignDraft(preset: NativeCampaignSegments.Preset, on date: Date = .now) -> Canonical.Campaign {
        Canonical.Campaign(
            id: Self.makeCampaignID(existing: Set(campaignRecords.map(\.id))),
            name: preset.suggestedName,
            code: NativeAttributionCode.makeUniqueCode(existing: Set(campaignRecords.map(\.code))),
            createdAt: Self.campaignTimestamp(date),
            segment: preset.segment,
            channelPlan: NativeCampaignSegments.ChannelPlan.textFirst.rawValue,
            message: .init(goal: Self.defaultGoal(for: preset).rawValue)
        )
    }

    /// A new draft from a preset, stored right away.
    @discardableResult
    func createCampaign(
        preset: NativeCampaignSegments.Preset,
        on date: Date = .now
    ) -> Result<Canonical.Campaign, NativeCampaignError> {
        saveCampaignDraft(makeCampaignDraft(preset: preset, on: date))
    }

    /// Stores a builder draft: inserts it when new (as a `draft`, with no
    /// recipients), else `updateCampaignDraft`.
    @discardableResult
    func saveCampaignDraft(_ draft: Canonical.Campaign) -> Result<Canonical.Campaign, NativeCampaignError> {
        if campaign(id: draft.id) != nil { return updateCampaignDraft(draft) }
        var fresh = draft
        fresh.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fresh.name.isEmpty, fresh.name.count <= NativeCampaignMessage.nameMaxLength else { return .failure(.invalidName) }
        fresh.status = NativeCampaignQueue.CampaignStatus.draft.rawValue
        fresh.recipients = nil
        fresh.frozenOn = nil
        fresh.endedAt = nil
        fresh.message.lockedAt = nil
        if (fresh.manualExclusions ?? []).isEmpty { fresh.manualExclusions = nil }
        if let brief = fresh.message.brief { fresh.message.brief = String(brief.prefix(NativeCampaignMessage.briefMaxLength)) }
        return commitMarketingRecords(customers: [], campaign: fresh, mode: .insert) ? .success(fresh) : .failure(.notSaved)
    }

    /// Saves a draft's name, audience rules, channel plan, exclusions and
    /// message as edited on screen. Identity fields, status and recipients
    /// are kept from the stored row. Only a draft's rules change; a locked
    /// message never does (C3). An unchanged draft writes nothing.
    @discardableResult
    func updateCampaignDraft(_ edited: Canonical.Campaign) -> Result<Canonical.Campaign, NativeCampaignError> {
        guard let stored = campaign(id: edited.id) else { return .failure(.notFound) }
        let name = edited.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= NativeCampaignMessage.nameMaxLength else { return .failure(.invalidName) }
        var next = stored
        next.name = name
        if NativeCampaignQueue.campaignStatus(stored) == .draft {
            next.segment = edited.segment
            next.channelPlan = edited.channelPlan
            next.manualExclusions = (edited.manualExclusions ?? []).isEmpty ? nil : edited.manualExclusions
            var message = edited.message
            message.lockedAt = stored.message.lockedAt
            if let brief = message.brief { message.brief = String(brief.prefix(NativeCampaignMessage.briefMaxLength)) }
            next.message = message
        } else if edited.message != stored.message || edited.segment != stored.segment
                    || edited.channelPlan != stored.channelPlan {
            return .failure(.messageLocked)
        }
        guard next != stored else { return .success(stored) }
        return commitMarketingRecords(customers: [], campaign: next) ? .success(next) : .failure(.notSaved)
    }

    /// "Duplicate campaign": an editable copy (C3, D12).
    @discardableResult
    func duplicateCampaign(id: String, on date: Date = .now) -> Result<Canonical.Campaign, NativeCampaignError> {
        guard let stored = campaign(id: id) else { return .failure(.notFound) }
        let copy = NativeCampaignQueue.duplicate(
            stored,
            id: Self.makeCampaignID(existing: Set(campaignRecords.map(\.id))),
            code: NativeAttributionCode.makeUniqueCode(existing: Set(campaignRecords.map(\.code))),
            createdAt: Self.campaignTimestamp(date)
        )
        return commitMarketingRecords(customers: [], campaign: copy, mode: .insert) ? .success(copy) : .failure(.notSaved)
    }

    /// "Start sending" (spec §7.1): freezes the current audience, persists it
    /// and enqueues the upsert. Refused for an empty or over-cap audience and
    /// for a blocking message issue.
    @discardableResult
    func startCampaignSending(
        id: String,
        bookingLink: CampaignBookingLinkState,
        on date: Date = .now
    ) -> Result<Canonical.Campaign, NativeCampaignError> {
        guard let stored = campaign(id: id) else { return .failure(.notFound) }
        let audience = campaignAudience(for: stored, now: date)
        var kinds: Set<NativeCampaignMessage.Kind> = []
        if audience.counts.byText > 0 { kinds.insert(.text) }
        if audience.counts.byEmail > 0 { kinds.insert(.email) }
        let blocking = campaignMessageIssues(stored, kinds: kinds, bookingLink: bookingLink).filter(\.isBlocking)
        do {
            let frozen = try NativeCampaignQueue.freeze(
                stored, audience: audience, blockingIssues: blocking, today: NativeCashBasis.ymd(date)
            )
            return commitMarketingRecords(customers: [], campaign: frozen) ? .success(frozen) : .failure(.notSaved)
        } catch {
            return .failure((error as? NativeCampaignError) ?? .notSaved)
        }
    }

    // MARK: - The send queue (spec §7)

    /// Spec §7.3: the live check before a composer opens. A failing customer
    /// is skipped right away with the reason (persisted), and the reason is
    /// returned for the notice.
    func prepareCampaignRecipient(
        campaignID: String,
        customerID: String,
        on date: Date = .now
    ) -> Result<NativeCampaignQueue.LiveCheck, NativeCampaignError> {
        guard let stored = campaign(id: campaignID) else { return .failure(.notFound) }
        guard let recipient = stored.recipients?.first(where: { $0.customerId == customerID }) else {
            return .failure(.recipientNotFound)
        }
        let check = NativeCampaignQueue.liveCheck(
            recipient, customers: canonicalCustomers,
            campaign: stored, campaigns: campaignRecords, today: NativeCashBasis.ymd(date)
        )
        if case let .skip(reason) = check {
            do {
                let skipped = try NativeCampaignQueue.skip(stored, customerID: customerID, reason: reason,
                                                           nowISO: Self.campaignTimestamp(date))
                guard commitMarketingRecords(customers: [], campaign: skipped) else { return .failure(.notSaved) }
            } catch {
                return .failure((error as? NativeCampaignError) ?? .notSaved)
            }
        }
        return .success(check)
    }

    /// One composer outcome (spec §7.3), persisted immediately. A `.sent`
    /// that cannot be saved returns `.notSaved`, and the screen says so
    /// instead of presenting the next composer.
    @discardableResult
    func recordCampaignOutcome(
        campaignID: String,
        customerID: String,
        outcome: NativeMessageComposeOutcome,
        autoAdvance: Bool,
        on date: Date = .now
    ) -> Result<NativeCampaignQueue.OutcomeResult, NativeCampaignError> {
        guard let stored = campaign(id: campaignID) else { return .failure(.notFound) }
        let mapped: NativeCampaignQueue.Outcome = switch outcome {
        case .sent: .sent
        case .cancelled: .cancelled
        case .saved: .saved
        case .failed: .failed
        }
        do {
            let result = try NativeCampaignQueue.apply(
                mapped, to: stored, customerID: customerID, autoAdvance: autoAdvance, nowISO: Self.campaignTimestamp(date)
            )
            guard result.campaign != stored else { return .success(result) }
            return commitMarketingRecords(customers: [], campaign: result.campaign) ? .success(result) : .failure(.notSaved)
        } catch {
            return .failure((error as? NativeCampaignError) ?? .notSaved)
        }
    }

    /// "Mark as sent" and the URL-scheme fallback's "Sent" (`manual`).
    @discardableResult
    func markCampaignRecipientSent(campaignID: String, customerID: String, on date: Date = .now)
        -> Result<Canonical.Campaign, NativeCampaignError> {
        mutateCampaign(id: campaignID) {
            try NativeCampaignQueue.markSent($0, customerID: customerID, nowISO: Self.campaignTimestamp(date))
        }
    }

    /// "Skip".
    @discardableResult
    func skipCampaignRecipient(campaignID: String, customerID: String, on date: Date = .now)
        -> Result<Canonical.Campaign, NativeCampaignError> {
        mutateCampaign(id: campaignID) {
            try NativeCampaignQueue.skip($0, customerID: customerID, reason: .owner, nowISO: Self.campaignTimestamp(date))
        }
    }

    /// "They asked to stop": sets the customer's opt-out (O1) and skips them
    /// with `opted_out`, in one commit.
    @discardableResult
    func campaignRecipientAskedToStop(campaignID: String, customerID: String, on date: Date = .now)
        -> Result<Canonical.Campaign, NativeCampaignError> {
        guard let stored = campaign(id: campaignID) else { return .failure(.notFound) }
        guard let customer = canonicalCustomer(id: customerID) else { return .failure(.customerNotFound) }
        do {
            let skipped = try NativeCampaignQueue.skip(stored, customerID: customerID, reason: .optedOut,
                                                       nowISO: Self.campaignTimestamp(date))
            let optedOut = NativeMarketingOptOut.optedOut(customer, on: NativeCashBasis.ymd(date), via: .asked)
            let changed = optedOut.marketingOptOutOn != customer.marketingOptOutOn ? [optedOut] : []
            return commitMarketingRecords(customers: changed, campaign: skipped) ? .success(skipped) : .failure(.notSaved)
        } catch {
            return .failure((error as? NativeCampaignError) ?? .notSaved)
        }
    }

    /// "Retry" on a failed recipient.
    @discardableResult
    func retryCampaignRecipient(campaignID: String, customerID: String) -> Result<Canonical.Campaign, NativeCampaignError> {
        mutateCampaign(id: campaignID) { try NativeCampaignQueue.retry($0, customerID: customerID) }
    }

    /// "End campaign": remaining recipients are skipped as `ended`.
    @discardableResult
    func endCampaign(id: String, on date: Date = .now) -> Result<Canonical.Campaign, NativeCampaignError> {
        mutateCampaign(id: id) { try NativeCampaignQueue.end($0, nowISO: Self.campaignTimestamp(date)) }
    }

    /// "Replied" on a sent recipient's row (owner-marked).
    @discardableResult
    func setCampaignRecipientReplied(
        campaignID: String,
        customerID: String,
        replied: Bool,
        on date: Date = .now
    ) -> Result<Canonical.Campaign, NativeCampaignError> {
        mutateCampaign(id: campaignID) {
            try NativeCampaignQueue.markReplied($0, customerID: customerID, on: replied ? NativeCashBasis.ymd(date) : nil)
        }
    }

    // MARK: - Private

    /// Applies one pure queue operation to the stored campaign and commits it.
    private func mutateCampaign(
        id: String,
        _ change: (Canonical.Campaign) throws -> Canonical.Campaign
    ) -> Result<Canonical.Campaign, NativeCampaignError> {
        guard let stored = campaign(id: id) else { return .failure(.notFound) }
        do {
            let next = try change(stored)
            guard next != stored else { return .success(stored) }
            return commitMarketingRecords(customers: [], campaign: next) ? .success(next) : .failure(.notSaved)
        } catch {
            return .failure((error as? NativeCampaignError) ?? .notSaved)
        }
    }

    /// `cmp_` + a lowercase UUID v4 (row ids are global across accounts).
    static func makeCampaignID(existing: Set<String>) -> String {
        var id = "cmp_" + UUID().uuidString.lowercased()
        while existing.contains(id) { id = "cmp_" + UUID().uuidString.lowercased() }
        return id
    }

    static func campaignTimestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func defaultGoal(for preset: NativeCampaignSegments.Preset) -> NativeCampaignDrafting.Goal {
        switch preset {
        case .dueForMaintenance: .tuneUp
        case .annualCheckIn, .itsBeenAWhile, .everyoneServed: .checkIn
        case .neverBooked: .offer
        case .custom: .custom
        }
    }
}

// MARK: - AI drafting (spec §6.2)

extension AppStore {
    /// Drafts one message kind from the owner's brief. Only Settings' business
    /// name and trade plus the brief reach the provider; never any customer.
    /// Never throws: any failure returns the goal's template with a notice.
    func draftCampaignMessage(
        brief: NativeCampaignDrafting.Brief,
        bookingLinkReady: Bool
    ) async -> NativeCampaignDrafting.Result {
        let request = campaignDraftRequest(brief: brief, bookingLinkReady: bookingLinkReady)
        let reply = try? await sendCampaignDraftRequest(systemPrompt: request.systemPrompt, userMessage: request.userMessage)
        return NativeCampaignDrafting.result(reply: reply, brief: brief)
    }

    /// The exact request `draftCampaignMessage` sends (also what the privacy
    /// test inspects).
    func campaignDraftRequest(
        brief: NativeCampaignDrafting.Brief,
        bookingLinkReady: Bool
    ) -> (systemPrompt: String, userMessage: String) {
        (
            NativeCampaignDrafting.systemPrompt(
                businessName: campaignBusiness.businessName, trade: settings.trade,
                brief: brief, bookingLinkReady: bookingLinkReady
            ),
            NativeCampaignDrafting.userMessage(brief: brief)
        )
    }
}
