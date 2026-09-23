import Foundation

// MARK: - Expense editor composition (task 9.10, requirements E1, E2)
//
// Port of `components/money/AddExpenseModal.tsx` plus the `selectLinkableJobs`
// helper in `utils/profitabilityDisplay.ts`. Everything the expense editor
// decides — which jobs can be linked, what a receipt scan is allowed to fill,
// the amount-text contract, the save guard, the scan banner copy — lives here so
// the SwiftUI sheet owns no policy of its own.
//
// The scan rules are the RN modal's: a result only lands in a field the user has
// not touched, every field is independently optional, and a failure leaves
// manual entry exactly as it was. Nothing here writes canonical state.

/// Which fields the user has typed into. RN keeps this in a ref so the async
/// scan callback always reads the current set; the editor mirrors that by
/// holding one value here and updating it from the field bindings.
struct NativeExpenseTouchedFields: Equatable {
    var merchant = false
    var amount = false
    var date = false
    var category = false
}

/// The receipt-scan lifecycle shown under the photo preview (`ScanState` in RN).
enum NativeExpenseScanState: Equatable {
    case idle
    case reading
    case filled
    case empty
    case failed
}

/// RN's `ExpenseDraft` field set, held as editor text so nothing is lost while
/// the user is mid-keystroke. `categoryID` stays the raw canonical id (unknown
/// ids round-trip) and `date` is the local calendar day.
struct NativeExpenseEditorDraft: Equatable {
    var merchant = ""
    var amountText = ""
    var date = Date()
    var categoryID = "materials"
    var notes = ""
    var receiptUri: String?
    var jobId: String?

    /// A new expense: today's local day, Materials, nothing linked. Mirrors the
    /// modal's reset-on-open (`new Date().toISOString().split("T")[0]` is the
    /// UTC day in RN; native uses the stored local day, the same deliberate
    /// difference the 9.09 expense rows record).
    static func newExpense(now: Date = Date(), calendar: Calendar = NativeCashBasis.localCalendar) -> NativeExpenseEditorDraft {
        var draft = NativeExpenseEditorDraft()
        draft.date = calendar.startOfDay(for: now)
        return draft
    }
}

/// The two save guards, in the order RN checks them.
enum NativeExpenseValidation: Equatable {
    case missingMerchant
    case invalidAmount

    /// RN's `Alert.alert('Missing Info', ...)` copy.
    var message: String {
        switch self {
        case .missingMerchant: "Please enter a description."
        case .invalidAmount: "Please enter a valid amount."
        }
    }
}

/// What one scan application did: how many untouched fields it filled, and
/// whether the model flagged the photo as blurry.
struct NativeExpenseScanApplication: Equatable {
    var applied: Int
    var blurry: Bool

    var state: NativeExpenseScanState { applied > 0 ? .filled : .empty }
}

enum NativeExpenseComposer {
    /// `LINKABLE_STATUSES` in `utils/profitabilityDisplay.ts`: jobs still in
    /// play. Declined/lead estimates are deliberately not linkable.
    static let linkableStatuses: Set<String> = [
        "approved", "scheduled", "in_progress", "complete", "invoiced", "paid",
    ]

    // MARK: Job link (`selectLinkableJobs`)

    /// Linkable jobs, newest first by `createdAt` (code-unit compare — the RN
    /// comment is explicit that this is not `localeCompare`). `alwaysIncludeID`
    /// keeps a pre-linked job in the list even when the filter would drop it.
    static func linkableJobs(_ jobs: [Canonical.Job], alwaysIncludeID: String? = nil) -> [Canonical.Job] {
        jobs
            .filter { job in
                job.id == alwaysIncludeID
                    || (!isArchived(job) && linkableStatuses.contains(job.status))
            }
            .sorted { lhs, rhs in
                if lhs.createdAt == rhs.createdAt { return false }
                return lhs.createdAt > rhs.createdAt
            }
    }

    static func isArchived(_ job: Canonical.Job) -> Bool {
        !(job.archivedAt ?? "").isEmpty
    }

