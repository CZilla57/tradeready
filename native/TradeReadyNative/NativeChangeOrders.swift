import Foundation

enum NativeChangeOrderStatus: String, Equatable {
    case pending
    case awaiting
    case approved
    case declined
    case cancelled
}

enum NativeChangeOrderManualDecision: String, Equatable {
    case approved
    case declined
}

struct NativeValidatedChangeOrderInput: Equatable {
    let title: String
    let description: String?
    let amount: Decimal
}

enum NativeChangeOrderError: LocalizedError, Equatable {
    case invalidInput(String)
    case jobNotFound
    case jobNotEligible
    case duplicateIdentifier
    case changeOrderNotFound
    case changeOrderNotPending
    case changeOrderNotActionable

    var errorDescription: String? {
        switch self {
        case let .invalidInput(message): message
        case .jobNotFound: "The job no longer exists. The change order was not saved."
        case .jobNotEligible: "This job can no longer accept a change order. Nothing was changed."
        case .duplicateIdentifier: "That change order already exists. Nothing was overwritten."
        case .changeOrderNotFound: "The change order no longer exists. Nothing was changed."
        case .changeOrderNotPending: "Only a pending change order can be edited or deleted."
        case .changeOrderNotActionable: "This change order has already been decided or cancelled."
        }
    }

    /// True when retrying the same draft cannot succeed: the job can no longer
    /// take a change order, or the order was decided while the form was open.
    /// `AddChangeOrderScreen` closes the editor in those two cases
    /// (`navigation.goBack()`); the native editor does the same once the
    /// message is acknowledged, and keeps the form for every other refusal so
    /// the entry can be corrected or retried.
    var closesEditorOnFailure: Bool {
        switch self {
        case .jobNotEligible, .changeOrderNotPending: true
        case .invalidInput, .jobNotFound, .duplicateIdentifier, .changeOrderNotFound,
             .changeOrderNotActionable: false
        }
    }
}

/// Row badge tone for a derived change-order status. Mirrors the React Native
/// section's `STATUS_BADGE` mapping; tones that mapping never uses are omitted
/// so the native palette and the oracle stay comparable at a glance.
enum NativeChangeOrderBadgeTone: Equatable {
    case muted
    case accent
    case success
    case danger
}

extension NativeChangeOrderStatus {
    static func isApprovalEligible(_ order: Canonical.ChangeOrder) -> Bool {
        (order.cancelledAt ?? "").isEmpty
            && order.manualDecision == nil
            && order.approval?.decision == nil
            && (NativeChangeOrders.status(of: order) == .pending || NativeChangeOrders.status(of: order) == .awaiting)
    }

    /// Mirrors `STATUS_LABEL` in `components/ChangeOrdersSection.tsx`.
    var displayLabel: String {
        switch self {
        case .pending: "Pending"
        case .awaiting: "Awaiting"
        case .approved: "Approved"
        case .declined: "Declined"
        case .cancelled: "Cancelled"
        }
    }

    /// Mirrors `STATUS_BADGE` in `components/ChangeOrdersSection.tsx`.
    var badgeTone: NativeChangeOrderBadgeTone {
        switch self {
        case .pending, .cancelled: .muted
        case .awaiting: .accent
        case .approved: .success
        case .declined: .danger
        }
    }

    /// Only pending and awaiting rows offer actions. Decided and cancelled
    /// rows are history and must not look tappable.
    var isActionable: Bool { self == .pending || self == .awaiting }

    /// Edit and delete are pending-only, matching `validateChangeOrderInput`'s
    /// pending-only edit contract — a sent or decided order is a record.
    var isEditable: Bool { self == .pending }
}

/// One job-detail change-order row. Display-only: every mutation re-resolves
/// the canonical job and order by ID, so this value copy can expire harmlessly.
struct NativeChangeOrderRow: Identifiable, Equatable {
    let id: String
    let title: String
    /// The on-site decision note, when one was recorded
    /// (`manualDecision.note`), rendered under the title like the oracle.
    let note: String?
    let amount: Decimal
    let status: NativeChangeOrderStatus

    var statusLabel: String { status.displayLabel }
    var badgeTone: NativeChangeOrderBadgeTone { status.badgeTone }
    var isActionable: Bool { status.isActionable }
    var canEdit: Bool { status.isEditable }
    var canDelete: Bool { status.isEditable }
}

/// The job-detail change-order section read model, built from the canonical job
/// exactly as `ChangeOrdersSection` builds from `job.changeOrders`.
struct NativeChangeOrderSectionState: Equatable {
    let jobID: String
    let rows: [NativeChangeOrderRow]
    /// `canAddChangeOrder(job.status)` — an agreed baseline, an open bill.
    let canAdd: Bool
    /// Σ approved, non-cancelled orders, cents-rounded like
    /// `approvedChangeOrderTotal`.
    let approvedTotal: Decimal

