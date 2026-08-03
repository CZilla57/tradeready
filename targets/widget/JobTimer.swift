import AppIntents
import Foundation
import SwiftUI
import WidgetKit

// Job Timer widget (docs/widget-plan.md Phase 3) — the interactive half of the
// widget leg. Sibling of Widgets.swift: that file owns BridgeSnapshot,
// loadSnapshot() and the read-only Next Job widget; this one owns the
// pending-action queue writer, the two timer App Intents, and the timer widget.
//
// The extension is NEVER the writer of real data. Buttons here only append a
// PendingAction to the App Group container; the app replays the batch through
// its normal save paths on next launch/foreground (utils/widgetActions.ts) and
// re-mirrors the snapshot. Until that happens the widget shows the pending
// state optimistically ("Starting…" / "Clocked out") rather than lying about
// the timer.

// Local copies of the container coordinates: the equivalents in Widgets.swift
// are file-private, so these are separate declarations, not redeclarations.
// Must stay in sync with app.json ios.entitlements, expo-target.config.js and
// utils/widgetBridge.ts (WIDGET_ACTIONS_KEY).
private let timerAppGroupId = "group.com.gettradereadyapp.tradeready"
private let widgetActionsKey = "widgetActions"

// MARK: - Pending action queue

/// Append one PendingAction dict to the shared `widgetActions` queue.
/// Shape (docs/widget-plan.md Phase 3-4 contract):
/// `{ id, type, at, jobId? }` — JS drops anything missing id/type/at.
/// A malformed/absent queue is treated as empty, exactly like the JS parser.
/// Internal on purpose: the Phase-4 Siri intents append through this too.
func appendPendingAction(_ action: [String: Any]) {
  guard let defaults = UserDefaults(suiteName: timerAppGroupId) else { return }

  var queue: [[String: Any]] = []
  if let raw = defaults.string(forKey: widgetActionsKey),
     let data = raw.data(using: .utf8),
     let parsed = try? JSONSerialization.jsonObject(with: data, options: []),
     let existing = parsed as? [[String: Any]] {
    queue = existing
  }
  queue.append(action)

  guard
    let encoded = try? JSONSerialization.data(withJSONObject: queue, options: []),
    let json = String(data: encoded, encoding: .utf8)
  else { return }

  defaults.set(json, forKey: widgetActionsKey)
  WidgetCenter.shared.reloadAllTimelines()
}

/// The type of the most recent queued timer action, or nil when none is
/// waiting. Last one wins: a start followed by a stop reads as a stop, which
/// is what the user last asked for.
private func lastPendingTimerType() -> String? {
  guard
    let defaults = UserDefaults(suiteName: timerAppGroupId),
    let raw = defaults.string(forKey: widgetActionsKey),
    let data = raw.data(using: .utf8),
    let parsed = try? JSONSerialization.jsonObject(with: data, options: []),
    let entries = parsed as? [[String: Any]]
  else { return nil }

  var last: String?
  for entry in entries {
    guard let type = entry["type"] as? String else { continue }
    if type == "timer_start" || type == "timer_stop" {
      last = type
    }
  }
  return last
}

/// Parse an ISO 8601 instant. `timer.startedAt` comes from JS
/// `new Date().toISOString()`, which ALWAYS carries fractional seconds — and a
/// default ISO8601DateFormatter rejects those outright. Try the fractional
/// parser first, then plain (what this file's own intents write).
private func parseISODate(_ value: String) -> Date? {
  let fractional = ISO8601DateFormatter()
  fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  if let date = fractional.date(from: value) {
    return date
  }
  let plain = ISO8601DateFormatter()
  return plain.date(from: value)
}

// MARK: - Intents

struct StartTimerIntent: AppIntent {
  // `static let` (not `var`) satisfies AppIntent's get-only requirement and
  // stays concurrency-safe if the target ever moves to the Swift 6 mode.
  static let title: LocalizedStringResource = "Start Job Timer"

