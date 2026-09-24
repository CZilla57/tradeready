import SwiftUI
import WidgetKit

// Task 11.02 (W2): the Next Job widget's provider, timeline and
// `WidgetConfiguration`. Extension-only root (11.01 §7 placement rule) — its
// provider/timeline logic wires WidgetKit's protocol to the pure policy in
// `N/Widgets/Shared/NextJobWidgetPolicy.swift` and the rendering in
// `N/Widgets/Shared/NextJobWidgetView.swift`. No state resolution, URL
// building or timeline-date math happens in this file.
//
// Contract: docs/native-phase-11-platform-hardening-contract-decisions.md
// §3.3 (stale/empty states, timeline entry), §6.1 (deep-link grammar).
// Registered in the bundle in `TradeReadyWidgets.swift`, replacing the 11.01
// placeholder.

struct NextJobEntry: TimelineEntry {
    let date: Date
    let state: NextJobWidgetState
    let isPlaceholder: Bool
}

private extension WidgetSnapshot.NextJob {
    /// Placeholder-only sample (redacted in the view). Never real account
    /// data — matches the RN widget's gallery/preview sample
    /// (`targets/widget/Widgets.swift:49-56`).
    static let sample = WidgetSnapshot.NextJob(
        id: "sample",
        customerName: "Alex Morgan",
        title: "Water heater replacement",
        scheduledDate: "2026-01-01",
        scheduledStartTime: "09:00",
        address: "1420 Maple Ave"
    )
}

struct NextJobProvider: TimelineProvider {
    func placeholder(in context: Context) -> NextJobEntry {
        NextJobEntry(date: Date(), state: .job(.sample), isPlaceholder: true)
    }

    func getSnapshot(in context: Context, completion: @escaping (NextJobEntry) -> Void) {
        if context.isPreview {
            completion(NextJobEntry(date: Date(), state: .job(.sample), isPlaceholder: true))
        } else {
            completion(currentEntry())
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NextJobEntry>) -> Void) {
        let now = Date()
        let snapshot = WidgetSnapshot.load(from: WidgetAppGroup.liveDefaults())
        let entry = NextJobEntry(
            date: now,
            state: NextJobWidgetPolicy.resolveState(snapshot: snapshot, now: now),
            isPlaceholder: false
        )
        let refreshDate = NextJobWidgetPolicy.nextRefreshDate(snapshot: snapshot, now: now)
        // No self-scheduled background work (11.02 brief): either the single
        // OS-driven refresh date above, or `.never` — the app's own mirror
        // write calls `WidgetCenter.shared.reloadAllTimelines()` (§3.1).
        let policy: TimelineReloadPolicy = refreshDate.map { .after($0) } ?? .never
        completion(Timeline(entries: [entry], policy: policy))
    }

    private func currentEntry() -> NextJobEntry {
        let now = Date()
        let snapshot = WidgetSnapshot.load(from: WidgetAppGroup.liveDefaults())
        return NextJobEntry(
            date: now,
            state: NextJobWidgetPolicy.resolveState(snapshot: snapshot, now: now),
            isPlaceholder: false
        )
    }
}

struct NextJobWidgetEntryView: View {
    var entry: NextJobEntry

    var body: some View {
        NextJobWidgetView(state: entry.state, now: entry.date, isPlaceholder: entry.isPlaceholder)
    }
}

struct NextJobWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "NextJobWidget", provider: NextJobProvider()) { entry in
            NextJobWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Next Job")
        .description("Your next scheduled job at a glance.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
