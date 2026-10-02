import Foundation

/// Why a quote-options edit was refused. Validation cases follow the limits in
/// docs/superpowers/specs/2026-10-02-quote-options-design.md §2.1.
enum NativeQuoteOptionsError: Error, Equatable {
    /// The job has no `quoteOptions` (a single-total estimate).
    case noOptions
    /// `startOptions` on a job that already has options.
    case alreadyHasOptions
    /// Invariant M3: options are read-only once accepted or once the customer
    /// approved the estimate.
    case readOnly
    case tierNotFound
    case addOnNotFound
    /// A fourth tier (max 3).
    case tierLimitReached
    /// Deleting below two tiers; use `removeOptions(job:keepingTierID:)`.
    case tierMinimumReached
    /// An eleventh add-on (max 10).
    case addOnLimitReached
    /// Tier name empty or longer than 60 characters.
    case invalidTierName
    /// Tier description longer than 300 characters.
    case tierDescriptionTooLong
    /// Add-on label empty or longer than 80 characters.
    case invalidAddOnLabel
    /// Add-on description longer than 200 characters.
    case addOnDescriptionTooLong
    /// Add-on price not > 0, above 1,000,000, or finer than cents.
    case invalidAddOnPrice
    /// Add-on internal cost negative, above 1,000,000, or finer than cents.
    case invalidAddOnCost
}

/// The §3 selection errors. Raw values are the shared fixture's error codes
/// (`native/QuoteOptionsTests/Fixtures/quote-selection-vectors.json`).
enum NativeQuoteSelectionError: String, Error, Equatable {
    case chooseOption = "choose_option"
    case invalidAddOns = "invalid_addons"

    /// The Worker's 400 copy for the same rule.
    var message: String {
        switch self {
        case .chooseOption: "Please choose an option."
        case .invalidAddOns: "Invalid add-on selection."
        }
    }
}

/// Owner-entered add-on fields, validated by `NativeQuoteOptions.validated(_:)`.
struct NativeQuoteAddOnDraft: Equatable {
    var label: String
    var description: String?
    var price: Decimal
    var cost: Decimal?

    init(label: String, description: String? = nil, price: Decimal, cost: Decimal? = nil) {
        self.label = label
        self.description = description
        self.price = price
        self.cost = cost
    }
}

/// Pure good/better/best quote-options domain (Roadmap Phase 25, spec §6.2,
/// §6.3 and §6.4). Every function takes and returns `Canonical.Job` values;
/// persistence, sync and UI wiring live in `AppStore`.
///
/// Invariants (spec §2.1):
/// - M1: before acceptance the job's calculator fields and `estimateTotal`
///   equal the recommended tier's.
/// - M2: after acceptance they equal the accepted tier's, and
///   `estimateTotal = acceptance.total` (tier total + accepted add-ons).
/// - M3: `acceptance` is written once; edits are refused once the options are
///   accepted or the approval is approved (`isReadOnly`).
enum NativeQuoteOptions {
    static let minTiers = 2
    static let maxTiers = 3
    static let maxAddOns = 10
    static let tierNameMaxLength = 60
    static let tierDescriptionMaxLength = 300
    static let addOnLabelMaxLength = 80
    static let addOnDescriptionMaxLength = 200
    static let addOnAmountCeiling: Decimal = 1_000_000
    static let defaultTierNames = ["Good", "Better", "Best"]

    static func newTierID() -> String { "qt_\(UUID().uuidString.lowercased())" }
    static func newAddOnID() -> String { "qa_\(UUID().uuidString.lowercased())" }

    // MARK: - State

    /// M3: no option edits once the options are accepted or the customer's
    /// approval has landed (even before the reconciler applies it).
    static func isReadOnly(_ job: Canonical.Job) -> Bool {
        job.quoteOptions?.acceptance != nil || job.approval?.decision == "approved"
    }

    /// The cheapest tier total, for "from $X" copy. `nil` without options.
    static func lowestTierTotal(_ job: Canonical.Job) -> Decimal? {
        job.quoteOptions?.tiers.map(\.estimateTotal).min()
    }

    // MARK: - Tier editing