  // Widget-button-only: this intent takes a raw job id, which is meaningless
  // to type into a Shortcuts action. Hiding it from Shortcuts/Spotlight does
  // not affect Button(intent:) invocation. The Siri-facing intents live in
  // _shared/SiriIntents.swift and stay discoverable.
  static let isDiscoverable: Bool = false

  @Parameter(title: "Job ID")
  var jobId: String

  init() {
    jobId = ""
  }

  init(jobId: String) {
    self.jobId = jobId
  }

  func perform() async throws -> some IntentResult {
    // No job id means nothing the app could replay — drop it silently rather
    // than queue an action the JS side would only throw away.
    if !jobId.isEmpty {
      appendPendingAction([
        "id": UUID().uuidString,
        "type": "timer_start",
        "jobId": jobId,
        "at": ISO8601DateFormatter().string(from: Date()),
      ])
    }
    return .result()
  }
}

struct StopTimerIntent: AppIntent {
  static let title: LocalizedStringResource = "Stop Job Timer"

  // Widget-button-only, same reasoning as StartTimerIntent above.
  static let isDiscoverable: Bool = false

  @Parameter(title: "Job ID")
  var jobId: String

  init() {
    jobId = ""
  }

  init(jobId: String) {
    self.jobId = jobId
  }

  func perform() async throws -> some IntentResult {
    var action: [String: Any] = [
      "id": UUID().uuidString,
      "type": "timer_stop",
      "at": ISO8601DateFormatter().string(from: Date()),
    ]
    // Omitted when unknown: the app then stops whichever single job is running
    // (applyTimerActions in utils/widgetActions.ts).
    if !jobId.isEmpty {
      action["jobId"] = jobId
    }
    appendPendingAction(action)
    return .result()
  }
}

// MARK: - Timeline

enum JobTimerState {
  /// A session is running per the snapshot, with nothing queued against it.
  case running(timer: BridgeSnapshot.TimerState, since: Date)
  /// A stop is queued — the elapsed time is frozen until the app replays it.
  case pendingStop
  /// A start is queued — the session doesn't exist in app data yet.
  case pendingStart
  /// Nothing running, but there's a job worth clocking into.
  case idle(job: BridgeSnapshot.NextJob)
  /// Nothing running and nothing scheduled.
  case empty
}

struct JobTimerEntry: TimelineEntry {
  let date: Date
  let state: JobTimerState
  let isPlaceholder: Bool
}

extension BridgeSnapshot.TimerState {
  static let sample = BridgeSnapshot.TimerState(
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
      state: .running(
        timer: BridgeSnapshot.TimerState.sample,
        since: Date().addingTimeInterval(-45 * 60)
      ),
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
    // .never: every transition here is driven by a button tap (which reloads
    // timelines) or by the app's own mirror write. Nothing decays with time —
    // Text(_:style:.timer) ticks on its own without new entries.
    completion(Timeline(entries: [currentEntry()], policy: .never))
  }

  private func currentEntry() -> JobTimerEntry {
    let snapshot = loadSnapshot()
    let pending = lastPendingTimerType()

    let state: JobTimerState
    if pending == "timer_stop" {
      state = .pendingStop
    } else if pending == "timer_start" {
      state = .pendingStart
    } else if let timer = snapshot?.timer {
      // An unparseable timestamp shouldn't blank the widget: fall back to now,
      // so the label reads 0:00 and ticks up instead of disappearing.
      state = .running(timer: timer, since: parseISODate(timer.startedAt) ?? Date())
    } else if let job = snapshot?.nextJob {
      state = .idle(job: job)
    } else {
      state = .empty
    }

    return JobTimerEntry(date: Date(), state: state, isPlaceholder: false)
  }
}

// MARK: - View

// Same brand ground as NextJobView; that declaration is file-private, so this
// is a local copy of TradeReady ink navy (#0c335e).
private let inkNavy = Color(red: 12 / 255, green: 51 / 255, blue: 94 / 255)

struct JobTimerView: View {
  @Environment(\.widgetFamily) private var family
  var entry: JobTimerEntry

