import SwiftUI

/// Task 11.08 (contract §9.3): reports a screen view when the view appears.
/// The view layer only names its destination; `AppStore.trackScreen` owns
/// the RN route-name mapping, the consecutive-duplicate rule and the
/// transport, so no analytics policy lives here.
private struct NativeAnalyticsScreenModifier: ViewModifier {
    @EnvironmentObject private var store: AppStore
    let destination: NativeAnalyticsScreen

    func body(content: Content) -> some View {
        content.onAppear { store.trackScreen(destination) }
    }
}

extension View {
    func nativeAnalyticsScreen(_ destination: NativeAnalyticsScreen) -> some View {
        modifier(NativeAnalyticsScreenModifier(destination: destination))
    }
}
