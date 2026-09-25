import StoreKit
import SwiftUI

/// Asks StoreKit for the rating sheet when the coordinator has a pending
/// request. The short wait lets the payment/estimate sheet finish dismissing so
/// the ask follows the win instead of interrupting it. The coordinator stamps
/// the request only if the app is still in the foreground when the wait ends,
/// so a backgrounded or cancelled wait costs nothing.
struct NativeAppRatingPromptPresenter: ViewModifier {
    @ObservedObject var coordinator: NativeAppRatingPromptCoordinator
    @Environment(\.requestReview) private var requestReview
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content.task(id: coordinator.isRequestPending) {
            guard coordinator.isRequestPending else { return }
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, scenePhase == .active, coordinator.beginPresentation() else { return }
            requestReview()
        }
    }
}
