import Foundation

/// An editable UI value paired with the canonical record it came from.
/// Keep this value for the lifetime of an edit. Merging compares the edited UI
/// value with the original projection so fields the UI cannot represent remain
/// byte-semantically intact in the canonical record.
struct CanonicalUIEdit<Value, Record> {
    var value: Value
    fileprivate let baseline: Record
    fileprivate let calendar: Calendar

    init(value: Value, baseline: Record, calendar: Calendar = .current) {
        self.value = value
        self.baseline = baseline
        self.calendar = calendar
    }
}

enum CanonicalUIAdapterError: Error, Equatable {
    case invalidDate(field: String, value: String)
    case invalidCanonicalRecord(String)
}

struct NativeJobDuplicateDraft: Identifiable {
    let job: Job
    let canonicalTemplate: Canonical.Job

    var id: String { job.id }
}

struct NativeJobPricingDraft: Identifiable {
    let jobID: String
    var laborHours: Decimal
    var laborBreakdown: Canonical.LaborTimeBreakdown?
    var laborRate: Decimal
    var materials: [Canonical.Material]
    var materialMarkup: Decimal
    var jobCosts: [Canonical.JobCost]
    var overheadPercent: Decimal
    var marginPercent: Decimal
    var travelMiles: Decimal = 0
    var travelFeePerMile: Decimal
    var isEmergency = false
    var emergencyMultiplier: Decimal
    var minimumJobFee: Decimal
    var taxPercent: Decimal = 0

    var id: String { jobID }

    init(job: Canonical.Job, settings: Canonical.Settings?) {
        jobID = job.id
        laborHours = job.laborHours
        laborBreakdown = job.laborBreakdown
        laborRate = job.laborRate == 0 ? (settings?.laborRate ?? 85) : job.laborRate
        materials = job.materials
        materialMarkup = job.materialMarkup
        jobCosts = job.jobCosts ?? []
        overheadPercent = job.overhead
        marginPercent = job.margin
        travelFeePerMile = settings?.travelFeePerMile ?? 0
        emergencyMultiplier = settings?.emergencyMultiplier ?? Decimal(string: "1.5")!
        minimumJobFee = settings?.minimumJobFee ?? 75
    }

    /// Phase 25: a calculator draft for one good/better/best tier of `job`.
    /// Save it with `CanonicalUIAdapters.canonical(from:tierID:baseline:)`;
    /// `jobID` stays the job's so the save can verify its target.
    init(job: Canonical.Job, tier: Canonical.QuoteTier, settings: Canonical.Settings?) {
        jobID = job.id
        laborHours = tier.laborHours
        laborBreakdown = tier.laborBreakdown
        laborRate = tier.laborRate == 0 ? (settings?.laborRate ?? 85) : tier.laborRate
        materials = tier.materials
        materialMarkup = tier.materialMarkup
        jobCosts = tier.jobCosts ?? []
        overheadPercent = tier.overhead
        marginPercent = tier.margin
        travelFeePerMile = settings?.travelFeePerMile ?? 0
        emergencyMultiplier = settings?.emergencyMultiplier ?? Decimal(string: "1.5")!
        minimumJobFee = settings?.minimumJobFee ?? 75
    }

    var input: PricingInput {
        PricingInput(
            laborHours: laborHours,
            laborRate: laborRate,
            materials: materials.map { .init(name: $0.name, quantity: $0.quantity, unitCost: $0.unitCost) },
            materialMarkup: materialMarkup,
            jobCosts: jobCosts.map {
                PricingDirectCost(
                    id: $0.id,
                    label: $0.label,
                    category: PricingCostCategory(rawValue: $0.category) ?? .other,
                    quantity: $0.quantity,
                    unitCost: $0.unitCost,
                    markupPercent: $0.markupPercent,
                    markupPolicy: PricingMarkupPolicy(rawValue: $0.markupPolicy),
                    taxable: $0.taxable,
                    customerVisible: $0.customerVisible
                )
            },
            overheadPercent: overheadPercent,
            marginPercent: marginPercent,
            travelMiles: travelMiles,
            travelFeePerMile: travelFeePerMile,
            isEmergency: isEmergency,
            emergencyMultiplier: emergencyMultiplier,
            minimumJobFee: minimumJobFee,
            taxPercent: taxPercent
        )
    }
}

struct NativeEstimateReviewDraft: Identifiable {
    let jobID: String
    let expectedStatus: JobStatus
    let snapshot: Canonical.EstimateApprovalSnapshot
    let customerEmail: String
    let customerPhone: String
    let customerAddress: String
    let businessContactName: String
    let businessPhone: String
    let businessEmail: String
    let businessAddress: String
    let businessLogoReference: String?
    let jobDescription: String
    /// Phase 21 (spec §3): the job address when it differs from the
    /// customer's, printed as "Service address" under the customer block;
    /// empty otherwise (`NativePropertiesEquipment.serviceAddressLine`).
    var serviceAddress: String = ""

    var id: String { jobID }
}

/// Editable state for `NativeCreateInvoiceFromJobView`, ported from
/// `CreateInvoiceFromJobScreen.tsx`. `mode` fixes which of the three flows
/// (create / requestDeposit / finalize) this draft commits as — see
/// `JobLifecycleRules.invoiceScreenMode`.
struct NativeInvoiceFromJobDraft: Identifiable {
    let jobID: String
    let mode: InvoiceScreenMode
    /// Set only in `finalize` mode: the existing deposit invoice being updated.
    let existingInvoiceID: String?
    var customer: String
    var customerID: String
    var number: String
    var amount: Decimal
    var due: Date
    var email: String
    var phone: String
    var desc: String
    /// True when `amount` bills tracked timer hours instead of the quoted
    /// estimate (create mode only) — switches the tracked-time banner copy.
    let billedFromTracked: Bool
    /// Non-zero only in finalize mode, when approved change orders caused the
    /// amount to be re-derived from the existing deposit invoice's amount.
    let finalizeChangeOrderDelta: Decimal
    /// The job's current billable total, shown in the "pre-filled from job
    /// estimate" banner (create/requestDeposit only; 0 hides the banner).
    let prefillReferenceAmount: Decimal
    /// Phase 34 (spec §5.6): the referral credit owed to this job's customer
    /// when the sheet opened (create/finalize only, and only when the job
    /// produced a line); 0 hides the "Referral credit" section.
    var referralCreditAvailable: Decimal = 0
    /// The credit the owner turned on: 0 or exactly `referralCreditAvailable`
    /// (partial application is not in v1). `amount` already has it
    /// subtracted; commit adds the matching negative line.
    var referralCreditToApply: Decimal = 0

    var id: String { jobID }
}

enum CanonicalUIAdapters {
    /// Creates a complete canonical record for a UI draft that has no baseline.
    /// Existing records must use the `CanonicalUIEdit` overloads so fields the
    /// current UI cannot represent are retained.
    static func canonical(from value: Customer, calendar: Calendar = .current) throws -> Canonical.Customer {
        var fields: [String: Canonical.JSONValue] = [
            "id": .string(value.id), "name": .string(value.name), "email": .string(value.email),
            "phone": .string(value.phone), "address": .string(value.address), "notes": .string(value.notes),
            "createdAt": .string(timestamp(value.createdAt))
        ]
        if let archivedAt = value.archivedAt { fields["archivedAt"] = .string(archivedAt) }
        if let leadSource = value.leadSource { fields["leadSource"] = .string(leadSource) }
        if let referrer = value.referredByCustomerId { fields["referredByCustomerId"] = .string(referrer) }
        return try decode(fields)
    }

    static func canonical(from value: Job, calendar: Calendar = .current) throws -> Canonical.Job {
        var fields: [String: Canonical.JSONValue] = [
            "id": .string(value.id), "customerId": .string(value.customerId),
            "customerName": .string(value.customerName), "title": .string(value.title),
            "description": .string(value.description), "status": .string(value.status.rawValue),
            "address": .string(value.address), "estimateTotal": number(value.estimateTotal),
            "laborHours": number(value.laborHours), "laborRate": number(value.laborRate),
            "materials": .array([]), "materialMarkup": .number(0), "overhead": .number(0),
            "margin": .number(0), "notes": .string(value.notes), "createdAt": .string(timestamp(value.createdAt))
        ]
        if let invoiceId = value.invoiceId { fields["invoiceId"] = .string(invoiceId) }
        if let archivedAt = value.archivedAt { fields["archivedAt"] = .string(archivedAt) }
        if let propertyId = value.propertyId { fields["propertyId"] = .string(propertyId) }
        if let start = value.scheduledAt {
            fields["scheduledDate"] = .string(day(start, calendar: calendar))
            fields["scheduledStartTime"] = .string(time(start, calendar: calendar))
        }
        if let end = value.scheduledEnd { fields["scheduledEndTime"] = .string(time(end, calendar: calendar)) }
        return try decode(fields)
    }

