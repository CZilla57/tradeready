import SwiftUI
import WidgetKit

// Task 11.03 (W3): the Job Timer widget's provider, timeline and
// `WidgetConfiguration`. Extension-only root (11.01 §7 placement rule) — its
// provider/timeline logic wires WidgetKit's protocol to the pure policy in
// `N/Widgets/Shared/JobTimerWidgetPolicy.swift` and the rendering in
// `N/Widgets/Shared/JobTimerWidgetView.swift`. No state resolution, URL
// building or timeline-date math happens in this file.
//
// Contract: docs/native-phase-11-platform-hardening-contract-decisions.md
// §3.3 (stale/running/idle/no-job states), §4.5 (owner-tagged pending-action
// precedence), §6.1 (deep-link grammar). Registered in the bundle in
// `TradeReadyWidgets.swift`, alongside 11.02's `NextJobWidget`.

struct JobTimerEntry: TimelineEntry {
    let date: Date
    let state: JobTimerWidgetState
    let isPlaceholder: Bool
}

private extension WidgetSnapshot.TimerState {
    /// Placeholder-only sample (redacted in the view). Never real account
    /// data — matches the RN widget's gallery/preview sample
    /// (`targets/widget/JobTimer.swift`'s `BridgeSnapshot.TimerState.sample`).
    static let sample = WidgetSnapshot.TimerState(
        jobId: "sample",
        jobTitle: "Water heater replacement",
        customerName: "Alex Morgan",
        startedAt: "2026-01-01T09:00:00.000Z"
    )
}

struct JobTimerProvider: TimelineProvider {
    func placeholder(in context: Context) -> JobTimerEntry {
        JobTimerEntry(
            date: Date(),
            state: .running(.sample, since: Date().addingTimeInterval(-45 * 60)),
            isPlaceholder: true
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (JobTimerEntry) -> Void) {
        if context.isPreview {
            completion(placeholder(in: context))
        } else {
            completion(currentEntry())
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<JobTimerEntry>) -> Void) {
        let now = Date()
        let snapshot = WidgetSnapshot.load(from: WidgetAppGroup.liveDefaults())
        let entry = currentEntry(snapshot: snapshot, now: now)
        let refreshDate = JobTimerWidgetPolicy.nextRefreshDate(snapshot: snapshot, now: now)
        // No self-scheduled background work: either the single OS-driven
        // refresh date above, or `.never` — a button tap (via
        // `WidgetIntentTimelines.reloadIfNeeded`) or the app's own mirror
        // write calls `WidgetCenter.shared.reloadAllTimelines()`. The live
        // elapsed time itself needs no new entry (`Text(_:style:.timer)`).
        let policy: TimelineReloadPolicy = refreshDate.map { .after($0) } ?? .never
        completion(Timeline(entries: [entry], policy: policy))
    }

    private func currentEntry() -> JobTimerEntry {
        currentEntry(snapshot: WidgetSnapshot.load(from: WidgetAppGroup.liveDefaults()), now: Date())
    }

    private func currentEntry(snapshot: WidgetSnapshot?, now: Date) -> JobTimerEntry {
        let queueJSON = WidgetAppGroup.liveDefaults()?.string(forKey: WidgetAppGroup.actionsKey)
        let state = JobTimerWidgetPolicy.resolveState(
            snapshot: snapshot, pendingActionsJSON: queueJSON, now: now
        )
        return JobTimerEntry(date: now, state: state, isPlaceholder: false)
    }
}

struct JobTimerWidgetEntryView: View {
    var entry: JobTimerEntry

    var body: some View {
        JobTimerWidgetView(state: entry.state, now: entry.date, isPlaceholder: entry.isPlaceholder)
    }
}

struct JobTimerWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "JobTimerWidget", provider: JobTimerProvider()) { entry in
            JobTimerWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Job Timer")
        .description("Clock in and out of the job you're on.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
