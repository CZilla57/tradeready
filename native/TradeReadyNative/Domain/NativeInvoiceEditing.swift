import Foundation

/// Pure invoice create/edit policy mirroring `screens/AddInvoiceScreen.tsx`.
///
/// Standalone-compilable (Foundation only). Number generation is injected by
/// the caller (AppStore passes `InvoiceNumberRules.nextNumber` over the
/// latest canonical records at commit time), so this file never touches
/// persistence and the `swiftc` harness compiles it alone.
///
/// Contract:
/// - Normalize by trimming; never dismiss invalid drafts (validation is a
///   value, not a throw).
/// - Save only editor-owned fields; payments, job/recurrence linkage,
///   delivery metadata, import markers, nested metadata and unknown fields
///   are preserved by `CanonicalUIAdapters.canonical(from edit:)` below this
///   layer — this type only decides WHAT the editor may write.
/// - Deleted/conflicting baseline → typed refusal, never silent recreate.
struct NativeInvoiceDraft: Equatable {
    var customer: String
    var customerId: String
    var number: String
    var amount: Double
    var due: String
    var email: String
    var phone: String
    var description: String
}

enum NativeInvoiceEditInvalidReason: String, Equatable {
    case missingCustomer = "missingCustomer"
    case invalidAmount = "invalidAmount"
}

enum NativeInvoiceEditRefusal: Error, Equatable {
    case missingRecord
    case conflictingRecord
    case persistenceUnavailable
    case invalidDraft([NativeInvoiceEditInvalidReason])
}

struct NativeInvoiceValidatedEdit: Equatable {
    var customer: String
    var customerId: String
    /// Trimmed original, or the injected generated number when blank.
    var number: String
    var amount: Double
    var due: String
    var email: String
    var phone: String
    var description: String
    /// True when the number was auto-resolved (caller records provenance).
    var numberWasResolved: Bool
}

enum NativeInvoiceEditing {
    static func normalized(_ draft: NativeInvoiceDraft) -> NativeInvoiceDraft {
        var result = draft
        result.customer = draft.customer.trimmingCharacters(in: .whitespacesAndNewlines)
        result.customerId = draft.customerId.trimmingCharacters(in: .whitespacesAndNewlines)
        result.number = draft.number.trimmingCharacters(in: .whitespacesAndNewlines)
        result.due = draft.due.trimmingCharacters(in: .whitespacesAndNewlines)
        result.email = draft.email.trimmingCharacters(in: .whitespacesAndNewlines)
        result.phone = draft.phone.trimmingCharacters(in: .whitespacesAndNewlines)
        result.description = draft.description.trimmingCharacters(in: .whitespacesAndNewlines)
        return result
    }

    static func validationReasons(_ draft: NativeInvoiceDraft) -> [NativeInvoiceEditInvalidReason] {
        let value = normalized(draft)
        var reasons: [NativeInvoiceEditInvalidReason] = []
        if value.customer.isEmpty { reasons.append(.missingCustomer) }
        if !(value.amount.isFinite && value.amount > 0) { reasons.append(.invalidAmount) }
        return reasons
    }

    /// Strict "YYYY-MM-DD" ↔ local-midnight `Date` bridge for the editor's
    /// due field. Anything else fails closed to nil; the caller keeps the
    /// current due date rather than writing a corrupt value.
    static func dayString(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    static func date(fromDayString raw: String, calendar: Calendar = .current) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: "-")
        guard parts.count == 3,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              (1...12).contains(m), (1...31).contains(d)
        else { return nil }
        return calendar.date(from: DateComponents(year: y, month: m, day: d))
    }

    /// - `baselineExists`: false for create, or the record vanished → `.missingRecord`.
    /// - `baselineChangedSinceOpened`: another writer (sync/webhook) moved the
    ///   record under an open editor → `.conflictingRecord`; the caller must
    ///   re-resolve and ask, never overwrite.
    /// - `resolveNumber`: injected `InvoiceNumberRules.nextNumber` result.
    static func commit(
        _ draft: NativeInvoiceDraft,
        baselineExists: Bool,
        baselineChangedSinceOpened: Bool,
        resolveNumber: @autoclosure () -> String
    ) -> Result<NativeInvoiceValidatedEdit, NativeInvoiceEditRefusal> {
        guard baselineExists else { return .failure(.missingRecord) }
        if baselineChangedSinceOpened { return .failure(.conflictingRecord) }
        let value = normalized(draft)
        let reasons = validationReasons(value)
        if !reasons.isEmpty { return .failure(.invalidDraft(reasons)) }
        let trimmedNumber = value.number
        let wasBlank = trimmedNumber.isEmpty
        return .success(NativeInvoiceValidatedEdit(
            customer: value.customer,
            customerId: value.customerId,
            number: wasBlank ? resolveNumber() : trimmedNumber,
            amount: value.amount,
            due: value.due,
            email: value.email,
            phone: value.phone,
            description: value.description,
            numberWasResolved: wasBlank
        ))
    }
}
