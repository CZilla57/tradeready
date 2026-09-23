import Foundation

enum NativeBackgroundRefreshOutcome: Equatable, Sendable {
    case completed
    case skipped
    case failed

    var taskSucceeded: Bool { self != .failed }
}

/// Pure scheduling contract shared by the iOS bridge and host tests. The date
/// is only an earliest eligible time; iOS remains free to batch or defer work.
enum NativeBackgroundRefreshPolicy {
    static let taskIdentifier = "com.gettradereadyapp.tradeready.sync-refresh"
    static let minimumInterval: TimeInterval = 30 * 60

    static func earliestBeginDate(from now: Date) -> Date {
        now.addingTimeInterval(minimumInterval)
    }

    static func canAttachVerifiedIdentity(
        verifiedAccountBinding: String,
        workspaceAccountBinding: String?,
        workspaceIsComplete: Bool
    ) -> Bool {
        workspaceIsComplete && workspaceAccountBinding == verifiedAccountBinding
    }
}

/// Owns one system task's async work and guarantees exactly one completion,
/// including when iOS expires the task while a network operation is suspended.
@MainActor
final class NativeBackgroundRefreshOperation {
    typealias Work = @MainActor () async -> NativeBackgroundRefreshOutcome
    typealias Completion = @MainActor (Bool) -> Void

    private var task: Task<Void, Never>?
    private var didComplete = false
    private var completion: Completion?

    func start(work: @escaping Work, completion: @escaping Completion) {
        guard task == nil, !didComplete else { return }
        self.completion = completion
        task = Task { @MainActor [weak self] in
            let outcome = await work()
            guard let self else { return }
            finish(success: !Task.isCancelled && outcome.taskSucceeded)
        }
    }

    func cancel() {
        task?.cancel()
        finish(success: false)
    }

    private func finish(success: Bool) {
        guard !didComplete else { return }
        didComplete = true
        task = nil
        let completion = completion
        self.completion = nil
        completion?(success)
    }
}

#if os(iOS) && canImport(BackgroundTasks)
import BackgroundTasks

/// Thin iOS adapter around the testable policy/operation above. Registration
/// happens from `TradeReadyNativeApp.init`, before application launch finishes.
@MainActor
final class NativeBackgroundRefreshScheduler {
    typealias Work = NativeBackgroundRefreshOperation.Work

    private let work: Work
    private var registered = false
    private var activeOperation: NativeBackgroundRefreshOperation?

    init(work: @escaping Work) {
        self.work = work
    }

    func register() {
        guard !registered else { return }
        registered = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: NativeBackgroundRefreshPolicy.taskIdentifier,
            using: nil
        ) { [weak self] task in
            Task { @MainActor in
                self?.handle(task)
            }
        }
        if !registered {
            print("TradeReadyBackgroundRefresh stage=registration")
        }
    }

    func schedule(now: Date = Date()) {
        guard registered else { return }
        let request = BGAppRefreshTaskRequest(
            identifier: NativeBackgroundRefreshPolicy.taskIdentifier
        )
        request.earliestBeginDate = NativeBackgroundRefreshPolicy.earliestBeginDate(from: now)
        do {
            // Submitting the same unexecuted refresh identifier replaces the
            // pending request, so foreground/background churn stays idempotent.
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // Do not log NSError descriptions: they can contain environment
            // detail. The stage is sufficient for device diagnostics.
            print("TradeReadyBackgroundRefresh stage=schedule")
        }
    }

    /// A foreground transition supersedes a delivered refresh. Cancelling the
    /// structured task lets foreground identity activation take ownership and
    /// reports the delivered system task complete without waiting for expiry.
    func cancelActive() {
        activeOperation?.cancel()
    }

    private func handle(_ task: BGTask) {
        // Always request the next opportunity before doing this pass. iOS may
        // decline or substantially defer it; foreground sync remains primary.
        schedule()
        guard activeOperation == nil else {
            task.setTaskCompleted(success: false)
            return
        }

        let operation = NativeBackgroundRefreshOperation()
        activeOperation = operation
        let completion: NativeBackgroundRefreshOperation.Completion = { [weak self, weak task] success in
            task?.setTaskCompleted(success: success)
            self?.activeOperation = nil
        }
        task.expirationHandler = { [weak operation] in
            Task { @MainActor in
                operation?.cancel()
            }
        }
        operation.start(work: work, completion: completion)
    }
}
#endif