    static func recurringJob(
        from job: Canonical.Job,
        id: String,
        startDate: String,
        cadence: RecurrenceCadence,
        endCondition: RecurrenceEndCondition,
        endCount: Int?,
        endDate: String?,
        createdAt: String
    ) throws -> Canonical.RecurringJob {
        var fields: [String: Canonical.JSONValue] = [
            "id": .string(id), "customerId": .string(job.customerId), "customerName": .string(job.customerName),
            "title": .string(job.title), "description": .string(job.description), "address": .string(job.address),
            "notes": .string(job.notes), "estimateTotal": .number(job.estimateTotal), "laborHours": .number(job.laborHours),
            "laborRate": .number(job.laborRate), "materials": try json(job.materials),
            "materialMarkup": .number(job.materialMarkup), "overhead": .number(job.overhead), "margin": .number(job.margin),
            "cadence": .string(cadence.rawValue), "endCondition": .string(endCondition.rawValue),
            "occurrenceCount": .number(Decimal(1)), "lastGeneratedDate": .string(startDate),
            "nextDueDate": .string(RecurrenceRules.nextDate(after: startDate, cadence: cadence)),
            "isActive": .bool(true), "createdAt": .string(createdAt)
        ]
        if let costs = job.jobCosts { fields["jobCosts"] = try json(costs) }
        // Phase 21: occurrences of the rule are at the source job's property.
        if let propertyId = job.propertyId { fields["propertyId"] = .string(propertyId) }
        if let endCount { fields["endCount"] = .number(Decimal(endCount)) }
        if let endDate { fields["endDate"] = .string(endDate) }
        return try decode(fields)
    }

    /// Builds a new canonical job using the production duplicate whitelist.
    /// Nested materials retain their own preservation metadata, while every
    /// source lifecycle and job-level preservation field starts clean.
    ///
    /// Phase 25: `quoteOptions` is on the whitelist without its `acceptance`
    /// (tiers and add-ons keep their nested metadata; the options container
    /// starts clean). The copy is unaccepted, so invariant M1 re-mirrors the
    /// recommended tier's full pricing into the duplicate's top level.
    ///
    /// Phase 21: `propertyId` is on the whitelist (the copy is at the same
    /// property, beside the same `address`).
    static func duplicateJob(
        _ source: Canonical.Job,
        id: String,
        createdAt: Date,
        calendar: Calendar = .current
    ) throws -> NativeJobDuplicateDraft {
        var fields: [String: Canonical.JSONValue] = [
            "id": .string(id),
            "customerId": .string(source.customerId),
            "customerName": .string(source.customerName),
            "title": .string(source.title),
            "description": .string(source.description),
            "status": .string(JobStatus.lead.rawValue),
            "address": .string(source.address),
            "estimateTotal": .number(source.estimateTotal),
            "laborHours": .number(source.laborHours),
            "laborRate": .number(source.laborRate),
            "materials": try json(source.materials),
            "materialMarkup": .number(source.materialMarkup),
            "overhead": .number(source.overhead),
            "margin": .number(source.margin),
            "notes": .string(source.notes),
            "invoiceId": .null,
            "createdAt": .string(timestamp(createdAt))
        ]
        if let propertyId = source.propertyId { fields["propertyId"] = .string(propertyId) }
        var canonical: Canonical.Job = try decode(fields)
        if let sourceOptions = source.quoteOptions {
            let options = Canonical.QuoteOptions(
                tiers: sourceOptions.tiers,
                addOns: sourceOptions.addOns,
                recommendedTierId: sourceOptions.recommendedTierId
            )
            canonical.quoteOptions = options
            if let recommended = options.tier(id: options.recommendedTierId) {
                canonical.applyCalculatorPricing(of: recommended)
                canonical.estimateTotal = recommended.estimateTotal
            }
        }
        return NativeJobDuplicateDraft(
            job: try job(from: canonical, calendar: calendar),
            canonicalTemplate: canonical
        )
    }

    static func newPricingMaterial(id: String) throws -> Canonical.Material {
        try decode([
            "id": .string(id),
            "name": .string(""),
            "quantity": .number(1),
            "unitCost": .number(0)
        ])
    }

    static func newPricingJobCost(id: String) throws -> Canonical.JobCost {
        try decode([
            "id": .string(id),
            "label": .string(""),
            "category": .string(PricingCostCategory.other.rawValue),
            "quantity": .number(1),
            "unitCost": .number(0),
            "markupPercent": .number(0),
            "markupPolicy": .string(PricingMarkupPolicy.inMarginBase.rawValue),
            "taxable": .bool(false),
            "customerVisible": .bool(true)
        ])
    }

    static func newLaborBreakdown(onSiteHours: Decimal) throws -> Canonical.LaborTimeBreakdown {
        try decode([
            "onSiteHours": .number(onSiteHours),
            "driveHours": .number(0),
            "supplyRunHours": .number(0),
            "setupCleanupHours": .number(0)
        ])
    }

    /// Freezes the exact customer-facing estimate shape used by the approval
    /// service. The stored job total remains authoritative: hidden direct costs,
    /// overhead, and margin stay inside the residual operating-cost line rather
    /// than leaking internal pricing policy into the customer document.
    ///
    /// Phase 25 (good/better/best, spec 2026-10-02 §2.2 and §6.4):
    /// - Options and no acceptance: `options` carries every tier (each tier's
    ///   lines use this same derivation on that tier's pricing) and the add-ons
    ///   (never their internal `cost`). The top-level lines and total are the
    ///   recommended tier's, so old readers see one coherent estimate.
    /// - Accepted: a single estimate of the job's (accepted, M2) pricing plus
    ///   one line per accepted add-on. Add-on prices are subtracted before the
    ///   residual operating-cost line; there is no `options` key.
    /// - Accepted through the link, while the job's total is still the
    ///   consented total: the frozen lines the customer approved
    ///   (`linkApprovedEstimateLines(job:)`), so a tier edited after sending
    ///   never changes the accepted estimate the owner shares.
    ///
    /// Phase 32 (spec 2026-10-03 §2.3, §6.1): `validUntil` (`YYYY-MM-DD`) and
    /// `validUntilTimeZone` (IANA id) are frozen into the snapshot as a term of
    /// the offer. Both present or both absent; exactly one throws
    /// `invalidCanonicalRecord("estimate-validity")`.
    static func estimateApprovalSnapshot(
        job: Canonical.Job,
        customerName: String?,
        businessName: String,
        validUntil: Canonical.DateString? = nil,
        validUntilTimeZone: String? = nil
    ) throws -> Canonical.EstimateApprovalSnapshot {
        guard (validUntil == nil) == (validUntilTimeZone == nil) else {
            throw CanonicalUIAdapterError.invalidCanonicalRecord("estimate-validity")
        }
        var lineItems: [Canonical.JSONValue]
        var total = job.estimateTotal
        var optionsField: [String: Canonical.JSONValue]?

        if let quoteOptions = job.quoteOptions, quoteOptions.acceptance == nil {
            // Validates the §2.1 shape, including that the recommended tier exists.
            optionsField = try snapshotOptionsFields(quoteOptions)
            guard let recommended = quoteOptions.tier(id: quoteOptions.recommendedTierId) else {
                throw CanonicalUIAdapterError.invalidCanonicalRecord("quote-options")
            }
            lineItems = estimateLines(EstimatePricing(recommended), total: recommended.estimateTotal)
                .map(lineJSON)
            total = recommended.estimateTotal
        } else if job.quoteOptions != nil, let approved = linkApprovedEstimateLines(job: job) {
            lineItems = approved.map { lineJSON(($0.label, $0.amount)) }
        } else {
            lineItems = currentPricingLines(job).map(lineJSON)
        }

        var fields: [String: Canonical.JSONValue] = [
            "businessName": .string(businessName.isEmpty ? "Your tradesperson" : businessName),
            "customerName": .string((customerName?.isEmpty == false ? customerName : nil) ?? job.customerName),
            "jobTitle": .string(job.title),
            "lineItems": .array(lineItems),
            "total": .number(total),
            "currency": .string("USD")
        ]
        if let optionsField { fields["options"] = .object(optionsField) }
        if let validUntil, let validUntilTimeZone {
            fields["validUntil"] = .string(validUntil)
            fields["validUntilTimeZone"] = .string(validUntilTimeZone)
        }
        return try decode(fields)
    }

    /// Phase 25 spec §2.2: the frozen `snapshot.options` for a job's quote
    /// options, or `nil` for a single-total estimate. It is built whether or
    /// not the options are accepted (the snapshot builder omits it once they
    /// are). Throws when the options break the §2.1 shape the Worker enforces:
    /// 2–3 tiers with unique ids, ≤10 add-ons with unique ids, and a
    /// recommended tier that exists.
    static func estimateApprovalSnapshotOptions(
        job: Canonical.Job
    ) throws -> Canonical.EstimateApprovalSnapshot.Options? {
        guard let quoteOptions = job.quoteOptions else { return nil }
        return try decode(snapshotOptionsFields(quoteOptions))
    }

