import AppIntents
import Foundation
import WidgetKit

// Siri App Intents — Tier 1 (docs/widget-plan.md Phase 4) plus the Tier 2 wave
// (.superpowers/sdd/plan-widgets-tier2.md): clock in/out, log an expense, and
// "how much am I owed".
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
private let siriPendingOpenUrlKey = "pendingOpenUrl"

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

  /// Present ONLY while a clock-in session is running — selectActiveTimer in
  /// utils/widgetBridge.ts writes null otherwise — so `timer != nil` is the
  /// snapshot's answer to "is the user on the clock". Every field is optional
  /// for the same reason NextJob.address is: a partial timer object must
  /// degrade to "no job id", not fail the decode and make Siri claim the user
  /// is off the clock when they aren't.
  struct TimerState: Decodable {
    var jobId: String?
  }

  var nextJob: NextJob?
  var timer: TimerState?
  /// Sum of unpaid invoice balances in dollars, already rounded to cents by the
  /// app (summarizeInvoices semantics). Absent key -> nil -> spoken as zero.
  var outstandingTotal: Double?
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
/// Returns false when the container is unavailable or the payload won't encode
/// — StopTripIntent gates on that, because a failed write there also strands
/// the trip's starting odometer with no way for the user to get it back. The
/// other callers ignore the result on purpose; each says why at the call site.
private func siriAppendPendingAction(_ action: [String: Any]) -> Bool {
  guard let defaults = UserDefaults(suiteName: siriAppGroupId) else { return false }

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
  else { return false }

  defaults.set(json, forKey: siriActionsKey)
  WidgetCenter.shared.reloadAllTimelines()
  return true
}