    /// The chip label for a linked job; nil when the id is absent or unknown.
    static func jobTitle(id: String?, in jobs: [Canonical.Job]) -> String? {
        guard let id, !id.isEmpty else { return nil }
        return jobs.first { $0.id == id }?.title
    }

    // MARK: Amount

    /// RN's `parseFloat`: leading numeric prefix, non-finite and non-positive
    /// values rejected. `"40"`/`"40.50"`/`"$40"`-style junk all behave the way
    /// the modal's guard does.
    static func amountValue(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let value = (trimmed as NSString).doubleValue
        guard value.isFinite, value > 0 else { return nil }
        return value
    }

    /// The scan's amount-to-text rule: `Number.isInteger(n) ? String(n) :
    /// n.toFixed(2)`. `84` → "84", `84.5` → "84.50", `84.17` → "84.17".
    static func amountText(_ amount: Decimal) -> String {
        var source = amount
        var whole = Decimal()
        NSDecimalRound(&whole, &source, 0, .plain)
        if whole == amount {
            return NSDecimalNumber(decimal: amount).stringValue
        }
        var cents = Decimal()
        NSDecimalRound(&cents, &source, 2, .plain)
        return String(format: "%.2f", NSDecimalNumber(decimal: cents).doubleValue)
    }

    // MARK: Dates

    /// A real local calendar day from `YYYY-MM-DD`. `Date` tolerates rollovers
    /// (`2026-02-31` becomes March 3), so the components are compared back — the
    /// editor must never stamp a day the receipt does not name. The 9.04 parser
    /// applies the same rule to model replies; this keeps a hand-built
    /// extraction from slipping past it.
    static func isoDay(_ text: String) -> Date? {
        guard text.count == 10, let date = NativeCashBasis.parseLocalDate(text) else { return nil }
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        let components = NativeCashBasis.localComponents(date)
        guard components.year == parts[0], components.month == parts[1] - 1, components.day == parts[2] else {
            return nil
        }
        return date
    }

    // MARK: Save

    /// RN checks the description first, then the amount; the editor surfaces the
    /// same two messages.
    static func validation(_ draft: NativeExpenseEditorDraft) -> NativeExpenseValidation? {
        if draft.merchant.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .missingMerchant
        }
        if amountValue(draft.amountText) == nil { return .invalidAmount }
        return nil
    }

    // MARK: Receipt scan

    /// Applies an extraction to the fields the user has NOT touched. Every field
    /// is independent: a null merchant cannot stop the amount from landing.
    @discardableResult
    static func applyingScan(
        _ extraction: NativeReceiptExtraction,
        to draft: inout NativeExpenseEditorDraft,
        touched: NativeExpenseTouchedFields
    ) -> NativeExpenseScanApplication {
        var applied = 0
        if !touched.merchant, let merchant = extraction.merchant {
            draft.merchant = merchant
            applied += 1
        }
        if !touched.amount, let amount = extraction.amount {
            draft.amountText = amountText(amount)
            applied += 1
        }
        if !touched.date,
           let dateText = extraction.date,
           let parsed = isoDay(dateText) {
            draft.date = parsed
            applied += 1
        }
        if !touched.category,
           let category = extraction.category,
           NativeExpenseCategories.all.contains(where: { $0.id == category }) {
            draft.categoryID = category
            applied += 1
        }
        return NativeExpenseScanApplication(applied: applied, blurry: extraction.confidence == "low")
    }

    /// The one-line note under the preview. `nil` for `.idle` (no banner).
    static func scanBanner(_ state: NativeExpenseScanState, blurry: Bool = false) -> String? {
        switch state {
        case .idle: nil
        case .reading: "Reading receipt…"
        case .filled:
            blurry
                ? "Filled from receipt — the photo looks blurry, double-check the details"
                : "Filled from receipt — double-check the details"
        case .empty: "Receipt read — nothing new to fill in"
        case .failed: "Couldn't read the receipt — enter the details manually"
        }
    }
}