    private static func snapshotOptionsFields(
        _ options: Canonical.QuoteOptions
    ) throws -> [String: Canonical.JSONValue] {
        let tierIDs = options.tiers.map(\.id)
        let addOnIDs = options.addOns.map(\.id)
        guard (2...3).contains(options.tiers.count),
              Set(tierIDs).count == tierIDs.count,
              tierIDs.contains(options.recommendedTierId),
              options.addOns.count <= 10,
              Set(addOnIDs).count == addOnIDs.count
        else { throw CanonicalUIAdapterError.invalidCanonicalRecord("quote-options") }

        let tiers: [Canonical.JSONValue] = options.tiers.map { tier in
            var fields: [String: Canonical.JSONValue] = [
                "id": .string(tier.id),
                "name": .string(tier.name),
                "lineItems": .array(
                    estimateLines(EstimatePricing(tier), total: tier.estimateTotal).map(lineJSON)
                ),
                "total": .number(tier.estimateTotal)
            ]
            if let description = tier.description, !description.isEmpty {
                fields["description"] = .string(description)
            }
            return .object(fields)
        }
        // Add-on `cost` is the owner's internal figure: never frozen.
        let addOns: [Canonical.JSONValue] = options.addOns.map { addOn in
            var fields: [String: Canonical.JSONValue] = [
                "id": .string(addOn.id),
                "label": .string(addOn.label),
                "amount": .number(addOn.price)
            ]
            if let description = addOn.description, !description.isEmpty {
                fields["description"] = .string(description)
            }
            return .object(fields)
        }
        return [
            "tiers": .array(tiers),
            "addOns": .array(addOns),
            "recommendedTierId": .string(options.recommendedTierId)
        ]
    }

    /// The calculator-owned inputs the customer line derivation reads, from
    /// either a job or a quote tier (identical field names and types).
    private struct EstimatePricing {
        var laborHours: Decimal
        var laborRate: Decimal
        var materials: [Canonical.Material]
        var materialMarkup: Decimal
        var jobCosts: [Canonical.JobCost]?

        init(_ job: Canonical.Job) {
            laborHours = job.laborHours; laborRate = job.laborRate; materials = job.materials
            materialMarkup = job.materialMarkup; jobCosts = job.jobCosts
        }

        init(_ tier: Canonical.QuoteTier) {
            laborHours = tier.laborHours; laborRate = tier.laborRate; materials = tier.materials
            materialMarkup = tier.materialMarkup; jobCosts = tier.jobCosts
        }
    }

    /// Today's customer line derivation: labor, the material aggregate,
    /// customer-visible direct costs, then a positive residual "Overhead &
    /// operating costs" line. `reservedBeforeResidual` (accepted add-on
    /// prices) is taken out of the residual so the add-ons can be listed as
    /// their own lines without changing the total. Every label is capped at
    /// the Worker's `MAX_LINE_LABEL_CHARS` (`estimateLineLabelMaxLength`).
    private static func estimateLines(
        _ pricing: EstimatePricing,
        total: Decimal,
        reservedBeforeResidual: Decimal = 0
    ) -> [(label: String, amount: Decimal)] {
        let laborCost = pricing.laborHours * pricing.laborRate
        let materialBase = pricing.materials.reduce(Decimal.zero) {
            $0 + $1.quantity * $1.unitCost
        }
        let materialCost = materialBase * (1 + pricing.materialMarkup / 100)
        let visibleDirectCosts = (pricing.jobCosts ?? []).compactMap { cost -> (String, Decimal)? in
            guard cost.customerVisible else { return nil }
            let base = cost.quantity * cost.unitCost
            // React Native treats only the exact known in-margin wire value as
            // marked up. Unknown future policies therefore stay pass-through
            // for this frozen customer view rather than being reinterpreted.
            let amount = cost.markupPolicy == PricingMarkupPolicy.inMarginBase.rawValue
                ? base * (1 + cost.markupPercent / 100)
                : base
            return (estimateDirectCostLabel(cost), FinancialDecimal.cents(amount))
        }

        var lines: [(label: String, amount: Decimal)] = [(
            "Labor (\(estimateNumber(pricing.laborHours)) hrs @ $\(estimateNumber(pricing.laborRate))/hr)",
            laborCost
        )]
        if !pricing.materials.isEmpty {
            let suffix = pricing.materials.count == 1 ? "item" : "items"
            lines.append(("Materials (\(pricing.materials.count) \(suffix))", materialCost))
        }
        lines.append(contentsOf: visibleDirectCosts.map { (label: $0.0, amount: $0.1) })
        let visibleDirectTotal = visibleDirectCosts.reduce(Decimal.zero) { $0 + $1.1 }
        let operatingCost = total - laborCost - materialCost - visibleDirectTotal - reservedBeforeResidual
        if operatingCost > 0 {
            lines.append((estimateOverheadLineLabel, operatingCost))
        }
        return lines.map { (label: cappedEstimateLineLabel($0.label), amount: $0.amount) }
    }

    private static func lineJSON(_ line: (label: String, amount: Decimal)) -> Canonical.JSONValue {
        .object(["label": .string(line.label), "amount": .number(line.amount)])
    }

    /// The customer lines the job's *current* pricing derives, exactly as the
    /// snapshot builder would freeze them when no link acceptance is in force:
    /// the accepted tier plus accepted add-on lines once options are accepted
    /// (M2), otherwise the job's own single-estimate lines. Undecided options
    /// derive the job's lines too (they mirror the recommended tier, M1).
    private static func currentPricingLines(_ job: Canonical.Job) -> [(label: String, amount: Decimal)] {
        guard let quoteOptions = job.quoteOptions, quoteOptions.acceptance != nil else {
            return estimateLines(EstimatePricing(job), total: job.estimateTotal)
        }
        let addOns = quoteOptions.acceptedAddOns
        let reserved = addOns.reduce(Decimal.zero) { $0 + $1.price }
        return estimateLines(EstimatePricing(job), total: job.estimateTotal, reservedBeforeResidual: reserved)
            + addOns.map { (label: $0.label, amount: $0.price) }
    }

    /// The customer lines the job's current pricing derives (see
    /// `currentPricingLines`), as snapshot line items. Phase 25 review fix:
    /// compared with `linkApprovedEstimateLines(job:)` to decide whether the
    /// approved lines still match what the pricing would bill.
    static func currentEstimateLines(job: Canonical.Job) -> [Canonical.EstimateApprovalSnapshot.LineItem] {
        currentPricingLines(job).map { .init(label: $0.label, amount: $0.amount) }
    }

    /// The customer lines a quote tier's pricing derives (its frozen
    /// `snapshot.options` lines). Phase 25 review fix: finds the draft tier
    /// that still prices a single-price estimate exactly as it was sent.
    static func estimateLineItems(for tier: Canonical.QuoteTier) -> [Canonical.EstimateApprovalSnapshot.LineItem] {
        estimateLines(EstimatePricing(tier), total: tier.estimateTotal).map { .init(label: $0.label, amount: $0.amount) }
    }

    /// Phase 25 review fix (spec §12 "Review fixes (2026-10-03)"): the
    /// estimate lines the customer approved through the link, while that
    /// approval is still the job's price — or `nil`.
    ///
    /// - Options: a link acceptance with the server's `selection` for the
    ///   accepted tier, and the job's total still the consented
    ///   `selection.total`. The lines are the accepted tier's frozen
    ///   `snapshot.options` lines (the selection's tier lines when the
    ///   snapshot lacks the tier) followed by one line per selected add-on at
    ///   its frozen amount. An owner-recorded acceptance has no customer
    ///   snapshot and returns `nil` (current pricing applies).
    /// - Single price: an approved snapshot without options on a job without
    ///   options, whose total is still the snapshot total. The lines are the
    ///   snapshot's.
    ///
    /// Once the owner re-prices the job (its total moves off the approved
    /// total) the owner's pricing applies again and this returns `nil`.
    static func linkApprovedEstimateLines(job: Canonical.Job) -> [Canonical.EstimateApprovalSnapshot.LineItem]? {
        guard let approval = job.approval, approval.decision == "approved" else { return nil }
        if let quoteOptions = job.quoteOptions {
            guard let acceptance = quoteOptions.acceptance,
                  acceptance.source == Canonical.QuoteAcceptance.sourceLink,
                  let selection = approval.selection,
                  selection.tierId == acceptance.tierId,
                  job.estimateTotal == selection.total
            else { return nil }
            let tierLines = approval.snapshot.options?.tiers.first(where: { $0.id == selection.tierId })?.lineItems
                ?? Array(selection.lineItems.dropLast(min(selection.addOns.count, selection.lineItems.count)))
            return tierLines.map { .init(label: $0.label, amount: $0.amount) }
                + selection.addOns.map { .init(label: $0.label, amount: $0.amount) }
        }
        guard approval.snapshot.options == nil, job.estimateTotal == approval.snapshot.total else { return nil }
        return approval.snapshot.lineItems.map { .init(label: $0.label, amount: $0.amount) }
    }

