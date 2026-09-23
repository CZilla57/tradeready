import Foundation

/// Shared, data-agnostic presentation state for local-first native screens.
/// Existing local content always wins over transient loading or sync errors;
/// background failures belong in the sync banner and must not blank usable data.
enum NativeContentState: Equatable {
    case content
    case loading
    case empty
    case noMatches(query: String)
    case error

    static func collection(
        visibleCount: Int,
        totalCount: Int,
        query: String = "",
        isFiltering: Bool = false,
        isLoading: Bool = false,
        hasError: Bool = false
    ) -> NativeContentState {
        if visibleCount > 0 { return .content }
        if isLoading { return .loading }
        if hasError { return .error }

        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if totalCount > 0, !trimmedQuery.isEmpty || isFiltering {
            return .noMatches(query: trimmedQuery)
        }
        return .empty
    }
}

#if !NATIVE_INTERACTION_PURE_TESTS
import SwiftUI

/// One reusable loading/empty/no-results/error surface. Callers provide only
/// feature-specific copy and recovery actions; the visual hierarchy stays
/// consistent across customer, job, invoice, and search screens.
struct NativeContentStateView: View {
    let state: NativeContentState
    let emptyTitle: String
    let emptyMessage: String
    let symbol: String
    var loadingMessage = "Loading…"
    var errorTitle = "Unable to load"
    var errorMessage = "Your saved data is still safe. Try again when you're ready."
    var retryTitle = "Try again"
    var resetAction: (() -> Void)?
    var retryAction: (() -> Void)?
    var secondaryActionTitle: String?
    var secondaryAction: (() -> Void)?

    @ViewBuilder
    var body: some View {
        switch state {
        case .content:
            EmptyView()
        case .loading:
            ProgressView(loadingMessage)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel(loadingMessage)
        case .empty:
            ContentUnavailableView(
                emptyTitle,
                systemImage: symbol,
                description: Text(emptyMessage)
            )
        case .noMatches(let query):
            ContentUnavailableView {
                Label("No matches", systemImage: "magnifyingglass")
            } description: {
                Text(noMatchesMessage(query: query))
            } actions: {
                if let resetAction {
                    Button("Clear search and filters", action: resetAction)
                        .buttonStyle(.borderedProminent)
                }
            }
        case .error:
            ContentUnavailableView {
                Label(errorTitle, systemImage: symbol)
            } description: {
                Text(errorMessage)
            } actions: {
                if let retryAction {
                    Button(retryTitle, action: retryAction)
                        .buttonStyle(.borderedProminent)
                }
                if let secondaryActionTitle, let secondaryAction {
                    Button(secondaryActionTitle, action: secondaryAction)
                        .buttonStyle(.bordered)
                }
            }
        }
    }

    private func noMatchesMessage(query: String) -> String {
        query.isEmpty
            ? "No items match the selected filters."
            : "No results for \(query)."
    }
}
#endif