    /// React Native renders nothing at all when there are no orders and the
    /// job cannot take one either.
    var isVisible: Bool { !rows.isEmpty || canAdd }
}

/// Editable state for the add/edit change-order sheet. Ported from
/// `AddChangeOrderScreen.tsx`, which keeps the amount as raw text so the
/// validation message can explain a bad entry instead of silently coercing it.
struct NativeChangeOrderDraft: Identifiable, Equatable {
    let jobID: String
    /// Non-nil when editing an existing, still-pending order.
    let editingID: String?
    var title: String
    var description: String
    var amountText: String

    var id: String { editingID ?? "\(jobID)-new" }
    var isEditing: Bool { editingID != nil }
}

/// Result of committing an editor draft. The typed refusals let the sheet
/// reuse the canonical rules instead of keeping a second validation model.
enum NativeChangeOrderCommitOutcome: Equatable {
    case created(id: String)
    case updated
    /// Refused by the canonical rules; `NativeChangeOrderError` carries the
    /// reason and whether the form can be corrected in place.
    case refused(NativeChangeOrderError)
    /// Local persistence refused the write (read-only store or a save
    /// failure). The message is already user-safe.
    case failed(String)
}

/// Canonical, dependency-free change-order rules mirrored from
/// `utils/changeOrders.ts`. Mutations always return a copied job and touch only
/// fields owned by the requested action, preserving approval data and unknown
/// forward-compatible fields on the job and every existing change order.
enum NativeChangeOrders {
    private static let addableStatuses: Set<String> = [
        "approved", "scheduled", "in_progress", "complete"
    ]

    static func status(of order: Canonical.ChangeOrder) -> NativeChangeOrderStatus {
        if !(order.cancelledAt ?? "").isEmpty { return .cancelled }
        let decision = order.approval?.decision ?? order.manualDecision?.decision
        if decision == "approved" { return .approved }
        if decision == "declined" { return .declined }
        if order.approval != nil { return .awaiting }
        return .pending
    }

    static func approvedTotal(
        in job: Canonical.Job,
        excluding excludedID: String? = nil
    ) -> Decimal {
        approvedTotal(in: (job.changeOrders ?? []).filter { $0.id != excludedID })
    }

    /// Σ approved, non-cancelled order amounts, cents-rounded once — the same
    /// two-stage rule `approvedChangeOrderTotal` uses in `utils/changeOrders.ts`.
    static func approvedTotal(in changeOrders: [Canonical.ChangeOrder]) -> Decimal {
        cents(changeOrders.reduce(Decimal.zero) { partial, order in
            status(of: order) == .approved ? partial + order.amount : partial
        })
    }

    /// The job-detail section read model. Record order is preserved — the
    /// oracle never sorts `job.changeOrders`.
    static func sectionState(
        jobID: String,
        status jobStatus: String,
        changeOrders: [Canonical.ChangeOrder]
    ) -> NativeChangeOrderSectionState {
        .init(
            jobID: jobID,
            rows: changeOrders.map(row(for:)),
            canAdd: canAdd(to: jobStatus),
            approvedTotal: approvedTotal(in: changeOrders)
        )
    }

    /// Display projection of one order. The note is rendered only when it is
    /// present and non-empty, matching the oracle's falsy check.
    static func row(for order: Canonical.ChangeOrder) -> NativeChangeOrderRow {
        let note = order.manualDecision?.note
        return .init(
            id: order.id,
            title: order.title,
            note: (note?.isEmpty ?? true) ? nil : note,
            amount: order.amount,
            status: status(of: order)
        )
    }

    static func billableTotal(
        for job: Canonical.Job,
        excluding excludedID: String? = nil
    ) -> Decimal {
        cents(job.estimateTotal + approvedTotal(in: job, excluding: excludedID))
    }

    static func canAdd(to jobStatus: String) -> Bool {
        addableStatuses.contains(jobStatus)
    }

    /// The React Native implementation stamps
    /// `new Date().toISOString().split("T")[0]`, so these records use the UTC
    /// calendar day even though other native date-only workflows are local.
    static func recordDateString(for date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }

    static func validate(
        title: String,
        description: String,
        amountText: String,
        job: Canonical.Job,
        editingID: String? = nil
    ) -> Result<NativeValidatedChangeOrderInput, NativeChangeOrderError> {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            return .failure(.invalidInput("Please give this change a short title."))
        }