/// The type of the most recent queued timer action, or nil when none is
/// waiting. Last one wins: a start followed by a stop reads as a stop, which is
/// what the user last asked for.
///
/// A deliberate private reimplementation of lastPendingTimerType() in
/// JobTimer.swift rather than a call into it: that file is widget-target-only,
/// and this one also compiles into the main app target where it doesn't exist.
/// The two bodies must stay in step — if the optimistic rule changes in one,
/// Siri and the widget start telling the user different things.
private func siriLastPendingTimerType() -> String? {
  guard
    let defaults = UserDefaults(suiteName: siriAppGroupId),
    let raw = defaults.string(forKey: siriActionsKey),
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

/// Is the user on the clock right now? Exactly the reading the Job Timer widget
/// renders (JobTimerProvider.currentEntry), so Siri and the widget can never
/// disagree: a queued action outranks the snapshot because the app hasn't
/// replayed it yet, and the snapshot decides only when nothing is queued.
private func siriIsOnTheClock(snapshot: SiriSnapshot?, pending: String?) -> Bool {
  if pending == "timer_start" { return true }
  if pending == "timer_stop" { return false }
  return snapshot?.timer != nil
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

/// How long an unfinished trip may sit before StartTripIntent is allowed to
/// throw it away. A day is well past any plausible drive, and `activeTrip` is
/// Siri's own private state — no app screen can clear it — so without this
/// escape a trip the user never said "stop" to would wedge the intent forever.
private let siriStaleActiveTripInterval: TimeInterval = 24 * 60 * 60

/// An unparseable `startedAt` counts as stale: an active trip we can't date is
/// one we can never age out, which is the exact wedge this guards against.
private func siriIsStaleActiveTrip(_ trip: SiriActiveTrip) -> Bool {
  guard let started = siriParseISODate(trip.startedAt) else { return true }
  return Date().timeIntervalSince(started) > siriStaleActiveTripInterval
}

// MARK: - Pending open-url stash (cold-launch handoff)

/// Stash the deep link the app should open on its next start. Read-and-cleared
/// by App.tsx's drainPendingOpenUrl at the two cold-start flush points, which
/// also ignores anything older than 5 minutes — this is a handoff for a launch
/// that is happening right now, never a queue.
/// Best-effort: a failure here must not stop the notification post, which is
/// what serves the (far more common) warm path.
private func siriStashPendingOpenUrl(_ url: String) {
  guard let defaults = UserDefaults(suiteName: siriAppGroupId) else { return }
  let payload: [String: Any] = ["url": url, "at": siriISONow()]
  guard
    let encoded = try? JSONSerialization.data(withJSONObject: payload, options: []),
    let json = String(data: encoded, encoding: .utf8)
  else { return }
  defaults.set(json, forKey: siriPendingOpenUrlKey)
}

// MARK: - Formatting helpers

private func siriISONow() -> String {
  ISO8601DateFormatter().string(from: Date())
}

/// Parse an ISO 8601 instant, fractional seconds first: a plain
/// ISO8601DateFormatter rejects them outright, and JS toISOString() always
/// emits them (this file writes the plain form, but a value in the container
/// may have been written by another producer). Same two-step as
/// parseISODate(_:) in JobTimer.swift, which is widget-target-only.
private func siriParseISODate(_ value: String) -> Date? {
  let fractional = ISO8601DateFormatter()
  fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  if let date = fractional.date(from: value) {
    return date
  }
  return ISO8601DateFormatter().date(from: value)
}

/// The LOCAL "yyyy-MM-dd" the trip started on — the frame AddTripScreen and
/// utils/widgetActions.ts both use for Trip.date. A trip that starts at 11pm
/// and ends after midnight is logged on the day it began.
private func siriLocalDateString(fromISO iso: String) -> String {
  // An unparseable stamp falls back to now: a date is required by the contract,
  // and today is the only defensible guess for an action taken right now.
  let parsed = siriParseISODate(iso) ?? Date()

  let formatter = DateFormatter()
  formatter.locale = Locale(identifier: "en_US_POSIX")
  formatter.timeZone = TimeZone.current
  formatter.dateFormat = "yyyy-MM-dd"
  return formatter.string(from: parsed)
}

/// "12" for whole miles, "12.4" otherwise — spoken numbers shouldn't carry
/// trailing zeros.
///
/// ROUND FIRST, then decide whole-vs-decimal. Testing the raw value instead
/// (the v1 bug) mis-sorts everything that rounds to a whole number without
/// being one: 12.96 is not whole, took the "%.1f" branch, and Siri said
/// "twelve point nine six miles" as "13.0". siriFormatDollars has the same
/// shape one decimal place down.
private func siriFormatMiles(_ miles: Double) -> String {
  let rounded = (miles * 10).rounded() / 10
  if rounded == rounded.rounded() {
    return String(format: "%.0f", rounded)
  }
  return String(format: "%.1f", rounded)
}

/// "12" for a whole number of dollars, "12.50" otherwise. Rounds to cents
/// first, for the reason spelled out on siriFormatMiles. Deliberately not a
/// NumberFormatter: the "$" is written by the caller's dialog string, and a
/// currency formatter would add a grouped, locale-specific symbol that Siri
/// reads back oddly when it disagrees with the app's own USD formatting.
private func siriFormatDollars(_ amount: Double) -> String {
  let rounded = (amount * 100).rounded() / 100
  if rounded == rounded.rounded() {
    return String(format: "%.0f", rounded)
  }
  return String(format: "%.2f", rounded)
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
// as the timer intents in JobTimer.swift. (SiriExpenseCategory below is the one
// exception, for a reason spelled out on the type.) `description` is
// deliberately NOT declared on any of these: it is an optional requirement
// whose exact witness type (IntentDescription vs IntentDescription?) differs
// between the sources
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
    // The exception is a session nobody ever stopped — see
    // siriIsStaleActiveTrip. Its odometer reading is discarded with it; a drive
    // that was never finished has no end reading to log, and holding it any
    // longer only blocks the trip the user is asking for now.
    var replacedStaleTrip = false
    if let existing = siriLoadActiveTrip() {
      if !siriIsStaleActiveTrip(existing) {
        return .result(dialog: "A trip is already running. Say 'stop my trip' to finish it.")
      }
      replacedStaleTrip = true
    }
    guard siriIsValidOdometer(odometerStart) else {
      return .result(dialog: "\(siriBadOdometerDialog)")
    }
    // Overwrites a stale session in place, so there is nothing to clear first
    // and no window where the user has neither trip.
    guard siriSaveActiveTrip(startedAt: siriISONow(), odometerStart: odometerStart) else {
      return .result(dialog: "I couldn't start the trip. Open TradeReady and try again.")
    }
    if replacedStaleTrip {
      return .result(dialog: "Your previous trip was never finished \u{2014} starting a new one.")
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
    // The one caller that gates on the write: this intent is the ONLY moment
    // the trip becomes real, and clearing the session after a failed append
    // would take the starting odometer with it — unrecoverable, since the user
    // has long since driven past it.
    guard siriAppendPendingAction(action) else {
      return .result(dialog: "Something went wrong saving the trip \u{2014} try again.")
    }
    // Only now: the trip is queued, so the session state has done its job.
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
      // Two paths, because which one fires depends on whether JS is already up:
      //  * COLD launch — the notification below lands before App.tsx mounts its
      //    "url" listener and is lost, so stash the link first. App.tsx drains
      //    `pendingOpenUrl` at its cold-start flush points (onReady and the
      //    session effect) and navigates from there.
      //  * WARM — the listener is live, the notification navigates immediately,
      //    and App.tsx clears the stash on that same navigation so it can never
      //    replay on a later launch. The 5-minute freshness window in
      //    parsePendingOpenUrl is the backstop if even that is missed.
      // The stash is written first and unconditionally: a failed write must not
      // cost us the warm path, which is the common case.
      siriStashPendingOpenUrl(url.absoluteString)
      NotificationCenter.default.post(
        name: Notification.Name("RCTOpenURLNotification"),
        object: nil,
        userInfo: ["url": url.absoluteString]
      )
    }
    return .result(dialog: "Opening a message for \(job.customerName).")
  }
}

@available(iOS 17.0, *)
struct ClockInIntent: AppIntent {
  static let title: LocalizedStringResource = "Clock In"

  init() {}

  func perform() async throws -> some IntentResult & ProvidesDialog {
    let snapshot = siriLoadSnapshot()
    if siriIsOnTheClock(snapshot: snapshot, pending: siriLastPendingTimerType()) {
      return .result(dialog: "You're already clocked in.")
    }
    // The snapshot's nextJob is the same job the Job Timer widget puts its
    // Start button on. Siri has no way to name a job here, so there is nothing
    // else to choose; a job that shouldn't be clocked into (already complete,
    // invoiced, paid, declined) is dropped by the replay layer's DONE_STATUSES
    // guard in utils/widgetActions.ts, which is where that policy lives.
    guard let job = snapshot?.nextJob else {
      return .result(dialog: "No upcoming job to clock into.")
    }

    // Best-effort write: the snapshot read above already proved the App Group
    // container is reachable (without it this would have said "no upcoming
    // job"), and an all-strings payload is one JSONSerialization cannot refuse.
    // Contrast StopTripIntent, which gates because a lost write there also
    // strands state the user can't reconstruct.
    _ = siriAppendPendingAction([
      "id": UUID().uuidString,
      "type": "timer_start",
      "jobId": job.id,
      "at": siriISONow(),
    ])
    return .result(dialog: "Clocked in to \(job.title).")
  }
}

@available(iOS 17.0, *)
struct ClockOutIntent: AppIntent {
  static let title: LocalizedStringResource = "Clock Out"

  init() {}

  func perform() async throws -> some IntentResult & ProvidesDialog {
    let snapshot = siriLoadSnapshot()
    guard siriIsOnTheClock(snapshot: snapshot, pending: siriLastPendingTimerType()) else {
      return .result(dialog: "You're not clocked in.")
    }

    var action: [String: Any] = [
      "id": UUID().uuidString,
      "type": "timer_stop",
      "at": siriISONow(),
    ]
    // Omitted when the snapshot doesn't know it — which is exactly the case
    // where a clock-in is still sitting in the queue, so no timer has reached
    // the snapshot yet. applyTimerActions then stops whichever single job is
    // running, the same fallback the widget's Stop button leans on.
    if let jobId = snapshot?.timer?.jobId, !jobId.isEmpty {
      action["jobId"] = jobId
    }
    // Best-effort for the same reason as ClockInIntent above.
    _ = siriAppendPendingAction(action)
    return .result(dialog: "Clocked out.")
  }
}

// MARK: - Expense category

/// The 8 EXPENSE_CATEGORIES ids from utils/moneyUtils.ts. The raw values must
/// stay exactly these strings: they cross the bridge as the action's
/// `category`, and expenseFromAction (utils/widgetActions.ts) files anything it
/// doesn't recognise under "other" rather than dropping the expense.
///
/// INTERNAL, not `private` like the helpers above, for two reasons:
///  * a top-level `private` type has fileprivate scope, and an internal
///    property may not expose one — `@Parameter var category:
///    SiriExpenseCategory` inside the internal LogExpenseIntent would fail to
///    compile ("must be declared fileprivate because its type uses a
///    fileprivate type"), and the intents themselves cannot go fileprivate
///    because AppShortcutsProvider must name them;
///  * Xcode's "Extract app intents metadata" build step recovers these types
///    from the binary's reflection metadata, where reduced visibility is a
///    known source of extraction failures.
/// The `Siri` prefix is what keeps the symbol from colliding with the widget
/// target's own declarations, same job the `siri` prefixes do elsewhere.
///
/// The declaration is deliberately the shape Apple's own sample code uses,
/// down to details that look like they could be tightened:
///  * CaseIterable is NOT restated even though AppEnum refines it — every
///    shipping AppEnum omits it, which is the evidence that `allCases` is
///    synthesised through the inherited conformance, and restating a refined
///    protocol is the kind of thing that draws a redundant-conformance
///    diagnostic. No reason to find out on a cloud build.
///  * Both static properties are STORED `static var`s rather than this file's
///    usual `static let`: a stored var witnesses the requirement whether
///    AppEnum declares it `{ get }` or `{ get set }`, and this file gets
///    exactly one compile attempt per build.
@available(iOS 17.0, *)
enum SiriExpenseCategory: String, AppEnum {
  case materials
  case tools
  case fuel
  case labor
  case insurance
  case software
  case marketing
  case other

  static var typeDisplayRepresentation: TypeDisplayRepresentation =
    TypeDisplayRepresentation(name: "Expense Category")

  static var caseDisplayRepresentations: [SiriExpenseCategory: DisplayRepresentation] = [
    .materials: DisplayRepresentation(title: "Materials"),
    .tools: DisplayRepresentation(title: "Tools"),
    .fuel: DisplayRepresentation(title: "Fuel"),
    .labor: DisplayRepresentation(title: "Labor"),
    .insurance: DisplayRepresentation(title: "Insurance"),
    .software: DisplayRepresentation(title: "Software"),
    .marketing: DisplayRepresentation(title: "Marketing"),
    .other: DisplayRepresentation(title: "Other"),
  ]
}

@available(iOS 17.0, *)
struct LogExpenseIntent: AppIntent {
  static let title: LocalizedStringResource = "Log Expense"

  @Parameter(title: "Amount in dollars")
  var amount: Double

  @Parameter(title: "Category")
  var category: SiriExpenseCategory

  // Named expenseDescription rather than `description`: an instance property
  // called that on a type the AppIntents machinery reflects over is a needless
  // collision risk (CustomStringConvertible, and AppIntent's own static
  // `description`). Only the @Parameter title is user-facing.
  @Parameter(title: "What was it for?")
  var expenseDescription: String

  init() {}

  func perform() async throws -> some IntentResult & ProvidesDialog {
    // Mirrors expenseFromAction's amount guards (utils/widgetActions.ts),
    // including its 1,000,000 ceiling, so anything the replay would silently
    // drop is refused HERE, out loud. Confirming an expense that JS then throws
    // away is the one outcome worse than refusing it. The finite check also
    // makes the payload below safe for JSONSerialization, which refuses
    // NaN/infinity outright.
    guard amount.isFinite, amount > 0, amount <= 1_000_000 else {
      return .result(dialog: "That amount doesn't look right.")
    }

    let at = siriISONow()
    let action: [String: Any] = [
      "id": UUID().uuidString,
      "type": "expense_log",
      "at": at,
      // Local frame, like the trip contract: an expense logged at 11pm belongs
      // to the day the user said it, not to tomorrow in UTC.
      "date": siriLocalDateString(fromISO: at),
      "amount": amount,
      "category": category.rawValue,
      "description": expenseDescription,
    ]
    // Best-effort, unlike StopTripIntent: nothing here holds session state that
    // a failed write would strand, and the guard above rules out the only
    // payload JSONSerialization would reject.
    _ = siriAppendPendingAction(action)

    // rawValue, not the display representation: the raw ids are already the
    // plain lowercase words a person would say ("materials", "fuel").
    return .result(dialog: "Logged $\(siriFormatDollars(amount)) for \(category.rawValue).")
  }
}

@available(iOS 17.0, *)
struct OutstandingIntent: AppIntent {
  static let title: LocalizedStringResource = "Outstanding Invoices"

  init() {}

  func perform() async throws -> some IntentResult & ProvidesDialog {
    // A missing snapshot and a missing key both mean "nothing to report"
    // rather than an error: an install whose mirror hasn't run yet genuinely
    // has nothing owed to announce. Non-finite is impossible over JSON but
    // costs one word to rule out of the spoken number.
    let outstanding = siriLoadSnapshot()?.outstandingTotal ?? 0
    guard outstanding.isFinite, outstanding > 0 else {
      return .result(dialog: "Nothing outstanding \u{2014} you're fully collected.")
    }
    return .result(dialog: "You're owed $\(siriFormatDollars(outstanding)) in outstanding invoices.")
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
    AppShortcut(
      intent: ClockInIntent(),
      phrases: [
        "Clock in in \(.applicationName)",
        "Start the clock in \(.applicationName)",
      ],
      shortTitle: "Clock In",
      systemImageName: "play.circle"
    )
    AppShortcut(
      intent: ClockOutIntent(),
      phrases: [
        "Clock out in \(.applicationName)",
        "Stop the clock in \(.applicationName)",
      ],
      shortTitle: "Clock Out",
      systemImageName: "stop.circle"
    )
    AppShortcut(
      intent: LogExpenseIntent(),
      phrases: [
        "Log an expense in \(.applicationName)",
        "Add an expense in \(.applicationName)",
      ],
      shortTitle: "Log Expense",
      systemImageName: "dollarsign.circle"
    )
    AppShortcut(
      intent: OutstandingIntent(),
      phrases: [
        "How much am I owed in \(.applicationName)",
        "What's outstanding in \(.applicationName)",
      ],
      shortTitle: "Outstanding",
      systemImageName: "banknote"
    )
  }
}
