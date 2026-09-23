import Foundation

/// Pure bulk-selection policy mirroring `utils/bulkInvoiceActions.ts`
/// (`splitRemindable`). Settlement itself reuses the ledger's settle rule per
/// record; the AppStore commits the batch atomically.
///
/// Standalone-compilable (Foundation only). Paid invoices are silently ignored
/// even if selected — nothing to remind or settle.
enum NativeBulkRemindChannel: String, Equatable, Sendable {
    case email, text
}

struct NativeBulkRemindableItem: Equatable {
    var id: String
    var isPaid: Bool
    var email: String
    var phone: String
}

struct NativeRemindableSplit: Equatable {
    /// Unpaid, selected, and reachable on the channel — in list order.
    var eligible: [NativeBulkRemindableItem]
    /// Unpaid and selected but missing the channel's contact field.
    var skippedNoContact: [NativeBulkRemindableItem]
}

enum NativeInvoiceBulk {
    static func splitRemindable(
        _ invoices: [NativeBulkRemindableItem],
        selectedIDs: Set<String>,
        channel: NativeBulkRemindChannel
    ) -> NativeRemindableSplit {
        let selected = invoices.filter { selectedIDs.contains($0.id) && !$0.isPaid }
        let reachable = { (item: NativeBulkRemindableItem) -> Bool in
            switch channel {
            case .email: return !item.email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .text: return !item.phone.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        }
        return NativeRemindableSplit(
            eligible: selected.filter(reachable),
            skippedNoContact: selected.filter { !reachable($0) })
    }
}
