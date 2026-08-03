import AppIntents
import Foundation
import WidgetKit

// Siri App Intents — Tier 1 (docs/widget-plan.md Phase 4).
//
// WHY THIS FILE LIVES IN `_shared/` AND NOT NEXT TO THE WIDGETS
// ------------------------------------------------------------
// Apple DTS is explicit: "the AppShortcutsProvider needs to be in the main app
// target, and the app intents declared by this provider also need to be in the
// same target" (developer.apple.com/forums/thread/759160). A WidgetKit
// extension is not an App Intents extension, so a provider that only ships
// inside the .appex is not registered — the phrases would never reach Siri.
// @bacons/apple-targets links every file under `targets/<name>/_shared/` into
// BOTH the main app target and the widget target, which is exactly the layout
// its README prescribes for App Intents. So this one file compiles twice:
// once into TradeReady.app (where Siri finds it) and once into the widget
// extension (harmless — nothing here is invoked from a widget).
//
// CONSEQUENCES OF COMPILING INTO THE APP TARGET
//  * The app's deployment target is iOS 15.1 (React Native's floor) while
//    AppIntents starts at iOS 16 — every AppIntents type below carries
//    @available. They all carry the SAME floor (17.0, matching the widget
//    extension's deployment target) on purpose: mixed availability inside one
//    AppShortcutsProvider is the documented crash pattern
//    (developer.apple.com/forums/thread/747409), and `shortTitle:` on
//    AppShortcut needs 16.4 anyway.
//  * Nothing here may reference widget UI or the sibling files' symbols —
//    Widgets.swift/JobTimer.swift are widget-target-only, so `loadSnapshot()`
//    and `appendPendingAction(_:)` do not exist in the app target. The small
//    helpers below are deliberate duplicates with `siri`-prefixed names, so
//    the widget target (which has both copies) sees no redeclaration.
//
// Like the widget buttons, these intents are NEVER the writer of real data:
// they append a PendingAction to the App Group container and the app replays
// the batch through its normal save paths (utils/widgetActions.ts). The one
// exception is `activeTrip`, which is Siri's own private session state — a
// half-finished trip the app must never see.

// MARK: - Shared container coordinates

// Must stay in sync with app.json ios.entitlements, expo-target.config.js and
// utils/widgetBridge.ts. Sign-out wipes the whole suite via
// removePersistentDomain (WidgetBridgeModule.clearShared), which covers
// `activeTrip` too — no per-key wipe needed.
private let siriAppGroupId = "group.com.gettradereadyapp.tradeready"
private let siriSnapshotKey = "widgetSnapshot"
private let siriActionsKey = "widgetActions"
private let siriActiveTripKey = "activeTrip"

// MARK: - Snapshot read

/// The slice of `widgetSnapshot` these intents speak aloud. Decoding only the
/// fields we use keeps this independent of the widget's BridgeSnapshot; extra
/// keys in the JSON are ignored by JSONDecoder.
private struct SiriSnapshot: Decodable {
  struct NextJob: Decodable {
    var id: String
    var customerName: String
    var title: String
    var scheduledDate: String
    var scheduledStartTime: String?
    // Optional here even though the app always writes a string: a snapshot
    // missing this key must degrade to "no address", not fail the whole decode.
    var address: String?
  }

  var nextJob: NextJob?
}

private func siriLoadSnapshot() -> SiriSnapshot? {
  guard
    let defaults = UserDefaults(suiteName: siriAppGroupId),
    let json = defaults.string(forKey: siriSnapshotKey),
    let data = json.data(using: .utf8)
  else { return nil }
  return try? JSONDecoder().decode(SiriSnapshot.self, from: data)
}