  var body: some View {
    Group {
      switch entry.state {
      case .running(let timer, let since):
        runningBody(timer: timer, since: since)
      case .pendingStop:
        statusBody(icon: "checkmark.circle", title: "Clocked out", detail: "Open app to sync")
      case .pendingStart:
        statusBody(icon: "hourglass", title: "Starting\u{2026}", detail: "Open app to sync")
      case .idle(let job):
        idleBody(job: job)
      case .empty:
        statusBody(icon: "clock", title: "No job to clock into", detail: nil)
      }
    }
    .redacted(reason: entry.isPlaceholder ? .placeholder : [])
    .containerBackground(for: .widget) { inkNavy }
  }

  private func runningBody(timer: BridgeSnapshot.TimerState, since: Date) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      captionLabel("ON THE CLOCK")
      Text(since, style: .timer)
        // .monospaced so the ticking digits don't reflow the layout every second.
        .font(.system(size: family == .systemSmall ? 26 : 30, weight: .bold, design: .monospaced))
        .foregroundColor(.white)
        .lineLimit(1)
        .minimumScaleFactor(0.6)
      Text(timer.jobTitle)
        .font(.system(size: 13, weight: .semibold))
        .foregroundColor(.white.opacity(0.9))
        .lineLimit(1)
      Text(timer.customerName)
        .font(.system(size: 12))
        .foregroundColor(.white.opacity(0.7))
        .lineLimit(1)
      Spacer(minLength: 4)
      Button(intent: StopTimerIntent(jobId: timer.jobId)) {
        actionLabel(icon: "stop.fill", title: "Stop")
      }
      .buttonStyle(.plain)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .widgetURL(URL(string: "tradeready://job/\(timer.jobId)"))
  }

  private func idleBody(job: BridgeSnapshot.NextJob) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      captionLabel("OFF THE CLOCK")
      Text(job.title)
        .font(.system(size: family == .systemSmall ? 15 : 17, weight: .bold))
        .foregroundColor(.white)
        .minimumScaleFactor(0.7)
        .lineLimit(2)
      Text(job.customerName)
        .font(.system(size: 12))
        .foregroundColor(.white.opacity(0.7))
        .lineLimit(1)
      Spacer(minLength: 4)
      Button(intent: StartTimerIntent(jobId: job.id)) {
        actionLabel(icon: "play.fill", title: "Start")
      }
      .buttonStyle(.plain)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .widgetURL(URL(string: "tradeready://job/\(job.id)"))
  }

  private func statusBody(icon: String, title: String, detail: String?) -> some View {
    VStack(spacing: 4) {
      Image(systemName: icon)
        .font(.system(size: 22))
        .foregroundColor(.white.opacity(0.6))
      Text(title)
        .font(.system(size: 12, weight: .medium))
        .foregroundColor(.white.opacity(0.75))
        .multilineTextAlignment(.center)
        .lineLimit(2)
      if let detail = detail {
        Text(detail)
          .font(.system(size: 11))
          .foregroundColor(.white.opacity(0.55))
          .multilineTextAlignment(.center)
          .lineLimit(1)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private func captionLabel(_ text: String) -> some View {
    Text(text)
      .font(.system(size: 10, weight: .semibold))
      .kerning(1.2)
      .foregroundColor(.white.opacity(0.55))
  }

  private func actionLabel(icon: String, title: String) -> some View {
    HStack(spacing: 5) {
      Image(systemName: icon)
        .font(.system(size: 11, weight: .bold))
      Text(title)
        .font(.system(size: 13, weight: .semibold))
    }
    .foregroundColor(inkNavy)
    .padding(.vertical, 7)
    .frame(maxWidth: family == .systemSmall ? CGFloat.infinity : 140)
    .background(Color.white)
    .clipShape(RoundedRectangle(cornerRadius: 9))
  }
}

struct JobTimerWidget: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(kind: "JobTimerWidget", provider: JobTimerProvider()) { entry in
      JobTimerView(entry: entry)
    }
    .configurationDisplayName("Job Timer")
    .description("Clock in and out of the job you're on.")
    .supportedFamilies([.systemSmall, .systemMedium])
  }
}
