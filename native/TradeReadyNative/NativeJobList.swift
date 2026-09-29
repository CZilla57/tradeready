import Foundation

enum NativeJobListFilter: String, CaseIterable, Identifiable {
    case active
    case quotes
    case complete
    case paid
    case declined
    case all
    case archived

    var id: String { rawValue }

    var title: String {
        switch self {
        case .active: "Active"
        case .quotes: "Quotes"
        case .complete: "Complete"
        case .paid: "Paid"
        case .declined: "Declined"
        case .all: "All"
        case .archived: "Archived"
        }
    }

    fileprivate var statuses: Set<String>? {
        switch self {
        case .active: ["lead", "estimate_sent", "approved", "scheduled", "in_progress"]
        case .quotes: ["lead", "estimate_sent"]
        case .complete: ["complete", "invoiced"]
        case .paid: ["paid"]
        case .declined: ["declined"]
        case .all, .archived: nil
        }
    }
}

struct NativeJobListItem: Identifiable, Equatable {
    let id: String
    let title: String
    let customerName: String
    let description: String
    let status: String
    let createdAt: Date
    let billableTotal: Double
    let isArchived: Bool
    let isRecurring: Bool
}

struct NativeJobListChangeOrder: Equatable {
    let amount: Decimal
    let approvalDecision: String?
    let manualDecision: String?
    let isCancelled: Bool
}

struct NativeJobListFilterSummary: Identifiable, Equatable {
    let filter: NativeJobListFilter
    let count: Int

    var id: NativeJobListFilter { filter }
}

struct NativeJobListStats: Equatable {
    let activeCount: Int
    let openEstimateCount: Int
    let pendingValue: Double
}

struct NativeJobListState: Equatable {
    let items: [NativeJobListItem]
    let filters: [NativeJobListFilterSummary]
    let effectiveFilter: NativeJobListFilter
    let stats: NativeJobListStats
    let nonArchivedCount: Int
}

/// Pure Phase 6 job-list contract ported from `screens/JobsScreen.tsx`.
/// Canonical-only fields are projected into `NativeJobListItem` by AppStore;
/// filtering this read model can never rewrite the canonical job record.
enum NativeJobList {
    /// Estimate plus approved change orders. A link decision outranks an
    /// on-site decision and cancellation outranks both, matching the existing
    /// TypeScript display contract.
    static func billableTotal(
        estimate: Decimal,
        changeOrders: [NativeJobListChangeOrder]
    ) -> Double {
        let approved = changeOrders.reduce(Decimal.zero) { total, order in
            guard !order.isCancelled else { return total }
            let decision = order.approvalDecision ?? order.manualDecision
            return decision == "approved" ? total + order.amount : total
        }
        // React Native's approvedChangeOrderTotal rounds first, then
        // jobBillableTotal rounds the estimate plus that subtotal again.
        return NSDecimalNumber(decimal: cents(estimate + cents(approved))).doubleValue
    }

    static func state(
        items: [NativeJobListItem],
        selectedFilter: NativeJobListFilter,
        query: String
    ) -> NativeJobListState {
        let nonArchived = items.filter { !$0.isArchived }
        let archivedCount = items.count - nonArchived.count
        let declinedCount = count(.declined, in: items)
        let effectiveFilter: NativeJobListFilter =
            (selectedFilter == .declined && declinedCount == 0)
            || (selectedFilter == .archived && archivedCount == 0)
            ? .active
            : selectedFilter

        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let visible = items
            .filter { matches($0, filter: effectiveFilter) }
            .filter { normalizedQuery.isEmpty || matchesSearch($0, query: normalizedQuery) }
            .sorted {
                if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
                return $0.id < $1.id
            }

        let openEstimates = nonArchived.filter { ["lead", "estimate_sent"].contains($0.status) }
        let stats = NativeJobListStats(
            // This intentionally mirrors the React Native stat: completed and
            // declined work still counts until it is invoiced, paid, or archived.
            activeCount: nonArchived.filter { !["paid", "invoiced"].contains($0.status) }.count,
            openEstimateCount: openEstimates.count,
            pendingValue: cents(openEstimates.reduce(0) { $0 + $1.billableTotal })
        )

        let summaries = NativeJobListFilter.allCases.compactMap { filter -> NativeJobListFilterSummary? in
            let value = count(filter, in: items)
            if (filter == .declined || filter == .archived) && value == 0 { return nil }
            return .init(filter: filter, count: value)
        }

        return NativeJobListState(
            items: visible,
            filters: summaries,
            effectiveFilter: effectiveFilter,
            stats: stats,
            nonArchivedCount: nonArchived.count
        )
    }

    static func quickActionLabel(status: String) -> String? {
        switch status {
        case "lead": "Build estimate →"
        case "estimate_sent": "Mark approved →"
        case "approved": "Schedule →"
        case "scheduled": "Start job →"
        case "in_progress": "Mark complete →"
        case "complete": "Create invoice →"
        case "invoiced": "View invoice →"
        case "paid": "View details"
        case "declined": "Revise & re-send →"
        default: nil
        }
    }

    private static func count(_ filter: NativeJobListFilter, in items: [NativeJobListItem]) -> Int {
        items.filter { matches($0, filter: filter) }.count
    }

    private static func matches(_ item: NativeJobListItem, filter: NativeJobListFilter) -> Bool {
        if filter == .archived { return item.isArchived }
        guard !item.isArchived else { return false }
        guard let statuses = filter.statuses else { return true }
        return statuses.contains(item.status)
    }

    private static func matchesSearch(_ item: NativeJobListItem, query: String) -> Bool {
        item.title.localizedCaseInsensitiveContains(query)
            || item.customerName.localizedCaseInsensitiveContains(query)
    }

    private static func cents(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }

    private static func cents(_ value: Decimal) -> Decimal {
        let text = NSDecimalNumber(decimal: value).stringValue
        guard let source = Double(text), source.isFinite else { return 0 }
        let rounded = floor(source * 100 + 0.5) / 100
        return Decimal(string: String(rounded), locale: Locale(identifier: "en_US_POSIX")) ?? 0
    }
}