    /// The Worker's `MAX_LINE_LABEL_CHARS` for frozen option line labels
    /// (`backend-workers/lib/estimate/quoteOptions.js`), in UTF-16 code units
    /// like JavaScript's `String.length`.
    static let estimateLineLabelMaxLength = 300
    static let estimateOverheadLineLabel = "Overhead & operating costs"

    /// Phase 25 review fix: owner-named direct costs are the only uncapped
    /// line labels; a longer one would make the Worker refuse the whole
    /// options estimate (400 at send). Trims to 299 code units on a
    /// character boundary and appends an ellipsis.
    static func cappedEstimateLineLabel(_ label: String) -> String {
        guard label.utf16.count > estimateLineLabelMaxLength else { return label }
        var capped = ""
        var length = 0
        for character in label {
            let width = String(character).utf16.count
            guard length + width <= estimateLineLabelMaxLength - 1 else { break }
            capped.append(character)
            length += width
        }
        return capped + "\u{2026}"
    }

    /// Mirrors the backend's `planApprovalWrite` semantics. An approved
    /// snapshot is immutable; pending/declined approvals retain additive
    /// metadata while the server-issued token, sent time, and reviewed snapshot
    /// are refreshed.
    static func estimateApprovalAfterLink(
        existing: Canonical.EstimateApproval?,
        snapshot: Canonical.EstimateApprovalSnapshot,
        token: String,
        sentAt: String
    ) throws -> Canonical.EstimateApproval {
        if let existing, existing.decision == "approved" {
            guard existing.token == token else {
                throw CanonicalUIAdapterError.invalidCanonicalRecord("approved-estimate-token")
            }
            return existing
        }
        if var existing {
            existing.token = token
            existing.sentAt = sentAt
            existing.snapshot = snapshot
            return existing
        }
        return try decode([
            "token": .string(token),
            "sentAt": .string(sentAt),
            "snapshot": try json(snapshot)
        ])
    }

    /// Exact equality for the customer-visible approval artifact, including
    /// additive fields preserved from a future writer. Used after the
    /// sync-before-mint round trip so a stale review can never freeze newer
    /// canonical estimate values.
    ///
    /// Phase 32 (spec 2026-10-03 §6.1): `validUntil` and `validUntilTimeZone`
    /// are terms of the offer and compare exactly. `ignoringValidity: true`
    /// compares as if both were absent on both sides: the declined-revision
    /// guard and the extension check use it so a fresh date alone never
    /// counts as a revision (or as a pricing change).
    static func estimateApprovalSnapshotsMatch(
        _ lhs: Canonical.EstimateApprovalSnapshot,
        _ rhs: Canonical.EstimateApprovalSnapshot,
        ignoringValidity: Bool = false
    ) -> Bool {
        if !ignoringValidity {
            guard lhs.validUntil == rhs.validUntil,
                  lhs.validUntilTimeZone == rhs.validUntilTimeZone
            else { return false }
        }
        guard lhs.businessName == rhs.businessName,
              lhs.customerName == rhs.customerName,
              lhs.jobTitle == rhs.jobTitle,
              lhs.total == rhs.total,
              lhs.currency == rhs.currency,
              lhs.preservation == rhs.preservation,
              // Phase 25: tiers, their lines, add-ons and every nested
              // preservation bag compare exactly (synthesized Equatable).
              lhs.options == rhs.options,
              lhs.lineItems.count == rhs.lineItems.count
        else { return false }
        return zip(lhs.lineItems, rhs.lineItems).allSatisfy { left, right in
            left.label == right.label
                && left.amount == right.amount
                && left.preservation == right.preservation
        }
    }

    /// Exact comparison for an archived consent artifact. Revision may move a
    /// declined approval into history, but it may not rewrite any customer or
    /// server-authored field while doing so.
    static func estimateApprovalsMatch(
        _ lhs: Canonical.EstimateApproval,
        _ rhs: Canonical.EstimateApproval
    ) -> Bool {
        lhs.token == rhs.token
            && lhs.sentAt == rhs.sentAt
            && estimateApprovalSnapshotsMatch(lhs.snapshot, rhs.snapshot)
            && lhs.decision == rhs.decision
            && lhs.consentAt == rhs.consentAt
            && lhs.signerName == rhs.signerName
            && lhs.declineReason == rhs.declineReason
            && lhs.ip == rhs.ip
            && lhs.userAgent == rhs.userAgent
            && lhs.selection == rhs.selection
            && lhs.preservation == rhs.preservation
    }