/// Spoken form of the schedule slot: "today at 9:00 AM", "tomorrow",
/// "Monday, August 10 at 2:30 PM". Deliberately NOT the widget's whenLabel —
/// that one uses a middle dot separator, which Siri would read out loud.
/// scheduledDate/scheduledStartTime are local-frame strings, so they are
/// parsed in the device's own calendar (same frame the app wrote them in).
private func siriWhenLabel(_ job: SiriSnapshot.NextJob) -> String {
  let parser = DateFormatter()
  parser.locale = Locale(identifier: "en_US_POSIX")
  parser.timeZone = TimeZone.current

  var parsed: Date?
  var hasTime = false
  if let time = job.scheduledStartTime, !time.isEmpty {
    parser.dateFormat = "yyyy-MM-dd HH:mm"
    parsed = parser.date(from: "\(job.scheduledDate) \(time)")
    hasTime = parsed != nil
  }
  if parsed == nil {
    parser.dateFormat = "yyyy-MM-dd"
    parsed = parser.date(from: job.scheduledDate)
  }
  guard let start = parsed else { return job.scheduledDate }

  let calendar = Calendar.current
  let dayLabel: String
  if calendar.isDateInToday(start) {
    dayLabel = "today"
  } else if calendar.isDateInTomorrow(start) {
    dayLabel = "tomorrow"
  } else {
    let dayFormatter = DateFormatter()
    dayFormatter.dateFormat = "EEEE, MMMM d"
    dayLabel = dayFormatter.string(from: start)
  }

  if hasTime {
    let timeFormatter = DateFormatter()
    timeFormatter.dateStyle = .none
    timeFormatter.timeStyle = .short
    return "\(dayLabel) at \(timeFormatter.string(from: start))"
  }
  return dayLabel
}

// MARK: - Pending action queue

/// Append one PendingAction to the shared `widgetActions` queue. Same
/// read-append-write as appendPendingAction(_:) in JobTimer.swift — duplicated
/// rather than shared because that one is widget-target-only (see header).
/// A malformed/absent queue is treated as empty, exactly like the JS parser.
private func siriAppendPendingAction(_ action: [String: Any]) {
  guard let defaults = UserDefaults(suiteName: siriAppGroupId) else { return }

  var queue: [[String: Any]] = []
  if let raw = defaults.string(forKey: siriActionsKey),
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

  defaults.set(json, forKey: siriActionsKey)
  WidgetCenter.shared.reloadAllTimelines()
}

// MARK: - Active trip (Siri's private session state)

private struct SiriActiveTrip {
  var startedAt: String
  var odometerStart: Double
}

private func siriLoadActiveTrip() -> SiriActiveTrip? {
  guard
    let defaults = UserDefaults(suiteName: siriAppGroupId),
    let raw = defaults.string(forKey: siriActiveTripKey),
    let data = raw.data(using: .utf8),
    let parsed = try? JSONSerialization.jsonObject(with: data, options: []),
    let dict = parsed as? [String: Any],
    let startedAt = dict["startedAt"] as? String,
    let odometerStart = dict["odometerStart"] as? Double
  else { return nil }
  return SiriActiveTrip(startedAt: startedAt, odometerStart: odometerStart)
}

/// Returns false when the container is unavailable or the payload won't
/// encode, so the caller can tell the user instead of silently losing the trip.
private func siriSaveActiveTrip(startedAt: String, odometerStart: Double) -> Bool {
  guard let defaults = UserDefaults(suiteName: siriAppGroupId) else { return false }
  let payload: [String: Any] = ["startedAt": startedAt, "odometerStart": odometerStart]
  guard
    let encoded = try? JSONSerialization.data(withJSONObject: payload, options: []),
    let json = String(data: encoded, encoding: .utf8)
  else { return false }
  defaults.set(json, forKey: siriActiveTripKey)
  return true
}

private func siriClearActiveTrip() {
  UserDefaults(suiteName: siriAppGroupId)?.removeObject(forKey: siriActiveTripKey)
}

// MARK: - Formatting helpers

private func siriISONow() -> String {
  ISO8601DateFormatter().string(from: Date())
}

/// The LOCAL "yyyy-MM-dd" the trip started on — the frame AddTripScreen and
/// utils/widgetActions.ts both use for Trip.date. A trip that starts at 11pm
/// and ends after midnight is logged on the day it began.
private func siriLocalDateString(fromISO iso: String) -> String {
  // Try fractional seconds first: a plain ISO8601DateFormatter rejects them,
  // and JS toISOString() always emits them (this file writes the plain form,
  // but the value may have been written by a future/other producer).
  let fractional = ISO8601DateFormatter()
  fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  let parsed = fractional.date(from: iso) ?? ISO8601DateFormatter().date(from: iso) ?? Date()

  let formatter = DateFormatter()
  formatter.locale = Locale(identifier: "en_US_POSIX")
  formatter.timeZone = TimeZone.current
  formatter.dateFormat = "yyyy-MM-dd"
  return formatter.string(from: parsed)
}