    /// Turns a single-total estimate into options: tier 1 ("Good") is the
    /// job's current pricing and stored total, tier 2 ("Better") a duplicate.
    /// Tier 1 is recommended, so the job's own pricing is unchanged (M1).
    static func startOptions(
        job: Canonical.Job,
        makeTierID: () -> String = newTierID
    ) throws -> Canonical.Job {
        guard job.quoteOptions == nil else { throw NativeQuoteOptionsError.alreadyHasOptions }
        guard !isReadOnly(job) else { throw NativeQuoteOptionsError.readOnly }
        let good = Canonical.QuoteTier(id: makeTierID(), name: defaultTierNames[0], pricingOf: job)
        let better = Canonical.QuoteTier(id: makeTierID(), name: defaultTierNames[1], pricingOf: job)
        var result = job
        result.quoteOptions = Canonical.QuoteOptions(
            tiers: [good, better],
            addOns: [],
            recommendedTierId: good.id
        )
        return result
    }

    /// Appends a copy of one tier's pricing (max 3 tiers). The copy gets the
    /// first unused default name — "Best" for the usual third tier — and no
    /// description. The job's own pricing is unchanged.
    static func duplicateTier(
        job: Canonical.Job,
        tierID: String,
        makeTierID: () -> String = newTierID
    ) throws -> Canonical.Job {
        var options = try editableOptions(job)
        guard let source = options.tier(id: tierID) else { throw NativeQuoteOptionsError.tierNotFound }
        guard options.tiers.count < maxTiers else { throw NativeQuoteOptionsError.tierLimitReached }
        options.tiers.append(Canonical.QuoteTier(
            id: makeTierID(),
            name: defaultDuplicateName(options),
            laborHours: source.laborHours,
            laborBreakdown: source.laborBreakdown,
            laborRate: source.laborRate,
            materials: source.materials,
            materialMarkup: source.materialMarkup,
            jobCosts: source.jobCosts,
            overhead: source.overhead,
            margin: source.margin,
            estimateTotal: source.estimateTotal
        ))
        var result = job
        result.quoteOptions = options
        return result
    }

    /// Deletes a tier while at least two remain. Deleting the recommended
    /// tier recommends the first remaining one and mirrors it (M1).
    static func deleteTier(job: Canonical.Job, tierID: String) throws -> Canonical.Job {
        var options = try editableOptions(job)
        guard let index = options.tiers.firstIndex(where: { $0.id == tierID }) else {
            throw NativeQuoteOptionsError.tierNotFound
        }
        guard options.tiers.count > minTiers else { throw NativeQuoteOptionsError.tierMinimumReached }
        options.tiers.remove(at: index)
        var result = job
        if options.recommendedTierId == tierID, let first = options.tiers.first {
            options.recommendedTierId = first.id
            mirrorUnaccepted(first, into: &result)
        }
        result.quoteOptions = options
        return result
    }

    /// "Remove options": the kept tier's pricing and total become the job's
    /// and `quoteOptions` is cleared, back to a single-total estimate.
    static func removeOptions(job: Canonical.Job, keepingTierID: String) throws -> Canonical.Job {
        let options = try editableOptions(job)
        guard let kept = options.tier(id: keepingTierID) else { throw NativeQuoteOptionsError.tierNotFound }
        var result = job
        mirrorUnaccepted(kept, into: &result)
        result.quoteOptions = nil
        return result
    }

