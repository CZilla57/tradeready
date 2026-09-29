import SwiftUI

/// Phase 12 (L286.4): the manual retry for a pending switch/recovery boundary
/// step (the widget App Group wipe or the AI-key wipe). Unlike the full-screen
/// "Sign-out cleanup paused" state (a pending account scrub), the app stays
/// usable: each step's own gates keep the previous account's data closed
/// until it succeeds. `RootView` shows it above every authentication gate,
/// including sign-in, where the next owner would otherwise first meet it.
struct NativeAccountCleanupBanner: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        if store.isAccountBoundaryCleanupPending {
            VStack(alignment: .leading, spacing: 6) {
                Label("Account cleanup paused", systemImage: "person.crop.circle.badge.xmark")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.tradeWarningText)
                // Primary text: `.secondary` on the warning wash is not a
                // proven contrast pairing (11.10b); the title's
                // `tradeWarningText` on its ≤13% wash is.
                Text("TradeReady is keeping the previous account's data hidden until it can finish removing it safely.")
                    .font(.footnote)
                    .fixedSize(horizontal: false, vertical: true)
                // Regular control size: the banner's only action keeps the
                // full-size target of the "Sign-out cleanup paused" retry.
                Button("Try cleanup again") { store.retryAccountScrub() }
                    .font(.subheadline.weight(.semibold))
                    .tradeReadyProminentButtonStyle()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .nativeContentColumnFrame()
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(Color.tradeWarningText.opacity(0.12))
            .overlay(alignment: .bottom) { Divider() }
            .accessibilityElement(children: .contain)
        }
    }
}