/// "12" for whole miles, "12.4" otherwise — spoken numbers shouldn't carry
/// trailing zeros.
private func siriFormatMiles(_ miles: Double) -> String {
  if miles.rounded() == miles {
    return String(format: "%.0f", miles)
  }
  return String(format: "%.1f", miles)
}

// A reading the JS side would only drop: tripFromAction requires finite
// numbers >= 0 for both odometer values.
private func siriIsValidOdometer(_ value: Double) -> Bool {
  value.isFinite && value >= 0
}

private let siriBadOdometerDialog = "That odometer reading doesn't look right. Try again with a number of miles."

// MARK: - Intents

// `static let` (not `var`) satisfies AppIntent's get-only requirements and
// stays concurrency-safe if these targets ever move to the Swift 6 mode, same
// as the timer intents in JobTimer.swift. `description` is deliberately NOT
// declared on any of these: it is an optional requirement whose exact witness
// type (IntentDescription vs IntentDescription?) differs between the sources
// this was checked against, and a wrong guess costs a full cloud build for a
// subtitle in the Shortcuts app. Every intent below also declares an explicit
// empty `init()` rather than relying on Swift synthesising one — the
// AppIntent protocol requires `init()`, and an explicit empty one leaves the
// @Parameter values unset so Siri still prompts for them.

@available(iOS 17.0, *)
struct NextJobIntent: AppIntent {
  static let title: LocalizedStringResource = "Next Job"

  init() {}

  func perform() async throws -> some IntentResult & ProvidesDialog {
    guard let job = siriLoadSnapshot()?.nextJob else {
      return .result(dialog: "You have no upcoming jobs scheduled.")
    }

    var message = "Your next job is \(job.title) for \(job.customerName), \(siriWhenLabel(job))"
    if let address = job.address, !address.isEmpty {
      message += ", at \(address)"
    }
    message += "."
    return .result(dialog: "\(message)")
  }
}

@available(iOS 17.0, *)
struct StartTripIntent: AppIntent {
  static let title: LocalizedStringResource = "Start Mileage Trip"

  @Parameter(title: "Starting odometer")
  var odometerStart: Double

  init() {}

  func perform() async throws -> some IntentResult & ProvidesDialog {
    // One trip at a time: overwriting would silently lose the first drive.
    if siriLoadActiveTrip() != nil {
      return .result(dialog: "A trip is already running. Say 'stop my trip' to finish it.")
    }
    guard siriIsValidOdometer(odometerStart) else {
      return .result(dialog: "\(siriBadOdometerDialog)")
    }
    guard siriSaveActiveTrip(startedAt: siriISONow(), odometerStart: odometerStart) else {
      return .result(dialog: "I couldn't start the trip. Open TradeReady and try again.")
    }
    return .result(dialog: "Trip started at \(siriFormatMiles(odometerStart)) miles.")
  }
}

@available(iOS 17.0, *)
struct StopTripIntent: AppIntent {
  static let title: LocalizedStringResource = "Stop Mileage Trip"

  @Parameter(title: "Ending odometer")
  var odometerEnd: Double

  init() {}

  func perform() async throws -> some IntentResult & ProvidesDialog {
    guard let trip = siriLoadActiveTrip() else {
      return .result(dialog: "No trip is running.")
    }
    // Leave the trip running on a bad reading so the user can just try again.
    guard siriIsValidOdometer(odometerEnd), siriIsValidOdometer(trip.odometerStart) else {
      return .result(dialog: "\(siriBadOdometerDialog)")
    }

    // A COMPLETE trip — the app never sees a half-finished one. Keys are the
    // trip_log contract in utils/widgetActions.ts (tripFromAction); the
    // odometer values must serialize as JSON numbers, which the guard above
    // guarantees (JSONSerialization refuses NaN/infinity outright).
    let action: [String: Any] = [
      "id": UUID().uuidString,
      "type": "trip_log",
      "at": siriISONow(),
      "date": siriLocalDateString(fromISO: trip.startedAt),
      "odometerStart": trip.odometerStart,
      "odometerEnd": odometerEnd,
    ]
    siriAppendPendingAction(action)
    siriClearActiveTrip()

    let miles = max(0, odometerEnd - trip.odometerStart)
    return .result(dialog: "Logged \(siriFormatMiles(miles)) miles.")
  }
}

