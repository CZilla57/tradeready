import Foundation
#if canImport(os)
import os
#endif

/// Task 11.12 (H4): the app's performance signposts.
///
/// A small, fixed set of `os_signpost` intervals (through `OSSignposter`, on
/// the Points of Interest category) that Instruments' App Launch, Time Profiler
/// and os_signpost instruments show in Debug and in Release-with-dSYM builds.
/// The measurement protocol is `docs/native-phase-11-performance.md`.
///
/// Privacy (contract §10.1, the 11.09 redaction rules): an interval's name is a
/// compile-time `StaticString`, and its only metadata is a clamped record count
/// and a fixed outcome word, rendered by `metadata(count:outcome:)`. No API here
/// accepts a string, so no customer data, record id, email, token or key can
/// reach a signpost. Nothing is sent anywhere: signposts stay in the unified
/// log, read only by a developer's Instruments or `log` session. There is no
/// analytics or crash-reporting hook (contract §9/§10 allow neither).
///
/// Non-invasive and debug-safe: every call is synchronous, never suspends and
/// never traps; it adds no `await` and changes no ordering at a call site. When
/// no signpost consumer is attached, `OSSignposter.isEnabled` is false and a
/// call costs one flag read. A call made twice, out of order or without its
/// begin is a no-op.
enum NativePerformanceInterval: CaseIterable, Equatable, Sendable {
    /// `TradeReadyNativeApp.init` → the root view's first appearance.
    case launch
    /// The canonical snapshot read and decode inside `AppStore.init`.
    case snapshotLoad
    /// The Expo AsyncStorage import (`LegacyMigrationCoordinator.migrate`) at launch.
    case legacyMigration
    /// The first full pull after sign-in, through its atomic commit.
    case initialSync
    /// One incremental cursor pull through its atomic commit.
    case deltaPull
    /// One `BGAppRefreshTask` pass (push, pull, photos, replay).
    case backgroundRefresh
    /// The Jobs list projection (`NativeJobList.state`) a render reads.
    case jobListProjection
    /// The Invoices list filter/sort a render reads.
    case invoiceListProjection

    /// The Instruments name. A `StaticString`, so it can only be a literal.
    var signpostName: StaticString {
        switch self {
        case .launch: "Launch"
        case .snapshotLoad: "SnapshotLoad"
        case .legacyMigration: "LegacyMigration"
        case .initialSync: "InitialSync"
        case .deltaPull: "DeltaPull"
        case .backgroundRefresh: "BackgroundRefresh"
        case .jobListProjection: "JobListProjection"
        case .invoiceListProjection: "InvoiceListProjection"
        }
    }

    var name: String { signpostName.description }
}

/// How an interval ended. The only words a signpost's metadata may carry.
enum NativePerformanceOutcome: String, CaseIterable, Equatable, Sendable {
    case completed
    case partial
    case failed
    case skipped
}

/// Where intervals go. Production uses `NativeOSSignpostSink`; host tests
/// record. Only `NativePerformanceMetrics` talks to a sink.
protocol NativePerformanceSignpostSink: AnyObject {
    var isEnabled: Bool { get }
    /// Begins an interval and returns the state its end must hand back.
    func beginInterval(_ interval: NativePerformanceInterval, metadata: String) -> AnyObject?
    func endInterval(_ interval: NativePerformanceInterval, state: AnyObject?, metadata: String)
}

/// One begun interval. Ending it more than once is a no-op.
final class NativePerformanceIntervalToken: @unchecked Sendable {
    let interval: NativePerformanceInterval
    fileprivate let sink: (any NativePerformanceSignpostSink)?
    fileprivate let state: AnyObject?
    fileprivate var isEnded: Bool

    fileprivate init(
        interval: NativePerformanceInterval,
        sink: (any NativePerformanceSignpostSink)?,
        state: AnyObject?
    ) {
        self.interval = interval
        self.sink = sink
        self.state = state
        // An interval the sink never saw (disabled or absent) never ends on it.
        isEnded = sink == nil
    }
}

final class NativePerformanceMetrics: @unchecked Sendable {
    static let shared = NativePerformanceMetrics(sink: NativePerformanceMetrics.defaultSink())

    /// The largest count a signpost carries (nine digits).
    static let maximumCount = 999_999_999

    private let lock = NSLock()
    private var sink: (any NativePerformanceSignpostSink)?
    private var launchToken: NativePerformanceIntervalToken?
    private var launchStarted = false

    init(sink: (any NativePerformanceSignpostSink)?) {
        self.sink = sink
    }

    /// Whether a sink is installed (the OS sink wherever `os` exists).
    var hasSink: Bool {
        lock.lock(); defer { lock.unlock() }
        return sink != nil
    }

