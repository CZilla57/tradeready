import WidgetKit
import SwiftUI

// TradeReady home-screen widgets (docs/widget-plan.md Phase 2).
// Reads the snapshot that utils/widgetBridge.ts mirrors into the App Group
// container — field names here must match the WidgetSnapshot interface there.

private let appGroupId = "group.com.gettradereadyapp.tradeready"
private let snapshotKey = "widgetSnapshot"

struct BridgeSnapshot: Decodable {
  var version: Int
  var updatedAt: String
  var nextJob: NextJob?
  var timer: TimerState?
  var outstandingTotal: Double?

  struct NextJob: Decodable {
    var id: String
    var customerName: String
    var title: String
    var scheduledDate: String
    var scheduledStartTime: String?
    var address: String
  }

  struct TimerState: Decodable {
    var jobId: String
    var jobTitle: String
    var customerName: String
    var startedAt: String
  }
}

func loadSnapshot() -> BridgeSnapshot? {
  guard
    let defaults = UserDefaults(suiteName: appGroupId),
    let json = defaults.string(forKey: snapshotKey),
    let data = json.data(using: .utf8)
  else { return nil }
  return try? JSONDecoder().decode(BridgeSnapshot.self, from: data)
}

// MARK: - Display helpers

extension BridgeSnapshot.NextJob {
  static let sample = BridgeSnapshot.NextJob(
    id: "sample",
    customerName: "Alex Morgan",
    title: "Water heater replacement",
    scheduledDate: "2026-01-01",
    scheduledStartTime: "09:00",
    address: "1420 Maple Ave"
  )

  // scheduledDate is a local-frame "yyyy-MM-dd" (+ optional "HH:mm") string —
  // parse it in the device's local calendar, same frame the app wrote it in.
  var startDate: Date? {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone.current
    if let time = scheduledStartTime {
      formatter.dateFormat = "yyyy-MM-dd HH:mm"
      return formatter.date(from: "\(scheduledDate) \(time)")
    }
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.date(from: scheduledDate)
  }

  var whenLabel: String {
    guard let start = startDate else { return scheduledDate }
    let calendar = Calendar.current

    let dayLabel: String
    if calendar.isDateInToday(start) {
      dayLabel = "Today"
    } else if calendar.isDateInTomorrow(start) {
      dayLabel = "Tomorrow"
    } else {
      let dayFormatter = DateFormatter()
      dayFormatter.dateFormat = "EEE, MMM d"
      dayLabel = dayFormatter.string(from: start)
    }

    if scheduledStartTime != nil {
      let timeFormatter = DateFormatter()
      timeFormatter.dateStyle = .none
      timeFormatter.timeStyle = .short
      return "\(dayLabel) \u{00B7} \(timeFormatter.string(from: start))"
    }
    return dayLabel
  }
}

// MARK: - Next Job widget

struct NextJobEntry: TimelineEntry {
  let date: Date
  let job: BridgeSnapshot.NextJob?
  let isPlaceholder: Bool
}

struct NextJobProvider: TimelineProvider {
  func placeholder(in context: Context) -> NextJobEntry {
    NextJobEntry(date: Date(), job: .sample, isPlaceholder: true)
  }

  func getSnapshot(in context: Context, completion: @escaping (NextJobEntry) -> Void) {
    if context.isPreview {
      completion(NextJobEntry(date: Date(), job: .sample, isPlaceholder: true))
    } else {
      completion(NextJobEntry(date: Date(), job: loadSnapshot()?.nextJob, isPlaceholder: false))
    }
  }

  func getTimeline(in context: Context, completion: @escaping (Timeline<NextJobEntry>) -> Void) {
    let entry = NextJobEntry(date: Date(), job: loadSnapshot()?.nextJob, isPlaceholder: false)
    // The app reloads timelines on every mirror write; refresh at the next day
    // boundary anyway so the "Today"/"Tomorrow" labels can't go stale overnight.
    let nextMidnight = Calendar.current.startOfDay(for: Date()).addingTimeInterval(24 * 60 * 60)
    completion(Timeline(entries: [entry], policy: .after(nextMidnight)))
  }
}

// TradeReady ink navy (#0c335e), the blueprint brand ground.
private let inkNavy = Color(red: 12 / 255, green: 51 / 255, blue: 94 / 255)

struct NextJobView: View {
  @Environment(\.widgetFamily) private var family
  var entry: NextJobEntry

  var body: some View {
    Group {
      if let job = entry.job {
        VStack(alignment: .leading, spacing: 3) {
          Text("NEXT JOB")
            .font(.system(size: 10, weight: .semibold))
            .kerning(1.2)
            .foregroundColor(.white.opacity(0.55))
          Text(job.whenLabel)
            .font(.system(size: family == .systemSmall ? 15 : 17, weight: .bold))
            .foregroundColor(.white)
            .minimumScaleFactor(0.7)
            .lineLimit(1)
          Text(job.customerName)
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(.white.opacity(0.9))
            .lineLimit(1)
          Text(job.title)
            .font(.system(size: 12))
            .foregroundColor(.white.opacity(0.7))
            .lineLimit(family == .systemSmall ? 2 : 1)
          if family != .systemSmall && !job.address.isEmpty {
            Spacer(minLength: 2)
            HStack(spacing: 4) {
              Image(systemName: "mappin.and.ellipse")
                .font(.system(size: 11))
              Text(job.address)
                .font(.system(size: 12))
                .lineLimit(1)
            }
            .foregroundColor(.white.opacity(0.7))
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .redacted(reason: entry.isPlaceholder ? .placeholder : [])
        .widgetURL(URL(string: "tradeready://job/\(job.id)"))
      } else {
        VStack(spacing: 4) {
          Image(systemName: "calendar.badge.checkmark")
            .font(.system(size: 22))
            .foregroundColor(.white.opacity(0.6))
          Text("No upcoming jobs")
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(.white.opacity(0.75))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .containerBackground(for: .widget) { inkNavy }
  }
}

struct NextJobWidget: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(kind: "NextJobWidget", provider: NextJobProvider()) { entry in
      NextJobView(entry: entry)
    }
    .configurationDisplayName("Next Job")
    .description("Your next scheduled job at a glance.")
    .supportedFamilies([.systemSmall, .systemMedium])
  }
}

@main
struct TradeReadyWidgets: WidgetBundle {
  var body: some Widget {
    NextJobWidget()
  }
}