    static func canonicalJobsMatch(_ lhs: Canonical.Job, _ rhs: Canonical.Job) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(lhs)) == (try? encoder.encode(rhs))
    }

    /// Applies only calculator-owned fields to the latest canonical job.
    /// All lifecycle, approval, recurrence, photo, time, archive, import, and
    /// unknown fields remain attached to the current record.
    ///
    /// Phase 25 (invariants M1/M2): on a job with quote options the save also
    /// writes the tier the job mirrors (the recommended tier before
    /// acceptance, the accepted tier after it). After acceptance the job's
    /// `estimateTotal` is the engine total plus the accepted add-on prices.
    static func canonical(
        from pricing: NativeJobPricingDraft,
        baseline: Canonical.Job
    ) throws -> Canonical.Job {
        guard pricing.jobID == baseline.id else {
            throw CanonicalUIAdapterError.invalidCanonicalRecord("job-pricing-id")
        }
        let total = PricingEngine.calculate(pricing.input).total
        var result = baseline
        result.laborHours = pricing.laborHours
        result.laborBreakdown = pricing.laborBreakdown
        result.laborRate = pricing.laborRate
        result.materials = pricing.materials
        result.materialMarkup = pricing.materialMarkup
        result.jobCosts = pricing.jobCosts.isEmpty ? nil : pricing.jobCosts
        result.overhead = pricing.overheadPercent
        result.margin = pricing.marginPercent
        result.estimateTotal = total
        if var options = baseline.quoteOptions {
            if let index = options.tiers.firstIndex(where: { $0.id == options.mirroredTierId }) {
                apply(pricing, total: total, to: &options.tiers[index])
            }
            result.quoteOptions = options
            result.estimateTotal = quoteMirroredJobTotal(tierTotal: total, options: options)
        }
        return result
    }

    /// Phase 25: saves a calculator draft into one quote tier. The tier gets
    /// the draft's calculator fields and `estimateTotal = engine total`. The
    /// job's top-level pricing changes only when this tier is the one the job
    /// mirrors (recommended before acceptance, accepted after it), and then
    /// exactly as `canonical(from:baseline:)` would write it.
    static func canonical(
        from pricing: NativeJobPricingDraft,
        tierID: String,
        baseline: Canonical.Job
    ) throws -> Canonical.Job {
        guard pricing.jobID == baseline.id else {
            throw CanonicalUIAdapterError.invalidCanonicalRecord("job-pricing-id")
        }
        guard var options = baseline.quoteOptions,
              let index = options.tiers.firstIndex(where: { $0.id == tierID })
        else { throw CanonicalUIAdapterError.invalidCanonicalRecord("quote-tier-id") }
        let total = PricingEngine.calculate(pricing.input).total
        apply(pricing, total: total, to: &options.tiers[index])
        var result = baseline
        result.quoteOptions = options
        if tierID == options.mirroredTierId {
            result.applyCalculatorPricing(of: options.tiers[index])
            result.estimateTotal = quoteMirroredJobTotal(tierTotal: total, options: options)
        }
        return result
    }

    /// Phase 25: the job `estimateTotal` for a mirrored tier total. Before
    /// acceptance it is the tier total (M1); after it, the tier total plus
    /// the accepted add-on prices in integer cents (M2, spec §3).
    static func quoteMirroredJobTotal(
        tierTotal: Decimal,
        options: Canonical.QuoteOptions
    ) -> Decimal {
        guard options.acceptance != nil else { return tierTotal }
        return FinancialDecimal.integerCentsSum([tierTotal] + options.acceptedAddOns.map(\.price))
    }

    /// Phase 25 review fix: the job carries good/better/best options with no
    /// acceptance yet, so its top-level price mirrors the recommended tier
    /// (M1) and is owned by the options sheet, not the job editor.
    static func hasUndecidedQuoteOptions(_ job: Canonical.Job) -> Bool {
        job.quoteOptions != nil && job.quoteOptions?.acceptance == nil
    }

    private static func apply(
        _ pricing: NativeJobPricingDraft,
        total: Decimal,
        to tier: inout Canonical.QuoteTier
    ) {
        tier.laborHours = pricing.laborHours
        tier.laborBreakdown = pricing.laborBreakdown
        tier.laborRate = pricing.laborRate
        tier.materials = pricing.materials
        tier.materialMarkup = pricing.materialMarkup
        tier.jobCosts = pricing.jobCosts.isEmpty ? nil : pricing.jobCosts
        tier.overhead = pricing.overheadPercent
        tier.margin = pricing.marginPercent
        tier.estimateTotal = total
    }

    private static func estimateNumber(_ value: Decimal) -> String {
        NSDecimalNumber(decimal: value).stringValue
    }

    /// Not `private`: also used by `JobInvoiceDomain`'s line-item builder, so
    /// an invoice's direct-cost labels match the estimate review's exactly.
    /// Phase 25 review fix: an owner label longer than the Worker's line-label
    /// cap is shortened here, so the estimate and the invoice still agree.
    static func estimateDirectCostLabel(_ cost: Canonical.JobCost) -> String {
        let ownLabel = cost.label.trimmingCharacters(in: .whitespacesAndNewlines)
        if !ownLabel.isEmpty { return cappedEstimateLineLabel(ownLabel) }
        switch cost.category {
        case PricingCostCategory.permit.rawValue: return "Permit"
        case PricingCostCategory.disposal.rawValue: return "Disposal"
        case PricingCostCategory.rental.rawValue: return "Equipment rental"
        case PricingCostCategory.subcontractor.rawValue: return "Subcontractor"
        case PricingCostCategory.delivery.rawValue: return "Delivery"
        case PricingCostCategory.travel.rawValue: return "Travel"
        case PricingCostCategory.other.rawValue: return "Other cost"
        default: return "Cost"
        }
    }

    static func canonical(from value: Invoice, calendar: Calendar = .current) throws -> Canonical.Invoice {
        var fields: [String: Canonical.JSONValue] = [
            "id": .string(value.id), "customer": .string(value.customer), "number": .string(value.number),
            "amount": number(value.amount), "due": .string(day(value.due, calendar: calendar)),
            "email": .string(value.email), "phone": .string(value.phone), "desc": .string(value.description),
            "paid": .bool(value.isPaid), "payments": try json(value.payments.map { try newCanonicalPayment($0, calendar: calendar) })
        ]
        if !value.customerId.isEmpty { fields["customerId"] = .string(value.customerId) }
        if value.legacyPaid {
            fields["paidAt"] = .string(timestamp(value.legacyPaidAt ?? value.due))
        }
        return try decode(fields)
    }

    /// Builds fresh canonical line items for an invoice created or finalized
    /// from a job — see `JobInvoiceDomain.buildInvoiceLineItems`.
    static func invoiceLineItems(from drafts: [JobInvoiceLineDraft]) throws -> [Canonical.InvoiceLineItem] {
        try drafts.map { draft in
            try decode([
                "description": .string(draft.description),
                "amount": .number(draft.amount),
                "category": .string(draft.category)
            ])
        }
    }

    static func canonical(from value: Expense, calendar: Calendar = .current) throws -> Canonical.Expense {
        var fields: [String: Canonical.JSONValue] = [
            "id": .string(value.id), "createdAt": .string(timestamp(.now)),
            "description": .string(value.merchant), "amount": number(value.amount),
            "category": .string(value.category.rawValue), "date": .string(day(value.date, calendar: calendar)),
            "notes": .string(value.notes)
        ]
        // Absent stays absent: an unlinked expense must not carry an explicit
        // null job/receipt, matching the RN record shape.
        if let receiptUri = value.receiptUri { fields["receiptUri"] = .string(receiptUri) }
        if let jobId = value.jobId { fields["jobId"] = .string(jobId) }
        if let importBatchId = value.importBatchId { fields["importBatchId"] = .string(importBatchId) }
        return try decode(fields)
    }

    static func canonical(from value: BusinessSettings) throws -> Canonical.Settings {
        let fields: [String: Canonical.JSONValue] = [
            "businessName": .string(value.businessName), "contactName": .string(value.contactName),
            "phone": .string(value.phone), "email": .string(value.email), "address": .string(value.address),
            "region": value.region.isEmpty ? .null : .string(value.region),
            "logoPhoto": value.logoPhoto.isEmpty ? .null : .string(value.logoPhoto), "trade": .string(value.trade),
            "laborRate": number(value.laborRate), "laborCostRate": number(value.ownerLaborCostRate),
            "materialMarkup": number(value.materialMarkup), "overheadPercent": number(value.overheadPercent),
            "marginPercent": number(value.marginPercent), "minimumJobFee": number(value.minimumJobFee),
            "travelFeePerMile": .number(0), "emergencyMultiplier": number(value.emergencyMultiplier),
            "mileageRate": number(value.mileageRate),
            "schedule": .object([
                "workDays": .array(value.workDays.sorted().map { .number(Decimal($0)) }),
                "workDayStart": .string(hour(value.workDayStart)), "workDayEnd": .string(hour(value.workDayEnd)),
                "defaultDurationMinutes": .number(Decimal(value.appointmentMinutes)),
                "bufferMinutes": .number(Decimal(value.bufferMinutes)),
                "bookableSlotsEnabled": .bool(value.bookableSlotsEnabled)
            ]),
            "invoicePrefix": .string(value.invoicePrefix), "invoiceStartNumber": .number(Decimal(value.invoiceStart)),
            "paymentNotes": .string(value.paymentNotes), "provider": .string(value.paymentProvider),
            "providerKey": .string(value.paymentProviderKey),
            "providerKeys": .object(Dictionary(uniqueKeysWithValues: value.paymentProviderKeys.map { ($0.key, .string($0.value)) })),
            "rules": .array([]),
            "autoOutreachEnabled": .bool(value.autoOutreachEnabled),
            "autoSendEmailEnabled": .bool(value.autoSendEmailEnabled),
            "appointmentRemindersEnabled": .bool(value.appointmentRemindersEnabled),
            "appointmentConfirmTemplate": .string(value.appointmentConfirmTemplate),
            "onMyWayTemplate": .string(value.onMyWayTemplate),
            "estimateFollowUpsEnabled": .bool(value.estimateFollowUpsEnabled),
            "autoInvoiceOnComplete": .bool(value.autoInvoiceOnComplete),
            "autoSendRecurringInvoicesEnabled": .bool(value.autoSendRecurringInvoicesEnabled),
            "autoEmailInvoiceOnComplete": .bool(false), "anthropicKey": .string(""), "groqKey": .string(""),
            "reviewRequestEnabled": .bool(value.reviewRequestEnabled),
            "reviewRequestTemplate": .string(value.reviewRequestTemplate),
            "googleReviewLink": .string(value.googleReviewLink),
            "reviewRequestDelayHours": .number(Decimal(value.reviewRequestDelayHours)),
            "estimateValidityDays": .number(Decimal(value.estimateValidityDays)),
            // Native-only preferences stay inside the canonical record's
            // preservation bag instead of a second persisted model.
            "appearance": .string(value.appearance.rawValue),
            "bookingEnabled": .bool(value.bookingEnabled)
        ]
        var complete = fields
        if let rate = value.taxIncomeRate { complete["taxIncomeRate"] = number(rate) }
        if let method = value.vehicleDeductionMethod, !method.isEmpty {
            complete["vehicleDeductionMethod"] = .string(method)
        }
        return try decode(complete)
    }

    static func edit(_ value: Canonical.Customer, calendar: Calendar = .current) throws -> CanonicalUIEdit<Customer, Canonical.Customer> {
        .init(value: try customer(from: value, calendar: calendar), baseline: value, calendar: calendar)
    }

    static func edit(_ value: Canonical.Job, calendar: Calendar = .current) throws -> CanonicalUIEdit<Job, Canonical.Job> {
        .init(value: try job(from: value, calendar: calendar), baseline: value, calendar: calendar)
    }

    static func edit(_ value: Canonical.Payment, calendar: Calendar = .current) throws -> CanonicalUIEdit<Payment, Canonical.Payment> {
        .init(value: try payment(from: value, calendar: calendar), baseline: value, calendar: calendar)
    }

    static func edit(_ value: Canonical.Invoice, calendar: Calendar = .current) throws -> CanonicalUIEdit<Invoice, Canonical.Invoice> {
        .init(value: try invoice(from: value, calendar: calendar), baseline: value, calendar: calendar)
    }

    static func edit(_ value: Canonical.Expense, calendar: Calendar = .current) throws -> CanonicalUIEdit<Expense, Canonical.Expense> {
        .init(value: try expense(from: value, calendar: calendar), baseline: value, calendar: calendar)
    }

    static func edit(_ value: Canonical.Settings) throws -> CanonicalUIEdit<BusinessSettings, Canonical.Settings> {
        .init(value: settings(from: value), baseline: value)
    }

    static func canonical(from edit: CanonicalUIEdit<Customer, Canonical.Customer>) throws -> Canonical.Customer {
        var fields = try object(edit.baseline)
        let original = try customer(from: edit.baseline, calendar: edit.calendar)
        update(&fields, "id", edit.value.id, original.id)
        update(&fields, "name", edit.value.name, original.name)
        update(&fields, "email", edit.value.email, original.email)
        update(&fields, "phone", edit.value.phone, original.phone)
        update(&fields, "address", edit.value.address, original.address)
        update(&fields, "notes", edit.value.notes, original.notes)
        if edit.value.createdAt != original.createdAt { fields["createdAt"] = .string(timestamp(edit.value.createdAt)) }
        updateOptional(&fields, "archivedAt", edit.value.archivedAt, original.archivedAt)
        updateOptional(&fields, "leadSource", edit.value.leadSource, original.leadSource)
        updateOptional(&fields, "referredByCustomerId", edit.value.referredByCustomerId, original.referredByCustomerId)
        return try decode(fields)
    }

    static func canonical(from edit: CanonicalUIEdit<Job, Canonical.Job>) throws -> Canonical.Job {
        var fields = try object(edit.baseline)
        let original = try job(from: edit.baseline, calendar: edit.calendar)
        update(&fields, "id", edit.value.id, original.id)
        update(&fields, "customerId", edit.value.customerId, original.customerId)
        update(&fields, "customerName", edit.value.customerName, original.customerName)
        update(&fields, "title", edit.value.title, original.title)
        update(&fields, "description", edit.value.description, original.description)
        if edit.value.status != original.status { fields["status"] = .string(edit.value.status.rawValue) }
        update(&fields, "address", edit.value.address, original.address)
        // Phase 25 review fix (invariant M1): while good/better/best options
        // are undecided the job's price is the recommended tier's, edited
        // only through the options sheet or the calculator (which writes the
        // tier too). A job-editor or other UI-model save keeps the baseline's
        // pricing, so a stale or hand-typed total can never drift from the
        // tier the customer is sent.
        if !hasUndecidedQuoteOptions(edit.baseline) {
            updateNumber(&fields, "estimateTotal", edit.value.estimateTotal, original.estimateTotal)
            updateNumber(&fields, "laborHours", edit.value.laborHours, original.laborHours)
            updateNumber(&fields, "laborRate", edit.value.laborRate, original.laborRate)
        }
        update(&fields, "notes", edit.value.notes, original.notes)
        updateOptional(&fields, "invoiceId", edit.value.invoiceId, original.invoiceId)
        updateOptional(&fields, "archivedAt", edit.value.archivedAt, original.archivedAt)
        updateOptional(&fields, "propertyId", edit.value.propertyId, original.propertyId)
        if edit.value.createdAt != original.createdAt { fields["createdAt"] = .string(timestamp(edit.value.createdAt)) }
        if edit.value.scheduledAt != original.scheduledAt || edit.value.scheduledEnd != original.scheduledEnd {
            if let start = edit.value.scheduledAt {
                fields["scheduledDate"] = .string(day(start, calendar: edit.calendar))
                fields["scheduledStartTime"] = .string(time(start, calendar: edit.calendar))
            } else {
                fields.removeValue(forKey: "scheduledDate")
                fields.removeValue(forKey: "scheduledStartTime")
            }
            if let end = edit.value.scheduledEnd { fields["scheduledEndTime"] = .string(time(end, calendar: edit.calendar)) }
            else { fields.removeValue(forKey: "scheduledEndTime") }
        }
        return try decode(fields)
    }

    static func canonical(from edit: CanonicalUIEdit<Payment, Canonical.Payment>) throws -> Canonical.Payment {
        try merge(payment: edit.value, baseline: edit.baseline, calendar: edit.calendar)
    }

    static func canonical(from edit: CanonicalUIEdit<Invoice, Canonical.Invoice>) throws -> Canonical.Invoice {
        var fields = try object(edit.baseline)
        let original = try invoice(from: edit.baseline, calendar: edit.calendar)
        update(&fields, "id", edit.value.id, original.id)
        updateOptional(&fields, "customerId", optional(edit.value.customerId), optional(original.customerId))
        update(&fields, "customer", edit.value.customer, original.customer)
        update(&fields, "number", edit.value.number, original.number)
        updateNumber(&fields, "amount", edit.value.amount, original.amount)
        if edit.value.due != original.due { fields["due"] = .string(day(edit.value.due, calendar: edit.calendar)) }
        update(&fields, "email", edit.value.email, original.email)
        update(&fields, "phone", edit.value.phone, original.phone)
        update(&fields, "desc", edit.value.description, original.description)

        if edit.value.payments != original.payments {
            let baselines = Dictionary(uniqueKeysWithValues: (edit.baseline.payments ?? []).map { ($0.id, $0) })
            let merged = try edit.value.payments.map { payment -> Canonical.Payment in
                if let baseline = baselines[payment.id] { return try merge(payment: payment, baseline: baseline, calendar: edit.calendar) }
                return try newCanonicalPayment(payment, calendar: edit.calendar)
            }
            fields["payments"] = try json(merged)
            fields["paid"] = .bool(edit.value.isPaid)
            let ledger = PaymentLedger.reconcilePaidFields(edit.value.workflowLedger)
            if let paidAt = ledger.paidAt { fields["paidAt"] = .string(paidAt) }
            else { fields.removeValue(forKey: "paidAt") }
        }
        return try decode(fields)
    }

    static func canonical(from edit: CanonicalUIEdit<Expense, Canonical.Expense>) throws -> Canonical.Expense {
        var fields = try object(edit.baseline)
        let original = try expense(from: edit.baseline, calendar: edit.calendar)
        update(&fields, "id", edit.value.id, original.id)
        update(&fields, "description", edit.value.merchant, original.merchant)
        updateNumber(&fields, "amount", edit.value.amount, original.amount)
        if edit.value.date != original.date { fields["date"] = .string(day(edit.value.date, calendar: edit.calendar)) }
        if edit.value.category != original.category { fields["category"] = .string(edit.value.category.rawValue) }
        update(&fields, "notes", edit.value.notes, original.notes)
        updateOptional(&fields, "receiptUri", edit.value.receiptUri, original.receiptUri)
        updateOptional(&fields, "jobId", edit.value.jobId, original.jobId)
        // `importBatchId` is import provenance, not an editor-owned field: it
        // stays on the baseline record so a manual edit can neither forge nor
        // drop it.
        return try decode(fields)
    }

    static func canonical(from edit: CanonicalUIEdit<BusinessSettings, Canonical.Settings>) throws -> Canonical.Settings {
        var fields = try object(edit.baseline)
        let original = settings(from: edit.baseline)
        update(&fields, "businessName", edit.value.businessName, original.businessName)
        update(&fields, "contactName", edit.value.contactName, original.contactName)
        update(&fields, "phone", edit.value.phone, original.phone)
        update(&fields, "email", edit.value.email, original.email)
        update(&fields, "address", edit.value.address, original.address)
        updateOptional(&fields, "region", optional(edit.value.region), optional(original.region))
        updateOptional(&fields, "logoPhoto", optional(edit.value.logoPhoto), optional(original.logoPhoto))
        update(&fields, "trade", edit.value.trade, original.trade)
        update(&fields, "paymentNotes", edit.value.paymentNotes, original.paymentNotes)
        update(&fields, "provider", edit.value.paymentProvider, original.paymentProvider)
        update(&fields, "providerKey", edit.value.paymentProviderKey, original.paymentProviderKey)
        if edit.value.paymentProviderKeys != original.paymentProviderKeys {
            fields["providerKeys"] = .object(Dictionary(uniqueKeysWithValues: edit.value.paymentProviderKeys.map { ($0.key, .string($0.value)) }))
        }
        updateNumber(&fields, "laborRate", edit.value.laborRate, original.laborRate)
        updateNumber(&fields, "materialMarkup", edit.value.materialMarkup, original.materialMarkup)
        updateNumber(&fields, "overheadPercent", edit.value.overheadPercent, original.overheadPercent)
        updateNumber(&fields, "marginPercent", edit.value.marginPercent, original.marginPercent)
        updateNumber(&fields, "minimumJobFee", edit.value.minimumJobFee, original.minimumJobFee)
        updateNumber(&fields, "emergencyMultiplier", edit.value.emergencyMultiplier, original.emergencyMultiplier)
        updateNumber(&fields, "mileageRate", edit.value.mileageRate, original.mileageRate)
        updateNumber(&fields, "laborCostRate", edit.value.ownerLaborCostRate, original.ownerLaborCostRate)
        // Tax set-aside settings (task 9.08). Absent stays absent: an unset rate
        // or vehicle election removes the key rather than writing a null.
        updateOptionalNumber(&fields, "taxIncomeRate", edit.value.taxIncomeRate, original.taxIncomeRate)
        updateOptional(
            &fields, "vehicleDeductionMethod",
            optional(edit.value.vehicleDeductionMethod ?? ""),
            optional(original.vehicleDeductionMethod ?? "")
        )
        updateOptional(&fields, "invoicePrefix", optional(edit.value.invoicePrefix), optional(original.invoicePrefix))
        if edit.value.invoiceStart != original.invoiceStart { fields["invoiceStartNumber"] = .number(Decimal(edit.value.invoiceStart)) }
        updateBool(&fields, "autoOutreachEnabled", edit.value.autoOutreachEnabled, original.autoOutreachEnabled)
        updateBool(&fields, "autoSendEmailEnabled", edit.value.autoSendEmailEnabled, original.autoSendEmailEnabled)
        updateBool(&fields, "appointmentRemindersEnabled", edit.value.appointmentRemindersEnabled, original.appointmentRemindersEnabled)
        update(&fields, "appointmentConfirmTemplate", edit.value.appointmentConfirmTemplate, original.appointmentConfirmTemplate)
        update(&fields, "onMyWayTemplate", edit.value.onMyWayTemplate, original.onMyWayTemplate)
        updateBool(&fields, "estimateFollowUpsEnabled", edit.value.estimateFollowUpsEnabled, original.estimateFollowUpsEnabled)
        updateBool(&fields, "autoInvoiceOnComplete", edit.value.autoInvoiceOnComplete, original.autoInvoiceOnComplete)
        updateBool(&fields, "autoSendRecurringInvoicesEnabled", edit.value.autoSendRecurringInvoicesEnabled, original.autoSendRecurringInvoicesEnabled)
        updateBool(&fields, "reviewRequestEnabled", edit.value.reviewRequestEnabled, original.reviewRequestEnabled)
        update(&fields, "googleReviewLink", edit.value.googleReviewLink, original.googleReviewLink)
        update(&fields, "reviewRequestTemplate", edit.value.reviewRequestTemplate, original.reviewRequestTemplate)
        if edit.value.reviewRequestDelayHours != original.reviewRequestDelayHours { fields["reviewRequestDelayHours"] = .number(Decimal(edit.value.reviewRequestDelayHours)) }
        // Phase 32: absent reads as 30, so an untouched default never writes the key.
        if edit.value.estimateValidityDays != original.estimateValidityDays { fields["estimateValidityDays"] = .number(Decimal(edit.value.estimateValidityDays)) }
        if edit.value.appearance != original.appearance { fields["appearance"] = .string(edit.value.appearance.rawValue) }
        if edit.value.bookingEnabled != original.bookingEnabled { fields["bookingEnabled"] = .bool(edit.value.bookingEnabled) }

        if scheduleFieldsChanged(edit.value, original) {
            var schedule = (try? object(edit.baseline.schedule)) ?? [:]
            schedule["workDays"] = .array(edit.value.workDays.sorted().map { .number(Decimal($0)) })
            schedule["workDayStart"] = .string(hour(edit.value.workDayStart))
            schedule["workDayEnd"] = .string(hour(edit.value.workDayEnd))
            schedule["defaultDurationMinutes"] = .number(Decimal(edit.value.appointmentMinutes))
            schedule["bufferMinutes"] = .number(Decimal(edit.value.bufferMinutes))
            schedule["bookableSlotsEnabled"] = .bool(edit.value.bookableSlotsEnabled)
            fields["schedule"] = .object(schedule)
        }
        // `bookingEnabled` is intentionally UI-only at this boundary. A valid
        // canonical BookingLink requires a backend-minted token; adapters must
        // preserve an existing link and never fabricate credentials.
        return try decode(fields)
    }

    static func customer(from value: Canonical.Customer, calendar: Calendar = .current) throws -> Customer {
        Customer(id: value.id, name: value.name, email: value.email, phone: value.phone,
                 address: value.address, notes: value.notes,
                 createdAt: try parsed(value.createdAt ?? "1970-01-01", field: "customer.createdAt", calendar: calendar),
                 archivedAt: value.archivedAt, leadSource: value.leadSource,
                 referredByCustomerId: value.referredByCustomerId)
    }

    static func job(from value: Canonical.Job, calendar: Calendar = .current) throws -> Job {
        let start = try scheduledDate(value.scheduledDate, time: value.scheduledStartTime, field: "job.scheduledStart", calendar: calendar)
        let end = try scheduledDate(value.scheduledDate, time: value.scheduledEndTime, field: "job.scheduledEnd", calendar: calendar)
        return Job(id: value.id, customerId: value.customerId, customerName: value.customerName,
                   title: value.title, description: value.description,
                   status: JobStatus(rawValue: value.status) ?? .lead,
                   scheduledAt: start, scheduledEnd: end, address: value.address,
                   estimateTotal: double(value.estimateTotal), laborHours: double(value.laborHours),
                   laborRate: double(value.laborRate), notes: value.notes, invoiceId: value.invoiceId,
                   createdAt: try parsed(value.createdAt, field: "job.createdAt", calendar: calendar),
                   archivedAt: value.archivedAt, propertyId: value.propertyId)
    }

    static func payment(from value: Canonical.Payment, calendar: Calendar = .current) throws -> Payment {
        Payment(id: value.id, amount: double(value.amount), date: try parsed(value.date, field: "payment.date", calendar: calendar),
                method: displayPaymentMethod(value.method), note: value.note ?? "",
                voidedAt: try value.voidedAt.map { try parsed($0, field: "payment.voidedAt", calendar: calendar) })
    }

    static func invoice(from value: Canonical.Invoice, calendar: Calendar = .current) throws -> Invoice {
        let legacyPaid = value.paid && (value.payments?.isEmpty ?? true)
        let legacyPaidAt = try legacyPaid
            ? parsed(value.paidAt ?? value.due, field: "invoice.paidAt", calendar: calendar)
            : nil
        return Invoice(id: value.id, customerId: value.customerId ?? "", customer: value.customer,
                number: value.number, amount: double(value.amount), due: try parsed(value.due, field: "invoice.due", calendar: calendar),
                email: value.email, phone: value.phone, description: value.desc,
                payments: try (value.payments ?? []).map { try payment(from: $0, calendar: calendar) },
                legacyPaid: legacyPaid, legacyPaidAt: legacyPaidAt)
    }

    static func expense(from value: Canonical.Expense, calendar: Calendar = .current) throws -> Expense {
        var expense = Expense(id: value.id, merchant: value.description, amount: double(value.amount),
                              date: try parsed(value.date, field: "expense.date", calendar: calendar),
                              category: ExpenseCategory(rawValue: value.category) ?? .other, notes: value.notes)
        expense.jobId = value.jobId
        expense.receiptUri = value.receiptUri
        expense.importBatchId = value.importBatchId
        return expense
    }

    static func settings(from value: Canonical.Settings) -> BusinessSettings {
        var result = BusinessSettings(businessName: value.businessName, contactName: value.contactName,
                                      phone: value.phone, email: value.email, address: value.address,
                                      region: value.region ?? "", trade: value.trade)
        result.logoPhoto = value.logoPhoto ?? ""
        result.paymentNotes = value.paymentNotes
        result.paymentProvider = value.provider
        result.paymentProviderKey = value.providerKey
        result.paymentProviderKeys = value.providerKeys
        // React Native legacy backfill: a non-Stripe providerKey predating
        // per-provider keys is adopted into its provider entry.
        if value.provider != "stripe", !value.providerKey.isEmpty,
           result.paymentProviderKeys[value.provider] == nil {
            result.paymentProviderKeys[value.provider] = value.providerKey
        }
        result.laborRate = double(value.laborRate); result.materialMarkup = double(value.materialMarkup)
        result.overheadPercent = double(value.overheadPercent); result.marginPercent = double(value.marginPercent)
        result.minimumJobFee = double(value.minimumJobFee); result.emergencyMultiplier = double(value.emergencyMultiplier)
        result.mileageRate = double(value.mileageRate); result.ownerLaborCostRate = double(value.laborCostRate ?? 0)
        // Tax set-aside settings: absent stays absent (never coerced to 0/"").
        result.taxIncomeRate = value.taxIncomeRate.map(double)
        result.vehicleDeductionMethod = value.vehicleDeductionMethod
        result.invoicePrefix = value.invoicePrefix ?? "INV-"; result.invoiceStart = value.invoiceStartNumber ?? 1
        result.autoOutreachEnabled = value.autoOutreachEnabled; result.autoSendEmailEnabled = value.autoSendEmailEnabled
        result.appointmentRemindersEnabled = value.appointmentRemindersEnabled
        result.appointmentConfirmTemplate = value.appointmentConfirmTemplate
        result.onMyWayTemplate = value.onMyWayTemplate
        result.estimateFollowUpsEnabled = value.estimateFollowUpsEnabled
        result.autoInvoiceOnComplete = value.autoInvoiceOnComplete
        result.autoSendRecurringInvoicesEnabled = value.autoSendRecurringInvoicesEnabled ?? false
        result.bookingEnabled = value.bookingLink?.enabled ?? false
        result.bookableSlotsEnabled = value.schedule?.bookableSlotsEnabled ?? false
        result.reviewRequestEnabled = value.reviewRequestEnabled; result.googleReviewLink = value.googleReviewLink
        result.reviewRequestDelayHours = value.reviewRequestDelayHours; result.reviewRequestTemplate = value.reviewRequestTemplate
        // Phase 32: absent = 30; a malformed stored value is clamped into 0…365.
        result.estimateValidityDays = min(max(value.estimateValidityDays ?? 30, 0), 365)
        if case let .string(raw)? = value.preservation.unknownFields["appearance"] {
            result.appearance = Appearance(rawValue: raw) ?? .system
        }
        if case let .bool(enabled)? = value.preservation.unknownFields["bookingEnabled"] {
            result.bookingEnabled = enabled
        }
        if let schedule = value.schedule {
            result.workDays = Set(schedule.workDays ?? Array(result.workDays))
            result.workDayStart = parseHour(schedule.workDayStart) ?? result.workDayStart
            result.workDayEnd = parseHour(schedule.workDayEnd) ?? result.workDayEnd
            result.appointmentMinutes = schedule.defaultDurationMinutes ?? result.appointmentMinutes
            result.bufferMinutes = schedule.bufferMinutes ?? result.bufferMinutes
        }
        return result
    }
}