    /// Host-test seam: routes intervals begun after this call to `sink`. An
    /// interval already begun still ends on the sink that began it.
    func replaceSink(_ sink: (any NativePerformanceSignpostSink)?) {
        lock.lock(); defer { lock.unlock() }
        self.sink = sink
    }

    /// Begins `interval`. `count` is an optional size (records, rows).
    @discardableResult
    func begin(_ interval: NativePerformanceInterval, count: Int? = nil) -> NativePerformanceIntervalToken {
        lock.lock()
        let current = sink
        lock.unlock()
        guard let current, current.isEnabled else {
            return NativePerformanceIntervalToken(interval: interval, sink: nil, state: nil)
        }
        let state = current.beginInterval(interval, metadata: Self.metadata(count: count, outcome: nil))
        return NativePerformanceIntervalToken(interval: interval, sink: current, state: state)
    }

    /// Ends `token` once, on the sink that began it.
    func end(
        _ token: NativePerformanceIntervalToken,
        outcome: NativePerformanceOutcome = .completed,
        count: Int? = nil
    ) {
        lock.lock()
        let alreadyEnded = token.isEnded
        token.isEnded = true
        lock.unlock()
        guard !alreadyEnded, let sink = token.sink else { return }
        sink.endInterval(token.interval, state: token.state, metadata: Self.metadata(count: count, outcome: outcome))
    }

    /// Brackets synchronous `work`, passing its value or error through
    /// unchanged. A thrown error ends the interval as `failed`.
    func measure<T>(
        _ interval: NativePerformanceInterval,
        count: (T) -> Int? = { _ in nil },
        _ work: () throws -> T
    ) rethrows -> T {
        let token = begin(interval)
        do {
            let value = try work()
            end(token, outcome: .completed, count: count(value))
            return value
        } catch {
            end(token, outcome: .failed)
            throw error
        }
    }

    /// Starts the process's launch interval. Only the first call counts.
    func beginLaunch() {
        lock.lock()
        let shouldBegin = !launchStarted
        launchStarted = true
        lock.unlock()
        guard shouldBegin else { return }
        let token = begin(.launch)
        lock.lock()
        launchToken = token
        lock.unlock()
    }

    /// Ends the launch interval at the root view's first appearance. Later
    /// appearances (scene reconnects, window changes) are no-ops.
    func endLaunch() {
        finishLaunch(.completed)
    }

    /// Ends the launch interval as `skipped` when the process was launched
    /// for background work and no root view has appeared (review M6): a
    /// background-only cold launch never draws a first frame, so it is not a
    /// launch-time sample. A no-op once the launch has ended.
    func endLaunchInBackground() {
        finishLaunch(.skipped)
    }

    private func finishLaunch(_ outcome: NativePerformanceOutcome) {
        lock.lock()
        let token = launchToken
        launchToken = nil
        lock.unlock()
        guard let token else { return }
        end(token, outcome: outcome)
    }

    /// The only metadata a signpost carries: `count=<0…999999999>` and/or
    /// `outcome=<completed|partial|failed|skipped>`, space-separated, or empty.
    static func metadata(count: Int?, outcome: NativePerformanceOutcome?) -> String {
        var parts: [String] = []
        if let count {
            parts.append("count=\(min(max(count, 0), maximumCount))")
        }
        if let outcome {
            parts.append("outcome=\(outcome.rawValue)")
        }
        return parts.joined(separator: " ")
    }

    private static func defaultSink() -> (any NativePerformanceSignpostSink)? {
        #if canImport(os)
        NativeOSSignpostSink()
        #else
        nil
        #endif
    }
}

#if canImport(os)
/// Production sink: `OSSignposter` on the Points of Interest category, so the
/// intervals appear in Instruments' App Launch and Points of Interest tracks.
/// The only message is the rendered metadata (counts and outcome words), marked
/// public so a Release build shows it instead of `<private>`.
final class NativeOSSignpostSink: NativePerformanceSignpostSink, @unchecked Sendable {
    private let signposter = OSSignposter(subsystem: "com.tradeready.native", category: .pointsOfInterest)

    var isEnabled: Bool { signposter.isEnabled }

    func beginInterval(_ interval: NativePerformanceInterval, metadata: String) -> AnyObject? {
        let id = signposter.makeSignpostID()
        return signposter.beginInterval(interval.signpostName, id: id, "\(metadata, privacy: .public)")
    }

    func endInterval(_ interval: NativePerformanceInterval, state: AnyObject?, metadata: String) {
        guard let state = state as? OSSignpostIntervalState else { return }
        signposter.endInterval(interval.signpostName, state, "\(metadata, privacy: .public)")
    }
}
#endif
