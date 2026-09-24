import SwiftUI

// MARK: - Accessibility view helpers (task 11.10a, requirement H1)
//
// View-side wrappers only; the policy (palette, contrast, motion, labels) lives
// in `Domain/NativeAccessibilityAudit.swift` and is host-tested by
// `native/AccessibilityAuditTests`.

extension View {
    /// `.borderedProminent` over `tradeReadyFill`. The prominent style draws a
    /// white label on the tint, and the dark-mode tint (RN's `#5b9bdb`) is too
    /// light for white text, so prominent buttons use the fill color instead.
    func tradeReadyProminentButtonStyle() -> some View {
        buttonStyle(.borderedProminent).tint(.tradeReadyFill)
    }
}

/// Columns side by side at standard text sizes; stacked at accessibility sizes
/// (AX1–AX5) so money figures are not squeezed, truncated or split mid-number.
struct NativeAccessibilityAdaptiveRow<Content: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var alignment: VerticalAlignment = .top
    var spacing: CGFloat = 0
    @ViewBuilder var content: Content

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: max(spacing, 8)))
            : AnyLayout(HStackLayout(alignment: alignment, spacing: spacing))
        layout { content }
    }
}

/// The hairline between `NativeAccessibilityAdaptiveRow` columns: vertical when
/// the columns sit side by side, a horizontal divider when they stack.
struct NativeAccessibilityColumnDivider: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var height: CGFloat
    var horizontalPadding: CGFloat = 12

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            Divider()
        } else {
            Rectangle()
                .fill(.quaternary)
                .frame(width: 1, height: height)
                .padding(.horizontal, horizontalPadding)
        }
    }
}
