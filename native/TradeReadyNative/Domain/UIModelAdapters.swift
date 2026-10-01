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
        if let endCount { fields["endCount"] = .number(Decimal(endCount)) }
        if let endDate { fields["endDate"] = .string(endDate) }
        return try decode(fields)
    }

    /// Builds a new canonical job using the production duplicate whitelist.
    /// Nested materials retain their own preservation metadata, while every
    /// source lifecycle and job-level preservation field starts clean.
    static func duplicateJob(
        _ source: Canonical.Job,
        id: String,
        createdAt: Date,
        calendar: Calendar = .current
    ) throws -> NativeJobDuplicateDraft {
        let fields: [String: Canonical.JSONValue] = [
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
        let canonical: Canonical.Job = try decode(fields)
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
    static func estimateApprovalSnapshot(
        job: Canonical.Job,
        customerName: String?,
        businessName: String
    ) throws -> Canonical.EstimateApprovalSnapshot {
        let laborCost = job.laborHours * job.laborRate
        let materialBase = job.materials.reduce(Decimal.zero) {
            $0 + $1.quantity * $1.unitCost
        }
        let materialCost = materialBase * (1 + job.materialMarkup / 100)
        let visibleDirectCosts = (job.jobCosts ?? []).compactMap { cost -> (String, Decimal)? in
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

        var lineItems: [[String: Canonical.JSONValue]] = [[
            "label": .string("Labor (\(estimateNumber(job.laborHours)) hrs @ $\(estimateNumber(job.laborRate))/hr)"),
            "amount": .number(laborCost)
        ]]
        if !job.materials.isEmpty {
            let suffix = job.materials.count == 1 ? "item" : "items"
            lineItems.append([
                "label": .string("Materials (\(job.materials.count) \(suffix))"),
                "amount": .number(materialCost)
            ])
        }
        for directCost in visibleDirectCosts {
            lineItems.append([
                "label": .string(directCost.0),
                "amount": .number(directCost.1)
            ])
        }
        let visibleDirectTotal = visibleDirectCosts.reduce(Decimal.zero) { $0 + $1.1 }
        let operatingCost = job.estimateTotal - laborCost - materialCost - visibleDirectTotal
        if operatingCost > 0 {
            lineItems.append([
                "label": .string("Overhead & operating costs"),
                "amount": .number(operatingCost)
            ])
        }

        return try decode([
            "businessName": .string(businessName.isEmpty ? "Your tradesperson" : businessName),
            "customerName": .string((customerName?.isEmpty == false ? customerName : nil) ?? job.customerName),
            "jobTitle": .string(job.title),
            "lineItems": .array(lineItems.map(Canonical.JSONValue.object)),
            "total": .number(job.estimateTotal),
            "currency": .string("USD")
        ])
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
    static func estimateApprovalSnapshotsMatch(
        _ lhs: Canonical.EstimateApprovalSnapshot,
        _ rhs: Canonical.EstimateApprovalSnapshot
    ) -> Bool {
        guard lhs.businessName == rhs.businessName,
              lhs.customerName == rhs.customerName,
              lhs.jobTitle == rhs.jobTitle,
              lhs.total == rhs.total,
              lhs.currency == rhs.currency,
              lhs.preservation == rhs.preservation,
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
    static func canonical(
        from pricing: NativeJobPricingDraft,
        baseline: Canonical.Job
    ) throws -> Canonical.Job {
        guard pricing.jobID == baseline.id else {
            throw CanonicalUIAdapterError.invalidCanonicalRecord("job-pricing-id")
        }
        var result = baseline
        result.laborHours = pricing.laborHours
        result.laborBreakdown = pricing.laborBreakdown
        result.laborRate = pricing.laborRate
        result.materials = pricing.materials
        result.materialMarkup = pricing.materialMarkup
        result.jobCosts = pricing.jobCosts.isEmpty ? nil : pricing.jobCosts
        result.overhead = pricing.overheadPercent
        result.margin = pricing.marginPercent
        result.estimateTotal = PricingEngine.calculate(pricing.input).total
        return result
    }

    private static func estimateNumber(_ value: Decimal) -> String {
        NSDecimalNumber(decimal: value).stringValue
    }

    /// Not `private`: also used by `JobInvoiceDomain`'s line-item builder, so
    /// an invoice's direct-cost labels match the estimate review's exactly.
    static func estimateDirectCostLabel(_ cost: Canonical.JobCost) -> String {
        let ownLabel = cost.label.trimmingCharacters(in: .whitespacesAndNewlines)
        if !ownLabel.isEmpty { return ownLabel }
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
        updateNumber(&fields, "estimateTotal", edit.value.estimateTotal, original.estimateTotal)
        updateNumber(&fields, "laborHours", edit.value.laborHours, original.laborHours)
        updateNumber(&fields, "laborRate", edit.value.laborRate, original.laborRate)
        update(&fields, "notes", edit.value.notes, original.notes)
        updateOptional(&fields, "invoiceId", edit.value.invoiceId, original.invoiceId)
        updateOptional(&fields, "archivedAt", edit.value.archivedAt, original.archivedAt)
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
                 archivedAt: value.archivedAt)
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
                   archivedAt: value.archivedAt)
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
