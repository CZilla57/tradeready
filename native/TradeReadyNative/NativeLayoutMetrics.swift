import Foundation

/// Task 11.11 (H2): the native analog of RN `layout.contentColumn`
/// (`utils/theme.ts`: `{ width: "100%", maxWidth: 700, alignSelf: "center" }`).
///
/// List, form and scroll screens keep their scroll area and background full
/// width, and center their content in a column of at most
/// `contentMaxWidth` points. Below that width the column is the full width,
/// exactly as RN's `width: "100%"` does on a phone, in Slide Over and in a
/// narrow Split View.
///
/// The policy is width-only. It never reads the size class, so a regular-width
/// window narrower than the column (an iPad mini half split, a Stage Manager
/// window) is not capped, and a compact-height landscape phone wider than the
/// column is. Every size class keeps the one `TabView` from `RootView`; no
/// size class switches to a split view (RN is a phone-style tab app on iPad).
///
/// Foundation-only: the width math is covered by
/// `native/LayoutMetricsTests/main.swift`. The SwiftUI modifiers below are
/// compiled only where UIKit exists (the app), not in the host test.
enum NativeLayoutMetrics {
    /// RN `layout.contentMaxWidth` (points).
    static let contentMaxWidth: Double = 700

    /// The smallest side inset an inset-grouped `List`/`Form` keeps outside the
    /// safe area once the column takes over. It is the system's regular-width
    /// row margin, so the row edge does not jump when the column engages.
    static let listMinimumSideInset: Double = 20

    /// Which scroll container the column is applied to. SwiftUI measures the
    /// two differently (measured on the iOS Simulator, 2026-09-24):
    /// - `.list` (`List`, `Form`): `contentMargins(.horizontal, m, for:
    ///   .scrollContent)` *replaces* the row inset and is measured from the
    ///   container's outer edge; the row edge lands at `max(safe-area inset, m)`.
    /// - `.scroll` (`ScrollView`): the margin is *added* inside the safe area,
    ///   and the content keeps its own padding inside the column (as RN's
    ///   `paddingHorizontal` sits inside `contentColumn`).
    enum Container: String, CaseIterable {
        case list
        case scroll
    }

    /// A scroll container's measured size, in points.
    struct Geometry: Equatable {
        /// The container's width inside its safe area (`GeometryProxy.size`).
        var width: Double
        var leadingSafeArea: Double
        var trailingSafeArea: Double

        init(width: Double, leadingSafeArea: Double = 0, trailingSafeArea: Double = 0) {
            self.width = width
            self.leadingSafeArea = leadingSafeArea
            self.trailingSafeArea = trailingSafeArea
        }

        static let zero = Geometry(width: 0)

        /// The container's full width, safe areas included.
        var outerWidth: Double { width + leadingSafeArea + trailingSafeArea }

        fileprivate var isUsable: Bool {
            [width, leadingSafeArea, trailingSafeArea].allSatisfy { $0.isFinite && $0 >= 0 } && width > 0
        }
    }

    /// The horizontal scroll-content margin that centers a `contentMaxWidth`
    /// column, or `nil` to keep the system default (the container is not
    /// wider than the column).
    static func horizontalContentMargin(for container: Container, in geometry: Geometry) -> Double? {
        guard geometry.isUsable else { return nil }
        switch container {
        case .scroll:
            guard geometry.width > contentMaxWidth else { return nil }
            return (geometry.width - contentMaxWidth) / 2
        case .list:
            let margin = (geometry.outerWidth - contentMaxWidth) / 2
            let floor = max(geometry.leadingSafeArea, geometry.trailingSafeArea) + listMinimumSideInset
            return margin >= floor ? margin : nil
        }
    }

    /// The width of the centered column the margin produces, or `nil` when the
    /// system default applies (the content spans the container, less the
    /// system row inset for a list).
    static func columnWidth(for container: Container, in geometry: Geometry) -> Double? {
        guard let margin = horizontalContentMargin(for: container, in: geometry) else { return nil }
        switch container {
        case .scroll: return geometry.width - 2 * margin
        case .list: return geometry.outerWidth - 2 * margin
        }
    }
}

#if canImport(UIKit)
import SwiftUI

extension View {
    /// Applies RN's `layout.contentColumn` to a scroll container: the scroll
    /// area and background stay full width, and the content is centered in a
    /// `NativeLayoutMetrics.contentMaxWidth` column. Put it directly on the
    /// `List`, `Form` or `ScrollView` of a screen root.
    func nativeContentColumn(_ container: NativeLayoutMetrics.Container) -> some View {
        modifier(NativeContentColumnModifier(container: container))
    }

    /// The same column for non-scrolling chrome (a composer, a header control,
    /// a bottom bar): the content is capped and centered, and any background
    /// applied after it stays full width.
    func nativeContentColumnFrame() -> some View {
        frame(maxWidth: CGFloat(NativeLayoutMetrics.contentMaxWidth))
            .frame(maxWidth: .infinity)
    }
}

private struct NativeContentColumnModifier: ViewModifier {
    let container: NativeLayoutMetrics.Container
    @State private var geometry = NativeLayoutMetrics.Geometry.zero

    func body(content: Content) -> some View {
        content
            .contentMargins(
                .horizontal,
                NativeLayoutMetrics.horizontalContentMargin(for: container, in: geometry).map { CGFloat($0) },
                for: .scrollContent
            )
            .onGeometryChange(for: NativeLayoutMetrics.Geometry.self) { proxy in
                NativeLayoutMetrics.Geometry(
                    width: Double(proxy.size.width),
                    leadingSafeArea: Double(proxy.safeAreaInsets.leading),
                    trailingSafeArea: Double(proxy.safeAreaInsets.trailing)
                )
            } action: { geometry = $0 }
    }
}
#endif