    /// Trims and stores a customer-facing tier name (1–60 characters).
    static func renameTier(job: Canonical.Job, tierID: String, name: String) throws -> Canonical.Job {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...tierNameMaxLength).contains(length(trimmed)) else {
            throw NativeQuoteOptionsError.invalidTierName
        }
        return try updatingTier(job: job, tierID: tierID) { $0.name = trimmed }
    }

    /// Trims and stores a tier description (0–300 characters; blank clears it).
    static func describeTier(
        job: Canonical.Job,
        tierID: String,
        description: String?
    ) throws -> Canonical.Job {
        let trimmed = description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard length(trimmed) <= tierDescriptionMaxLength else {
            throw NativeQuoteOptionsError.tierDescriptionTooLong
        }
        return try updatingTier(job: job, tierID: tierID) { $0.description = trimmed.isEmpty ? nil : trimmed }
    }

    /// Recommends a tier and mirrors its pricing and total into the job (M1).
    static func setRecommendedTier(job: Canonical.Job, tierID: String) throws -> Canonical.Job {
        var options = try editableOptions(job)
        guard let tier = options.tier(id: tierID) else { throw NativeQuoteOptionsError.tierNotFound }
        options.recommendedTierId = tierID
        var result = job
        mirrorUnaccepted(tier, into: &result)
        result.quoteOptions = options
        return result
    }

    /// Saves a calculator draft into one tier — see
    /// `CanonicalUIAdapters.canonical(from:tierID:baseline:)`. Mirrors into
    /// the job only when the tier is recommended (before acceptance) or
    /// accepted (after it).
    static func tierPricingSaved(
        job: Canonical.Job,
        tierID: String,
        draft: NativeJobPricingDraft
    ) throws -> Canonical.Job {
        try CanonicalUIAdapters.canonical(from: draft, tierID: tierID, baseline: job)
    }

    // MARK: - Add-ons

    /// Trims and checks owner input against the §2.1 add-on limits.
    static func validated(_ draft: NativeQuoteAddOnDraft) throws -> NativeQuoteAddOnDraft {
        let label = draft.label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...addOnLabelMaxLength).contains(length(label)) else {
            throw NativeQuoteOptionsError.invalidAddOnLabel
        }
        let description = draft.description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard length(description) <= addOnDescriptionMaxLength else {
            throw NativeQuoteOptionsError.addOnDescriptionTooLong
        }
        guard draft.price > 0, draft.price <= addOnAmountCeiling, isWholeCents(draft.price) else {
            throw NativeQuoteOptionsError.invalidAddOnPrice
        }
        if let cost = draft.cost {
            guard cost >= 0, cost <= addOnAmountCeiling, isWholeCents(cost) else {
                throw NativeQuoteOptionsError.invalidAddOnCost
            }
        }
        return NativeQuoteAddOnDraft(
            label: label,
            description: description.isEmpty ? nil : description,
            price: draft.price,
            cost: draft.cost
        )
    }

    static func addAddOn(
        job: Canonical.Job,
        draft: NativeQuoteAddOnDraft,
        makeAddOnID: () -> String = newAddOnID
    ) throws -> Canonical.Job {
        var options = try editableOptions(job)
        let valid = try validated(draft)
        guard options.addOns.count < maxAddOns else { throw NativeQuoteOptionsError.addOnLimitReached }
        options.addOns.append(Canonical.QuoteAddOn(
            id: makeAddOnID(),
            label: valid.label,
            description: valid.description,
            price: valid.price,
            cost: valid.cost
        ))
        var result = job
        result.quoteOptions = options
        return result
    }

    /// Replaces an add-on's owner fields, keeping its id and nested metadata.
    static func editAddOn(
        job: Canonical.Job,
        addOnID: String,
        draft: NativeQuoteAddOnDraft
    ) throws -> Canonical.Job {
        var options = try editableOptions(job)
        guard let index = options.addOns.firstIndex(where: { $0.id == addOnID }) else {
            throw NativeQuoteOptionsError.addOnNotFound
        }
        let valid = try validated(draft)
        options.addOns[index].label = valid.label
        options.addOns[index].description = valid.description
        options.addOns[index].price = valid.price
        options.addOns[index].cost = valid.cost
        var result = job
        result.quoteOptions = options
        return result
    }

    static func deleteAddOn(job: Canonical.Job, addOnID: String) throws -> Canonical.Job {
        var options = try editableOptions(job)
        guard let index = options.addOns.firstIndex(where: { $0.id == addOnID }) else {
            throw NativeQuoteOptionsError.addOnNotFound
        }
        options.addOns.remove(at: index)
        var result = job
        result.quoteOptions = options
        return result
    }

    // MARK: - Snapshot and selection (spec §2.2, §3)

    /// The frozen `snapshot.options` for a job — see
    /// `CanonicalUIAdapters.estimateApprovalSnapshotOptions(job:)`.
    static func snapshotOptions(job: Canonical.Job) throws -> Canonical.EstimateApprovalSnapshot.Options? {
        try CanonicalUIAdapters.estimateApprovalSnapshotOptions(job: job)
    }

    /// §3: `round2(cents(tier.total) + Σ cents(addOn.amount)) / 100`, in
    /// integer cents exactly as the Worker computes it.
    static func selectionTotal(tierTotal: Decimal, addOnAmounts: [Decimal]) -> Decimal {
        FinancialDecimal.integerCentsSum([tierTotal] + addOnAmounts)
    }

    /// §3, the server's `resolveSelection` mirrored for parity: a missing or
    /// unknown tier is `choose_option`; more than ten raw add-on ids (checked
    /// before de-duplication) or any unknown id is `invalid_addons`;
    /// duplicates are dropped and the result follows the snapshot's add-on
    /// order. Lines are the tier's lines then one line per add-on.
    static func resolveSelection(
        snapshotOptions options: Canonical.EstimateApprovalSnapshot.Options,
        tierId: String?,
        addOnIds: [String]
    ) -> Result<Canonical.EstimateSelection, NativeQuoteSelectionError> {
        guard let tierId, let tier = options.tiers.first(where: { $0.id == tierId }) else {
            return .failure(.chooseOption)
        }
        guard addOnIds.count <= maxAddOns else { return .failure(.invalidAddOns) }
        let known = Set(options.addOns.map(\.id))
        guard addOnIds.allSatisfy(known.contains) else { return .failure(.invalidAddOns) }
        let requested = Set(addOnIds)
        let chosen = options.addOns.filter { requested.contains($0.id) }
        let tierLines = tier.lineItems.map {
            Canonical.EstimateApprovalSnapshot.LineItem(label: $0.label, amount: $0.amount)
        }
        let addOnLines = chosen.map {
            Canonical.EstimateApprovalSnapshot.LineItem(label: $0.label, amount: $0.amount)
        }
        return .success(Canonical.EstimateSelection(
            tierId: tier.id,
            tierName: tier.name,
            addOnIds: chosen.map(\.id),
            addOns: chosen.map { .init(id: $0.id, label: $0.label, amount: $0.amount) },
            lineItems: tierLines + addOnLines,
            total: selectionTotal(tierTotal: tier.total, addOnAmounts: chosen.map(\.amount))
        ))
    }

    // MARK: - Acceptance (M2, M3)

    /// Records the accepted choice once (M3: a job that already has an
    /// acceptance is returned unchanged) and applies M2: the accepted tier's
    /// pricing becomes the job's and `estimateTotal = acceptance.total`.
    ///
    /// - `consentedTotal` (a link acceptance passes `approval.selection.total`)
    ///   is the price the customer agreed to and wins over the current tier,
    ///   so a tier edited after sending is absorbed by the residual line. With
    ///   it, an unknown tier keeps the job's pricing as it is and an unknown
    ///   add-on id is still recorded.
    /// - Without it (an owner-recorded choice) the total is the tier total plus
    ///   the add-on prices in integer cents, and the tier and every add-on
    ///   must exist.
    ///
    /// Add-on ids are de-duplicated and put in the job's add-on order (any
    /// unknown ids last, in input order). Status is not changed here.
    static func applyAcceptance(
        job: Canonical.Job,
        tierId: String,
        addOnIds: [String],
        acceptedAt: String,
        source: String,
        consentedTotal: Decimal? = nil
    ) throws -> Canonical.Job {
        guard var options = job.quoteOptions else { throw NativeQuoteOptionsError.noOptions }
        guard options.acceptance == nil else { return job }

        var seen = Set<String>()
        let unique = addOnIds.filter { seen.insert($0).inserted }
        let known = options.addOns.filter { seen.contains($0.id) }
        let knownIDs = Set(known.map(\.id))
        let unknown = unique.filter { !knownIDs.contains($0) }
        let tier = options.tier(id: tierId)

        let total: Decimal
        if let consentedTotal {
            total = consentedTotal
        } else {
            guard let tier else { throw NativeQuoteOptionsError.tierNotFound }
            guard unknown.isEmpty else { throw NativeQuoteOptionsError.addOnNotFound }
            total = FinancialDecimal.integerCentsSum([tier.estimateTotal] + known.map(\.price))
        }

        var result = job
        if let tier { result.applyCalculatorPricing(of: tier) }
        result.estimateTotal = total
        options.acceptance = Canonical.QuoteAcceptance(
            tierId: tierId,
            addOnIds: known.map(\.id) + unknown,
            total: total,
            acceptedAt: acceptedAt,
            source: source
        )
        result.quoteOptions = options
        return result
    }

    // MARK: - Decision reconciler (spec §6.3)

    /// Applies a server-written customer decision to one job, or returns `nil`
    /// when nothing changes (so the caller saves and queues an upsert only for
    /// real changes). Run it on every non-deleted job after each pull.
    ///
    /// - Status moves forward only: from `lead`/`estimate_sent`, approved goes
    ///   to `approved` and declined to `declined`
    ///   (`JobLifecycleRules.statusAfterEstimateDecision`); any other status,
    ///   including an unknown one, is left alone.
    /// - On approval with a server `selection`, quote options and no
    ///   acceptance yet, the selection is applied once as a link acceptance
    ///   with the consented `selection.total` (accepted at `consentAt`).
    static func reconcileEstimateDecision(job: Canonical.Job) -> Canonical.Job? {
        guard let approval = job.approval, let decisionText = approval.decision else { return nil }
        let decision: EstimateDecision
        switch decisionText {
        case "approved": decision = .approved
        case "declined": decision = .declined
        default: return nil
        }

        var result = job
        var changed = false
        if let status = JobLifecycleStatus(rawValue: job.status) {
            let next = JobLifecycleRules.statusAfterEstimateDecision(status, decision: decision)
            if next != status {
                result.status = next.rawValue
                changed = true
            }
        }
        if decision == .approved,
           let selection = approval.selection,
           let options = result.quoteOptions,
           options.acceptance == nil,
           let accepted = try? applyAcceptance(
               job: result,
               tierId: selection.tierId,
               addOnIds: selection.addOnIds,
               // The server stamps consentAt with every decision; sentAt only
               // guards a malformed record.
               acceptedAt: approval.consentAt ?? approval.sentAt,
               source: Canonical.QuoteAcceptance.sourceLink,
               consentedTotal: selection.total
           ) {
            result = accepted
            changed = true
        }
        return changed ? result : nil
    }

    /// Spec §6.3 rebase graft: when a pulled `server` job and a pending
    /// `local` job share the approval token and only the server copy carries a
    /// decision, returns `local` with the server's approval (and its approval
    /// history when longer) so a queued local edit cannot erase a customer's
    /// decision. `nil` when no graft applies. Server-only fields are never
    /// device-authored, so the graft is always safe.
    static func graftingServerDecision(onto local: Canonical.Job, from server: Canonical.Job) -> Canonical.Job? {
        guard local.id == server.id,
              let serverApproval = server.approval,
              serverApproval.decision != nil,
              let localApproval = local.approval,
              localApproval.token == serverApproval.token,
              localApproval.decision == nil
        else { return nil }
        var result = local
        result.approval = serverApproval
        if (server.approvalHistory?.count ?? 0) > (local.approvalHistory?.count ?? 0) {
            result.approvalHistory = server.approvalHistory
        }
        return result
    }

    // MARK: - Consumers (spec §6.4)

    /// One invoice line per accepted add-on, in the job's add-on order. Pass
    /// to `JobInvoiceDomain.computeBillableBreakdown(addOnLines:)`.
    static func invoiceAddOnLines(job: Canonical.Job) -> [JobInvoiceLineDraft] {
        (job.quoteOptions?.acceptedAddOns ?? []).map {
            JobInvoiceLineDraft(description: $0.label, amount: $0.price, category: "other")
        }
    }

    /// Σ the internal `cost` of the accepted add-ons that set one. Already
    /// part of `NativeJobProfitability.input`'s estimated direct cost.
    static func acceptedAddOnCost(job: Canonical.Job) -> Decimal {
        job.quoteOptions?.acceptedAddOnCost ?? 0
    }

    // MARK: - Private

    private static func editableOptions(_ job: Canonical.Job) throws -> Canonical.QuoteOptions {
        guard let options = job.quoteOptions else { throw NativeQuoteOptionsError.noOptions }
        guard !isReadOnly(job) else { throw NativeQuoteOptionsError.readOnly }
        return options
    }

    private static func updatingTier(
        job: Canonical.Job,
        tierID: String,
        _ change: (inout Canonical.QuoteTier) -> Void
    ) throws -> Canonical.Job {
        var options = try editableOptions(job)
        guard let index = options.tiers.firstIndex(where: { $0.id == tierID }) else {
            throw NativeQuoteOptionsError.tierNotFound
        }
        change(&options.tiers[index])
        var result = job
        result.quoteOptions = options
        return result
    }

    /// M1: the job's calculator fields and total become the tier's.
    private static func mirrorUnaccepted(_ tier: Canonical.QuoteTier, into job: inout Canonical.Job) {
        job.applyCalculatorPricing(of: tier)
        job.estimateTotal = tier.estimateTotal
    }

    private static func defaultDuplicateName(_ options: Canonical.QuoteOptions) -> String {
        let used = Set(options.tiers.map { $0.name.lowercased() })
        let start = min(options.tiers.count, defaultTierNames.count)
        let candidates = Array(defaultTierNames[start...]) + Array(defaultTierNames[..<start])
        return candidates.first { !used.contains($0.lowercased()) } ?? "Option \(options.tiers.count + 1)"
    }

    /// Length as JavaScript's `String.length` (UTF-16 code units), the unit the
    /// Worker's snapshot validation counts, so the device never stores a name
    /// the server would reject.
    private static func length(_ text: String) -> Int { text.utf16.count }

    private static func isWholeCents(_ value: Decimal) -> Bool {
        FinancialDecimal.cents(value) == value
    }
}