@available(iOS 17.0, *)
struct OnMyWayIntent: AppIntent {
  static let title: LocalizedStringResource = "On My Way"

  // openAppWhenRun makes the system bring TradeReady to the front and run
  // perform() IN THE APP PROCESS (possible only because this file is linked
  // into the app target — see the header). The intent itself NEVER sends
  // anything: it hands the app a deep link, the app opens the SMS composer
  // prefilled, and the user hits send.
  //
  // Two routes were rejected getting here:
  //  * OpenURLIntent — iOS 18+ only, and Apple states universal links, not
  //    custom schemes, are its supported input
  //    (developer.apple.com/forums/thread/762586). TradeReady has no
  //    associated domain, so it has no universal link to hand over.
  //  * EnvironmentValues().openURL(_:) — the commonly cited workaround, but
  //    reported not to actually open anything from inside an intent
  //    (developer.apple.com/forums/thread/763692).
  // What's left is the route the URL would have taken anyway once iOS handed
  // it to the app: RCTLinkingManager listens for RCTOpenURLNotification and
  // re-emits it as the JS "url" event that App.tsx's Linking listener consumes
  // (node_modules/react-native/Libraries/LinkingIOS/RCTLinkingManager.mm —
  // kOpenURLNotification, userInfo {"url": absoluteString}). Posting it here
  // is the same event the AppDelegate would post, minus UIApplication, which
  // is unavailable to app extensions and so cannot appear in a _shared file.
  static let openAppWhenRun: Bool = true

  init() {}

  @MainActor
  func perform() async throws -> some IntentResult & ProvidesDialog {
    guard let job = siriLoadSnapshot()?.nextJob else {
      return .result(dialog: "You have no upcoming jobs scheduled.")
    }
    // Same link shape as the widget's widgetURL; utils/deepLinks.ts parses one
    // path segment and decodes it. Job ids are alphanumeric with -/_ only.
    if let url = URL(string: "tradeready://onmyway/\(job.id)") {
      // No observer (cold launch before JS mounts, or the widget target, which
      // links this file but never runs it) simply means nothing happens — the
      // user still lands in the app, just not on the composer.
      NotificationCenter.default.post(
        name: Notification.Name("RCTOpenURLNotification"),
        object: nil,
        userInfo: ["url": url.absoluteString]
      )
    }
    return .result(dialog: "Opening a message for \(job.customerName).")
  }
}

// MARK: - Siri phrases

// Every phrase must contain \(.applicationName) — Siri matches on the app name
// to disambiguate. Two phrasings each: the literal command and the way a
// tradesperson would actually say it.
@available(iOS 17.0, *)
struct TradeReadyShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: NextJobIntent(),
      phrases: [
        "What's my next job in \(.applicationName)",
        "What's next in \(.applicationName)",
      ],
      shortTitle: "Next Job",
      systemImageName: "calendar"
    )
    AppShortcut(
      intent: StartTripIntent(),
      phrases: [
        "Start a trip in \(.applicationName)",
        "Start tracking miles in \(.applicationName)",
      ],
      shortTitle: "Start Trip",
      systemImageName: "car"
    )
    AppShortcut(
      intent: StopTripIntent(),
      phrases: [
        "Stop my trip in \(.applicationName)",
        "Finish my trip in \(.applicationName)",
      ],
      shortTitle: "Stop Trip",
      systemImageName: "car.fill"
    )
    AppShortcut(
      intent: OnMyWayIntent(),
      phrases: [
        "I'm on my way in \(.applicationName)",
        "Tell my customer I'm on my way in \(.applicationName)",
      ],
      shortTitle: "On My Way",
      systemImageName: "message"
    )
  }
}
