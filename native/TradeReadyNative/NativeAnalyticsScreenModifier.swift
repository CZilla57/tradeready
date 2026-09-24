import SwiftUI

/// Task 11.08 (contract §9.3): reports a screen view each time the view
/// appears. The view layer only names its destination and forwards its
/// appear/disappear callbacks: `NativeAnalyticsScreenAppearance` decides which
/// `onAppear` is a real appearance, and `AppStore.trackScreen` owns the RN
/// route-name mapping and the transport, so no analytics policy lives here.
private struct NativeAnalyticsScreenModifier: ViewModifier {
    @EnvironmentObject private var store: AppStore
    @State private var appearance = NativeAnalyticsScreenAppearance()
    let destination: NativeAnalyticsScreen

    func body(content: Content) -> some View {
        content
            .onAppear {
                if appearance.appear() { store.trackScreen(destination) }
            }
            .onDisappear { appearance.disappear() }
    }
}

extension View {
    func nativeAnalyticsScreen(_ destination: NativeAnalyticsScreen) -> some View {
        modifier(NativeAnalyticsScreenModifier(destination: destination))
    }
}