        let trimmedAmount = amountText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAmount.isEmpty,
              let parsedAmount = Decimal(string: trimmedAmount, locale: Locale(identifier: "en_US_POSIX")),
              parsedAmount != 0
        else {
            return .failure(.invalidInput("Please enter a non-zero amount (negative for a credit)."))
        }

        let amount = cents(parsedAmount)
        guard billableTotal(for: job, excluding: editingID) + parsedAmount >= 0 else {
            return .failure(.invalidInput("This credit would take the job's total below $0."))
        }

        let trimmedDescription = description.trimmingCharacters(in: .whitespacesAndNewlines)
        return .success(.init(
            title: trimmedTitle,
            description: trimmedDescription.isEmpty ? nil : trimmedDescription,
            amount: amount
        ))
    }

    static func adding(
        to job: Canonical.Job,
        id: String,
        title: String,
        description: String,
        amountText: String,
        createdAt: String
    ) throws -> Canonical.Job {
        guard canAdd(to: job.status) else { throw NativeChangeOrderError.jobNotEligible }
        guard !(job.changeOrders ?? []).contains(where: { $0.id == id }) else {
            throw NativeChangeOrderError.duplicateIdentifier
        }
        let input = try validate(
            title: title,
            description: description,
            amountText: amountText,
            job: job
        ).get()
        var result = job
        var orders = result.changeOrders ?? []
        orders.append(.init(
            id: id,
            title: input.title,
            description: input.description,
            amount: input.amount,
            createdAt: createdAt
        ))
        result.changeOrders = orders
        return result
    }

    static func editing(
        _ orderID: String,
        in job: Canonical.Job,
        title: String,
        description: String,
        amountText: String
    ) throws -> Canonical.Job {
        guard let index = job.changeOrders?.firstIndex(where: { $0.id == orderID }) else {
            throw NativeChangeOrderError.changeOrderNotFound
        }
        guard status(of: job.changeOrders![index]) == .pending else {
            throw NativeChangeOrderError.changeOrderNotPending
        }
        let input = try validate(
            title: title,
            description: description,
            amountText: amountText,
            job: job,
            editingID: orderID
        ).get()
        var result = job
        result.changeOrders![index].title = input.title
        result.changeOrders![index].description = input.description
        result.changeOrders![index].amount = input.amount
        return result
    }

    static func applyingManualDecision(
        _ decision: NativeChangeOrderManualDecision,
        to orderID: String,
        in job: Canonical.Job,
        note: String,
        decidedAt: String
    ) throws -> Canonical.Job {
        guard let index = job.changeOrders?.firstIndex(where: { $0.id == orderID }) else {
            throw NativeChangeOrderError.changeOrderNotFound
        }
        let currentStatus = status(of: job.changeOrders![index])
        guard currentStatus == .pending || currentStatus == .awaiting else {
            throw NativeChangeOrderError.changeOrderNotActionable
        }
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        var result = job
        result.changeOrders![index].manualDecision = .init(
            decision: decision.rawValue,
            decidedAt: decidedAt,
            note: trimmedNote.isEmpty ? nil : trimmedNote
        )
        return result
    }

    static func cancelling(
        _ orderID: String,
        in job: Canonical.Job,
        cancelledAt: String
    ) throws -> Canonical.Job {
        guard let index = job.changeOrders?.firstIndex(where: { $0.id == orderID }) else {
            throw NativeChangeOrderError.changeOrderNotFound
        }
        let currentStatus = status(of: job.changeOrders![index])
        guard currentStatus == .pending || currentStatus == .awaiting else {
            throw NativeChangeOrderError.changeOrderNotActionable
        }
        var result = job
        result.changeOrders![index].cancelledAt = cancelledAt
        return result
    }

    static func deletingPending(_ orderID: String, in job: Canonical.Job) throws -> Canonical.Job {
        guard let index = job.changeOrders?.firstIndex(where: { $0.id == orderID }) else {
            throw NativeChangeOrderError.changeOrderNotFound
        }
        guard status(of: job.changeOrders![index]) == .pending else {
            throw NativeChangeOrderError.changeOrderNotPending
        }
        var result = job
        result.changeOrders!.remove(at: index)
        return result
    }

    private static func cents(_ value: Decimal) -> Decimal {
        // JavaScript's Math.round is floor(x + 0.5), including for negative
        // ties. Convert through Double because the React Native oracle also
        // parses and calculates these values as IEEE-754 numbers.
        let text = NSDecimalNumber(decimal: value).stringValue
        guard let source = Double(text), source.isFinite else { return 0 }
        let rounded = floor(source * 100 + 0.5) / 100
        return Decimal(string: String(rounded), locale: Locale(identifier: "en_US_POSIX")) ?? 0
    }
}
