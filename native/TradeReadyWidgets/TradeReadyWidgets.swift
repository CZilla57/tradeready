import SwiftUI
import WidgetKit

// Task 11.01 (W1): the TradeReadyWidgets extension entry point.
//
// Target membership (task 11.01 execution log, plan §7): every file in
// `native/TradeReadyWidgets/` compiles into the extension ONLY; every file in
// `native/TradeReadyNative/Widgets/Shared/` compiles into BOTH the extension
// and the app. Neither needs a project-file edit when a file is added.
//
// PLACEHOLDER: a WidgetBundle must contain at least one widget for the target
// to build, so this file ships `TradeReadyPlaceholderWidget`. It shows no
// account data. 11.02 (Next Job) and 11.03 (Job Timer) replace it with their
// widgets in the bundle body below and delete the placeholder.

@main
struct TradeReadyWidgets: WidgetBundle {
    var body: some Widget {
        TradeReadyPlaceholderWidget()
    }
}

// MARK: - Placeholder (replaced by 11.02/11.03)

struct TradeReadyPlaceholderEntry: TimelineEntry {
    let date: Date
    /// Whether the app has mirrored an owner-tagged snapshot. Only this bit
    /// is shown; no customer, job or amount reaches the placeholder.
    let hasOwnedSnapshot: Bool
}

struct TradeReadyPlaceholderProvider: TimelineProvider {
    func placeholder(in context: Context) -> TradeReadyPlaceholderEntry {
        TradeReadyPlaceholderEntry(date: Date(), hasOwnedSnapshot: false)
    }

    func getSnapshot(in context: Context, completion: @escaping (TradeReadyPlaceholderEntry) -> Void) {
        completion(currentEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TradeReadyPlaceholderEntry>) -> Void) {
        // The app reloads timelines after every mirror write and wipe.
        completion(Timeline(entries: [currentEntry()], policy: .never))
    }

    private func currentEntry() -> TradeReadyPlaceholderEntry {
        let snapshot = WidgetSnapshot.load(from: WidgetAppGroup.liveDefaults())
        return TradeReadyPlaceholderEntry(date: Date(), hasOwnedSnapshot: snapshot?.ownerTag != nil)
    }
}

struct TradeReadyPlaceholderView: View {
    let entry: TradeReadyPlaceholderEntry

    var body: some View {
        VStack(spacing: 4) {
            Text("TradeReady")
                .font(.headline)
            Text(entry.hasOwnedSnapshot ? "Open the app to see your day" : "Open TradeReady and sign in")
                .font(.caption)
                .multilineTextAlignment(.center)
        }
        .containerBackground(for: .widget) { Color(.systemBackground) }
    }
}

struct TradeReadyPlaceholderWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "TradeReadyPlaceholderWidget", provider: TradeReadyPlaceholderProvider()) { entry in
            TradeReadyPlaceholderView(entry: entry)
        }
        .configurationDisplayName("TradeReady")
        .description("Placeholder until the Next Job and Job Timer widgets ship.")
        .supportedFamilies([.systemSmall])
    }
}