private extension CanonicalUIAdapters {
    static let encoder = JSONEncoder()
    static let decoder = JSONDecoder()
    static let isoWithFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    static let iso = ISO8601DateFormatter()

    static func object<T: Encodable>(_ value: T?) throws -> [String: Canonical.JSONValue] {
        guard let value else { return [:] }
        let data = try encoder.encode(value)
        guard case let .object(result) = try decoder.decode(Canonical.JSONValue.self, from: data) else {
            throw CanonicalUIAdapterError.invalidCanonicalRecord(String(describing: T.self))
        }
        return result
    }
    static func json<T: Encodable>(_ value: T) throws -> Canonical.JSONValue {
        try decoder.decode(Canonical.JSONValue.self, from: encoder.encode(value))
    }
    static func decode<T: Decodable>(_ fields: [String: Canonical.JSONValue]) throws -> T {
        try decoder.decode(T.self, from: encoder.encode(fields))
    }
    static func update(_ fields: inout [String: Canonical.JSONValue], _ key: String, _ value: String, _ old: String) {
        if value != old { fields[key] = .string(value) }
    }
    static func updateOptional(_ fields: inout [String: Canonical.JSONValue], _ key: String, _ value: String?, _ old: String?) {
        guard value != old else { return }; if let value { fields[key] = .string(value) } else { fields.removeValue(forKey: key) }
    }
    static func updateNumber(_ fields: inout [String: Canonical.JSONValue], _ key: String, _ value: Double, _ old: Double) {
        if value != old { fields[key] = .number(Decimal(string: String(value)) ?? 0) }
    }
    static func updateOptionalNumber(_ fields: inout [String: Canonical.JSONValue], _ key: String, _ value: Double?, _ old: Double?) {
        guard value != old else { return }
        if let value { fields[key] = number(value) } else { fields.removeValue(forKey: key) }
    }
    static func number(_ value: Double) -> Canonical.JSONValue {
        .number(Decimal(string: String(value)) ?? 0)
    }
    static func updateBool(_ fields: inout [String: Canonical.JSONValue], _ key: String, _ value: Bool, _ old: Bool) {
        if value != old { fields[key] = .bool(value) }
    }
    static func optional(_ value: String) -> String? { value.isEmpty ? nil : value }
    static func double(_ value: Decimal) -> Double { NSDecimalNumber(decimal: value).doubleValue }
    static func parsed(_ value: String, field: String, calendar: Calendar) throws -> Date {
        if let localDay = localDate(value, calendar: calendar) { return localDay }
        if let date = isoWithFractional.date(from: value) ?? iso.date(from: value) { return date }
        throw CanonicalUIAdapterError.invalidDate(field: field, value: value)
    }
    static func timestamp(_ value: Date) -> String { isoWithFractional.string(from: value) }
    static func day(_ value: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: value)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
    static func time(_ value: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.hour, .minute], from: value)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }
    static func hour(_ value: Int) -> String { String(format: "%02d:00", value) }
    static func parseHour(_ value: String?) -> Int? { value.flatMap { Int($0.split(separator: ":").first ?? "") } }
    static func localDate(_ value: String, calendar: Calendar) -> Date? {
        let pieces = value.split(separator: "-", omittingEmptySubsequences: false)
        guard value.count == 10, pieces.count == 3,
              let year = Int(pieces[0]), let month = Int(pieces[1]), let day = Int(pieces[2]) else { return nil }
        var components = DateComponents()
        components.calendar = calendar; components.timeZone = calendar.timeZone
        components.year = year; components.month = month; components.day = day
        return calendar.date(from: components)
    }
    static func scheduledDate(_ date: String?, time: String?, field: String, calendar: Calendar) throws -> Date? {
        guard let rawDate = date?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawDate.isEmpty else { return nil }

        // React Native historically persisted both date-only strings and ISO
        // timestamps here. Prefer the leading local YYYY-MM-DD when present so
        // a UTC offset cannot shift the intended appointment day.
        let datePrefix = String(rawDate.prefix(10))
        let baseDate = if let localDay = localDate(datePrefix, calendar: calendar) {
            localDay
        } else {
            try parsed(rawDate, field: field, calendar: calendar)
        }

        // The RN editor writes trimmed empty strings for an unset picker. Treat
        // that wire value exactly like nil in the UI projection; the canonical
        // baseline still retains the original empty string on an untouched edit.
        guard let rawTime = time?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawTime.isEmpty else { return baseDate }
        let timePieces = rawTime.split(separator: ":", omittingEmptySubsequences: false)
        guard (2...3).contains(timePieces.count),
              let hour = Int(timePieces[0]), (0..<24).contains(hour),
              let minute = Int(timePieces[1]), (0..<60).contains(minute),
              timePieces.count < 3 || Int(timePieces[2]).map({ (0..<60).contains($0) }) == true else {
            throw CanonicalUIAdapterError.invalidDate(field: field, value: "\(rawDate) \(rawTime)")
        }
        var components = calendar.dateComponents([.year, .month, .day], from: baseDate)
        components.calendar = calendar; components.timeZone = calendar.timeZone
        components.hour = hour; components.minute = minute
        if timePieces.count == 3 { components.second = Int(timePieces[2]) }
        guard let result = calendar.date(from: components) else {
            throw CanonicalUIAdapterError.invalidDate(field: field, value: "\(rawDate) \(rawTime)")
        }
        return result
    }
    static func displayPaymentMethod(_ value: String) -> String {
        switch value.lowercased() {
        case "cash": return "Cash"; case "check", "cheque": return "Check"; case "card": return "Card"
        case "ach", "bank_transfer", "bank transfer": return "ACH"; default: return "Other"
        }
    }
    static func canonicalPaymentMethod(_ value: String) -> String {
        switch value.lowercased() {
        case "cash": return "cash"; case "check", "cheque": return "check"; case "card": return "card"
        case "ach", "bank_transfer", "bank transfer": return "bank_transfer"; default: return "other"
        }
    }
    static func merge(payment value: Payment, baseline: Canonical.Payment, calendar: Calendar) throws -> Canonical.Payment {
        var fields = try object(baseline); let original = try payment(from: baseline, calendar: calendar)
        update(&fields, "id", value.id, original.id); updateNumber(&fields, "amount", value.amount, original.amount)
        if value.date != original.date { fields["date"] = .string(day(value.date, calendar: calendar)) }
        if value.method != original.method { fields["method"] = .string(canonicalPaymentMethod(value.method)) }
        updateOptional(&fields, "note", optional(value.note), optional(original.note))
        if value.voidedAt != original.voidedAt {
            if let date = value.voidedAt { fields["voidedAt"] = .string(timestamp(date)) } else { fields.removeValue(forKey: "voidedAt") }
        }
        return try decode(fields)
    }
    static func newCanonicalPayment(_ value: Payment, calendar: Calendar) throws -> Canonical.Payment {
        let fields: [String: Canonical.JSONValue] = [
            "id": .string(value.id), "amount": .number(Decimal(string: String(value.amount)) ?? 0),
            "date": .string(day(value.date, calendar: calendar)), "method": .string(canonicalPaymentMethod(value.method)),
            "note": value.note.isEmpty ? .null : .string(value.note),
            "voidedAt": value.voidedAt.map { .string(timestamp($0)) } ?? .null
        ]
        return try decode(fields)
    }
    static func scheduleFieldsChanged(_ value: BusinessSettings, _ old: BusinessSettings) -> Bool {
        value.workDays != old.workDays || value.workDayStart != old.workDayStart || value.workDayEnd != old.workDayEnd ||
        value.appointmentMinutes != old.appointmentMinutes || value.bufferMinutes != old.bufferMinutes ||
        value.bookableSlotsEnabled != old.bookableSlotsEnabled
    }
}
