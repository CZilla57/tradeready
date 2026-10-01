import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Canonical AppStore integration policy for Phase 8 task 8.08
/// (requirements S3, S4, B2–B4, P1, P3).
///
/// Frozen contracts: `docs/native-phase-8-contract-decisions.md` §§1–9 and the
/// calendar/booking/routes/portals spec §§3–5, 7.
///
/// This file owns the pure, testable integration policy. It performs no I/O
/// itself except through the injected `save`/`enqueue` closures and the
/// file-backed `NativeScheduleBookingPendingWorkStore`:
///
/// - Schedule-only and schedule-settings commits re-resolve the CURRENT
///   record, change only owned fields, and preserve unknown/concurrent
///   server fields by struct copy (the canonical `preservation` bags ride
///   along untouched).
/// - Booking/portal intake reuses the task 8.02 planner
///   (`NativeBookingIntake.plan`) and rechecks current records before the
///   atomic snapshot + queue commit. A no-op plan writes nothing (a save
///   would re-enqueue the whole collection).
/// - Remote actions capture the exact verified owner binding, target ID and
///   operation identity, and recheck them after every suspension and before
///   local publication. A timeout after a mutation is an unknown outcome —
///   never permission to repeat destructive server work automatically.
/// - Reschedule resolution is a two-phase commit per contract §7: the revised
///   job schedule is durably saved and queue-acknowledged first, then
///   `respond` carries the exact schedule proof. A superseding schedule edit
///   refuses instead of resolving against the wrong slot.
/// - Link authority is reconciled (`status` read) before adopting or sharing
///   a local display copy. A present-but-stale token gets the recovery path,
///   never a share URL.
/// - Incomplete local-mirror or queue-publication work is persisted per owner
///   binding and recovered without repeating committed server mutations.
///   Owner-bound pending work is scrubbed on the account boundary.
///
/// What this file does NOT do (no invented backend guarantees): it never
/// claims live RPC behavior — server preconditions from contract §§2/7 are
/// consumed through the injected task 8.07 transports, whose stub-loader
/// tests assert the frozen shapes. Real database concurrency proof stays
/// deferred to task 8.14 (blocker M1).
enum NativeScheduleBookingPolicy {

    // MARK: - Schedule-only commit (S3)

    /// Owner-supplied schedule edit. `nil` date/start/end clears the field
    /// (an untimed dated job is not a midnight appointment). Baselines pin
    /// the record the draft was opened against; a concurrent schedule or
    /// lifecycle change refuses instead of silently replacing.
    struct ScheduleOnlyDraft {
        var jobID: String
        var baselineDate: String?
        var baselineStart: String?
        var baselineEnd: String?
        var baselineStatus: String
        var date: String?
        var start: String?
        var end: String?

        init(
            jobID: String,
            baselineDate: String? = nil,
            baselineStart: String? = nil,
            baselineEnd: String? = nil,
            baselineStatus: String = "",
            date: String? = nil,
            start: String? = nil,
            end: String? = nil
        ) {
            self.jobID = jobID
            self.baselineDate = baselineDate
            self.baselineStart = baselineStart
            self.baselineEnd = baselineEnd
            self.baselineStatus = baselineStatus
            self.date = date
            self.start = start
            self.end = end
        }
    }

    enum ScheduleOnlyApply {
        /// Field-scoped merged job plus the IDs of conflicting jobs (RN
        /// parity: conflicts warn, never prevent saving).
        case apply(job: Canonical.Job, conflictingJobIDs: [String])
        /// The current schedule or lifecycle no longer matches the draft
        /// baseline — the owner must refresh/review.
        case baselineConflict(currentDate: String?, currentStart: String?, currentStatus: String)
        /// The record is gone — reject rather than recreate it.
        case missing
    }

    /// Merges ONLY `scheduledDate/scheduledStartTime/scheduledEndTime` (plus
    /// the single automatic `approved → scheduled` transition) into the
    /// current record. Every other field — pricing, contact, photos,
    /// approvals, history, unknown preservation — survives by struct copy.
    static func applyScheduleOnly(
        current: Canonical.Job,
        jobs: [Canonical.Job],
        draft: ScheduleOnlyDraft
    ) -> ScheduleOnlyApply {
        guard current.baselineStatusMatches(draft.baselineStatus) else {
            return .baselineConflict(
                currentDate: current.scheduledDate,
                currentStart: current.scheduledStartTime,
                currentStatus: current.status
            )
        }
        guard current.scheduledDate == draft.baselineDate,
              current.scheduledStartTime == draft.baselineStart,
              current.scheduledEndTime == draft.baselineEnd
        else {
            return .baselineConflict(
                currentDate: current.scheduledDate,
                currentStart: current.scheduledStartTime,
                currentStatus: current.status
            )
        }
        var merged = current
        merged.scheduledDate = normalizedDate(draft.date)
        merged.scheduledStartTime = normalizedTime(draft.start)
        merged.scheduledEndTime = normalizedTime(draft.end)
        // Only `approved → scheduled` is automatic (S3). Booked leads stay
        // leads; every other lifecycle transition is an explicit action.
        if merged.status == "approved", merged.scheduledDate != nil {
            merged.status = "scheduled"
        }
        let conflicts = NativeSchedule.findScheduleConflicts(
            jobs: jobs,
            query: NativeSchedule.ConflictQuery(
                excludeJobId: merged.id,
                date: merged.scheduledDate ?? "",
                start: merged.scheduledStartTime ?? "",
                end: merged.scheduledEndTime,
                laborHours: (merged.laborHours as NSDecimalNumber).doubleValue,
                bufferMinutes: 0
            )
        ).map(\.scheduleJobId)
        return .apply(job: merged, conflictingJobIDs: conflicts)
    }

    // MARK: - Schedule-settings commit (S4)

    /// Owner-supplied settings edit. `nil` leaves the field untouched;
    /// blackout edits are Add-by-id and remove-by-id (removing one preserves
    /// all others and nested unknown fields). `baselineSchedule` pins the
    /// config the draft was opened against; a concurrent owned-field change
    /// refuses instead of silently replacing.
    struct ScheduleSettingsDraft {
        var baselineSchedule: Canonical.ScheduleConfig?
        var workDays: [Int]?
        var workDayStart: String?
        var workDayEnd: String?
        var defaultDurationMinutes: Int?
        var bufferMinutes: Int?
        var slotLeadHours: Int?
        var slotWindowDays: Int?
        var timeZone: String??
        var bookableSlotsEnabled: Bool?
        var blackoutsToAdd: [Canonical.ScheduleBlackout]
        var blackoutIDsToRemove: [String]

        init(
            baselineSchedule: Canonical.ScheduleConfig? = nil,
            workDays: [Int]? = nil,
            workDayStart: String? = nil,
            workDayEnd: String? = nil,
            defaultDurationMinutes: Int? = nil,
            bufferMinutes: Int? = nil,
            slotLeadHours: Int? = nil,
            slotWindowDays: Int? = nil,
            timeZone: String?? = nil,
            bookableSlotsEnabled: Bool? = nil,
            blackoutsToAdd: [Canonical.ScheduleBlackout] = [],
            blackoutIDsToRemove: [String] = []
        ) {
            self.baselineSchedule = baselineSchedule
            self.workDays = workDays
            self.workDayStart = workDayStart
            self.workDayEnd = workDayEnd
            self.defaultDurationMinutes = defaultDurationMinutes
            self.bufferMinutes = bufferMinutes
            self.slotLeadHours = slotLeadHours
            self.slotWindowDays = slotWindowDays
            self.timeZone = timeZone
            self.bookableSlotsEnabled = bookableSlotsEnabled
            self.blackoutsToAdd = blackoutsToAdd
            self.blackoutIDsToRemove = blackoutIDsToRemove
        }
    }

    enum ScheduleSettingsApply {
        case apply(settings: Canonical.Settings)
        /// An owned schedule field changed under the draft.
        case baselineConflict
    }

    /// Merges ONLY owned schedule fields into the latest settings. Booking
    /// credentials (`bookingLink`) and every unknown/preserved field survive
    /// by struct copy — a settings save never rounds hours, drops the token,
    /// or rewrites configuration it does not own.
    static func applyScheduleSettings(
        current: Canonical.Settings,
        draft: ScheduleSettingsDraft
    ) -> ScheduleSettingsApply {
        if let baseline = draft.baselineSchedule,
           !scheduleConfigsMatch(baseline, current.schedule) {
            return .baselineConflict
        }
        var merged = current
        var schedule = merged.schedule ?? Canonical.ScheduleConfig(
            decodingSkipped: ()
        )
        if let workDays = draft.workDays { schedule.workDays = workDays }
        if let start = draft.workDayStart { schedule.workDayStart = start }
        if let end = draft.workDayEnd { schedule.workDayEnd = end }
        if let duration = draft.defaultDurationMinutes { schedule.defaultDurationMinutes = duration }
        if let buffer = draft.bufferMinutes { schedule.bufferMinutes = buffer }
        if let lead = draft.slotLeadHours { schedule.slotLeadHours = lead }
        if let horizon = draft.slotWindowDays { schedule.slotWindowDays = horizon }
        if let timeZone = draft.timeZone { schedule.timeZone = timeZone }
        if let enabled = draft.bookableSlotsEnabled { schedule.bookableSlotsEnabled = enabled }
        var blackouts = schedule.blackouts ?? []
        if !draft.blackoutIDsToRemove.isEmpty {
            let condemned = Set(draft.blackoutIDsToRemove)
            blackouts.removeAll { condemned.contains($0.id) }
        }
        for entry in draft.blackoutsToAdd where !entry.id.isEmpty {
            // Add-only: never replace an existing stable ID implicitly.
            if blackouts.contains(where: { $0.id == entry.id }) { continue }
            blackouts.append(entry)
        }
        schedule.blackouts = blackouts.isEmpty ? nil : blackouts
        merged.schedule = schedule
        return .apply(settings: merged)
    }

    // MARK: - Intake recheck (B3, P3)

    /// Rechecks a task 8.02 plan against CURRENT records before the atomic
    /// commit. It drops a conversion whose request vanished, changed status or
    /// already converted; whose lead job the plan made but whose deterministic
    /// job appeared meanwhile (a concurrent device won the race); or whose
    /// `jbk_` job the plan linked to (already on the device when planned) but
    /// that is gone now. Returns the filtered plan, or nil when nothing remains
    /// (the caller must not write — a no-op enqueues nothing).
    ///
    /// Conversion stamps (`convertedJobId`/`convertedCustomerId`,
    /// `new → converted`) are re-applied onto the CURRENT request rows, so
    /// late-arriving server lifecycle/history survives (D-B3-4). A lead job is
    /// added only where the plan made it; a request linked to a `jbk_` job
    /// already on the device is stamped and the job is never touched (RN:
    /// `utils/storage/bookingConversion.ts:66-111`). Created customers ride
    /// along. The blank-field fill the plan made on an existing customer
    /// (email, phone, address from the booking; RN `upsertCustomerInList`,
    /// `utils/storage/customers.ts:69-86`) is carried onto the CURRENT
    /// customer: only a field still blank there is filled, and a value is
    /// never replaced. Both follow only a conversion that survives.
    ///
    /// Phase 12 (12.00b.2-K fix round 1, review I1 and M1): before, the fill
    /// was always dropped (and never redone, since the request was stamped),
    /// and a request whose `jbk_` job was already on the device was never
    /// stamped. AppStore's intake plans and rechecks with no suspension in
    /// between, so there the recheck keeps everything the plan made.
    ///
    /// Phase 12 (12.00b.2-L, P12-017; Task 12d review M6): `guardSince` is
    /// the pull watermark per table. When given, the drafts for records
    /// already on the server (the request stamp and a repeat customer's fill)
    /// are guarded upserts (`Canonical.MutationItem.ifUnchangedSince`): the
    /// push writes them only onto the row this device pulled, so a customer's
    /// cancel or reschedule request, or another device's edit of the
    /// customer, that reached the server after the pull is never overwritten.
    /// RN pushes whole rows here (`utils/storage/bookingConversion.ts:140-142`).
    /// The lead job and a created customer are new rows and stay plain
    /// upserts. AppStore passes the later of the saved delta cursor and the
    /// initial sync's own watermarks (final review M3,
    /// `AppStore.intakeGuardWatermarks`): the initial sync saves no cursor,
    /// so on a cold launch the saved cursor alone is the previous session's,
    /// older than a booking that arrived while the app was closed, and a
    /// stamp guarded with it was dropped. A table with no watermark at all
    /// (no row of it pulled yet) stays a plain upsert, as RN pushes it.
    static func recheckedIntakePlan(
        _ plan: NativeBookingIntake.Plan,
        currentRequests: [Canonical.BookingRequest],
        currentJobs: [Canonical.Job],
        currentCustomers: [Canonical.Customer],
        guardSince: [String: String]? = nil
    ) -> NativeBookingIntake.Plan? {
        func guarded(_ draft: Canonical.MutationDraft) -> Canonical.MutationDraft {
            guard let since = guardSince?[draft.table], !since.isEmpty else { return draft }
            var next = draft
            next.ifUnchangedSince = since
            return next
        }
        let currentByID = Dictionary(uniqueKeysWithValues: currentRequests.map { ($0.id, $0) })
        let currentJobIDs = Set(currentJobs.map(\.id))
        let planLeadsByID = Dictionary(
            uniqueKeysWithValues: plan.jobs.filter { $0.id.hasPrefix("jbk_") }.map { ($0.id, $0) }
        )
        let planCreatedJobs = Set(plan.createdJobIDs)
        var surviving: [String] = []
        for requestID in plan.convertedRequestIDs {
            guard let current = currentByID[requestID],
                  NativeBookingIntake.isConvertible(current),
                  current.convertedJobId == nil
            else { continue }
            let jobID = "jbk_\(requestID)"
            if planCreatedJobs.contains(jobID) {
                guard !currentJobIDs.contains(jobID), planLeadsByID[jobID] != nil else { continue }
            } else {
                guard currentJobIDs.contains(jobID) else { continue }
            }
            surviving.append(requestID)
        }
        guard !surviving.isEmpty else { return nil }
        let survivors = Set(surviving)
        var nextRequests = currentRequests
        var drafts: [Canonical.MutationDraft] = []
        var linkedCustomerIDs: Set<String> = []
        for index in nextRequests.indices where survivors.contains(nextRequests[index].id) {
            guard let planned = plan.requests.first(where: { $0.id == nextRequests[index].id }) else { continue }
            var stamped = nextRequests[index]
            if stamped.status == "new" { stamped.status = planned.status }
            stamped.convertedJobId = planned.convertedJobId
            stamped.convertedCustomerId = planned.convertedCustomerId
            nextRequests[index] = stamped
            if let customerID = planned.convertedCustomerId { linkedCustomerIDs.insert(customerID) }
            drafts.append(guarded(mutationDraft(table: "bookingRequests", id: stamped.id, record: stamped)))
        }
        var nextJobs = currentJobs
        var createdJobs: [String] = []
        for requestID in plan.convertedRequestIDs where survivors.contains(requestID) {
            let jobID = "jbk_\(requestID)"
            if planCreatedJobs.contains(jobID), let lead = planLeadsByID[jobID] {
                nextJobs.append(lead)
                createdJobs.append(jobID)
                drafts.append(mutationDraft(table: "jobs", id: jobID, record: lead))
            }
        }
        let currentCustomerIDs = Set(currentCustomers.map(\.id))
        var nextCustomers = currentCustomers
        var keptCreatedCustomers: [String] = []
        var filledCustomers: [String] = []
        for customer in plan.customers where linkedCustomerIDs.contains(customer.id) {
            if plan.createdCustomerIDs.contains(customer.id) {
                guard !currentCustomerIDs.contains(customer.id) else { continue }
                nextCustomers.append(customer)
                keptCreatedCustomers.append(customer.id)
                drafts.append(mutationDraft(table: "customers", id: customer.id, record: customer))
                continue
            }
            guard let index = nextCustomers.firstIndex(where: { $0.id == customer.id }) else { continue }
            var merged = nextCustomers[index]
            var filled = false
            if isBlank(merged.email), !isBlank(customer.email) { merged.email = customer.email; filled = true }
            if isBlank(merged.phone), !isBlank(customer.phone) { merged.phone = customer.phone; filled = true }
            if isBlank(merged.address), !isBlank(customer.address) { merged.address = customer.address; filled = true }
            guard filled else { continue }
            nextCustomers[index] = merged
            filledCustomers.append(customer.id)
            drafts.append(guarded(mutationDraft(table: "customers", id: customer.id, record: merged)))
        }
        return NativeBookingIntake.Plan(
            requests: nextRequests,
            jobs: nextJobs,
            customers: nextCustomers,
            requestsChanged: true,
            jobsChanged: !createdJobs.isEmpty,
            customersChanged: !keptCreatedCustomers.isEmpty || !filledCustomers.isEmpty,
            convertedRequestIDs: surviving,
            createdJobIDs: createdJobs,
            createdCustomerIDs: keptCreatedCustomers,
            untouchedRequestIDs: plan.untouchedRequestIDs
                + plan.convertedRequestIDs.filter { !survivors.contains($0) },
            drafts: drafts
        )
    }

    private static func isBlank(_ value: String) -> Bool {
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Reschedule proof (B4, contract §7)

    /// Builds the replacement-schedule publication proof for the CURRENT job
    /// record. `writeStamp` is the local schedule-commit instant (ISO-8601):
    /// `Canonical.Job` carries no `updatedAt`, so the stamp the server
    /// compares (`updated_at ≥ proof.updatedAt`) is the durable local write
    /// recorded in pending work (`acceptProof` passes a lower bound instead,
    /// because the accept makes no write). Never invent server state here.
    static func rescheduleProof(
        job: Canonical.Job,
        writeStamp: String
    ) -> NativeScheduleProof? {
        guard let date = job.scheduledDate, !date.isEmpty,
              let start = job.scheduledStartTime, !start.isEmpty,
              !writeStamp.isEmpty
        else { return nil }
        return NativeScheduleProof(jobId: job.id, updatedAt: writeStamp, date: date, start: start)
    }

    /// Phase 12 (12.00b.2-J, P12-015): the proof for the owner's accept of a
    /// customer's reschedule request, from the job's CURRENT schedule. The
    /// owner moved the job first (RN's order) and the accept writes nothing,
    /// so there is no local write to stamp, and `Canonical.Job` carries no
    /// server `updated_at`. `updatedAt` is the request's `createdAt`: every
    /// converted job was created from the request after it existed, so its
    /// server `updated_at` meets that bound, and contract §7's
    /// in-transaction `(date, start)` check stays the one that refuses a
    /// superseded schedule. A `createdAt` that is not an ISO-8601 instant
    /// falls back to the epoch. Nil when the job has no date and start time
    /// (native never sends a proof-less resolve, §7 step 4).
    static func acceptProof(job: Canonical.Job, request: Canonical.BookingRequest) -> NativeScheduleProof? {
        let stamp = isISOInstant(request.createdAt) ? request.createdAt : "1970-01-01T00:00:00.000Z"
        return rescheduleProof(job: job, writeStamp: stamp)
    }

    private static func isISOInstant(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 40 else { return false }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) != nil || ISO8601DateFormatter().date(from: value) != nil
    }

    /// Refuses when a superseding schedule edit landed after proof
    /// generation: the proof's date/start must still match the current job.
    static func proofMatchesCurrentJob(_ proof: NativeScheduleProof, job: Canonical.Job?) -> Bool {
        guard let job, job.id == proof.jobId else { return false }
        return job.scheduledDate == proof.date && job.scheduledStartTime == proof.start
    }

    // MARK: - Link-authority reconciliation (B2, P1, contract §6)

    /// Adopts a local display copy ONLY when a fresh `status` read proves it
    /// current. A present-but-stale token needs the same recovery handling
    /// as a missing one — never a share URL.
    static func mayAdoptDisplayToken(displayToken: String?, status: NativeBookingLinkStatus) -> Bool {
        guard let displayToken, !displayToken.isEmpty else { return false }
        return status.tokenValid
    }

    static func mayAdoptPortalDisplayToken(displayToken: String?, status: NativePortalLinkStatus) -> Bool {
        guard let displayToken, !displayToken.isEmpty else { return false }
        return status.tokenValid
    }

    /// `already_exists` on a stale Create: refresh authority and adopt only a
    /// matching current display copy — never an implicit rotate.
    static func adoptAfterAlreadyExists(displayToken: String?, status: NativePortalLinkStatus) -> Bool {
        mayAdoptPortalDisplayToken(displayToken: displayToken, status: status)
    }

    // MARK: - Local commit boundary

    enum LocalCommitOutcome: Equatable {
        /// Snapshot + queue both durable.
        case committed
        /// The snapshot write failed: nothing was enqueued, nothing published.
        case snapshotFailed
        /// The snapshot is durable but the queue write failed: recovery work
        /// was staged in the pending-work store (never a silent drop).
        case queueFailedRecoveryStaged
    }

    /// Durable local-first boundary used by every 8.08 commit: the canonical
    /// snapshot is saved before the queue is touched, and a queue failure
    /// never rolls back or hides the saved records — recovery is staged
    /// instead. Mirrors the `commitCustomerMerge` boundary.
    static func commitLocal(
        saveSnapshot: () throws -> Void,
        publishToQueue: () throws -> Void,
        stageRecovery: () throws -> Void
    ) -> LocalCommitOutcome {
        do {
            try saveSnapshot()
        } catch {
            return .snapshotFailed
        }
        do {
            try publishToQueue()
            return .committed
        } catch {
            do {
                try stageRecovery()
            } catch {
                // Staging itself failed: the snapshot is still durable and
                // the next edit re-enqueues; the caller surfaces the sync
                // diagnostic. Never claim the queue publish succeeded.
            }
            return .queueFailedRecoveryStaged
        }
    }

    enum StagedCommitOutcome: Equatable {
        /// Staged, snapshot saved and applied, queue written, stage cleared.
        case committed
        /// The stage could not be written, so the commit did not start:
        /// nothing was saved and nothing was queued.
        case stageFailed
        /// The snapshot save failed: nothing is saved or queued, and the
        /// stage was cleared.
        case snapshotFailed
        /// The snapshot is saved and the queue write failed (or did not
        /// happen): the staged batch stays, and a launch or activation pass
        /// replays it.
        case queueFailedStaged
        /// The snapshot is saved (and the batch queued) but the in-memory
        /// state could not be applied from it. The records are durable and
        /// reach the server; the screen state catches up at the next launch
        /// or pull. The caller reports the local commit as failed.
        case savedNotApplied
    }

    /// The booking-intake boundary (P12-028, fix plan F10). The batch is
    /// staged durably BEFORE the snapshot is saved, so every point after it
    /// (a failed queue write, the app ending mid-commit) leaves a durable
    /// record of what must still reach the server. A failed stage aborts the
    /// commit: success is never reported for a batch with no durable trace.
    /// The stage is cleared only when nothing durable is left to send: the
    /// save failed (nothing was saved), or the queue holds the batch. A failed
    /// APPLY after a successful save never clears it before the queue write.
    /// Save and apply stay one closure because the save-first pin
    /// (`SaveRollbackTests`) requires `apply(X)` to directly follow
    /// `repository.save(X)`.
    static func commitLocalStaged(
        stageBatch: () throws -> Void,
        saveAndApply: () throws -> Void,
        snapshotLanded: () -> Bool,
        publishToQueue: () throws -> Void,
        clearStage: () -> Void
    ) -> StagedCommitOutcome {
        do { try stageBatch() } catch { return .stageFailed }
        var applied = true
        do {
            try saveAndApply()
        } catch {
            // `saveAndApply` saves and then applies, so a throw may come from
            // either. When the saved snapshot holds the batch's records the
            // save landed and only the apply failed: keep going.
            guard snapshotLanded() else {
                clearStage()
                return .snapshotFailed
            }
            applied = false
        }
        do {
            try publishToQueue()
        } catch {
            return .queueFailedStaged
        }
        clearStage()
        return applied ? .committed : .savedNotApplied
    }

    /// The drafts of a staged batch that still need queuing (P12-028).
    /// A draft is replayed only when the record on the device still equals
    /// what was staged: a later edit of that record queued its own, newer
    /// upsert (and replaying the old one could overwrite it), and a record
    /// that is gone has nothing to send. A draft whose record the queue
    /// already holds is skipped, so a replay after a partial or repeated
    /// pass queues nothing twice. "Already holds" means the queue's upsert for
    /// that record carries the staged payload: an OLDER queued upsert of the
    /// same record is replaced (last writer wins), never mistaken for it.
    static func stagedDraftsToReplay(
        _ staged: [NativeScheduleBookingStagedDraft],
        currentPayload: (_ table: String, _ id: String) -> Canonical.JSONValue?,
        queued: [Canonical.MutationItem]
    ) -> [Canonical.MutationDraft] {
        staged.compactMap { item in
            let queuedForRecord = queued.filter { $0.table == item.table && $0.recordId == item.recordId }
            // The queue already holds exactly this change.
            if queuedForRecord.contains(where: { $0.op == .upsert && $0.payload == item.payload }) { return nil }
            guard let current = currentPayload(item.table, item.recordId) else { return nil }
            // The record is still what was staged: queue it, replacing any
            // older queued copy (last writer wins).
            if current == item.payload { return item.draft }
            // The record changed since. A guarded draft (the request stamp, a
            // repeat customer's fill) is still safe to send when nothing else
            // is queued for it: a pull may have replaced the local copy with
            // the server's unstamped one, and the guard makes the server drop
            // the write if the row moved. Anything queued for the record is a
            // later edit's, which must not be replaced.
            if item.ifUnchangedSince != nil && queuedForRecord.isEmpty { return item.draft }
            return nil
        }
    }

    // MARK: - Durable admin operation IDs (P12-027)

    /// The server keeps an operation's replay row for 30 days (contract
    /// §1.3). A pending operation is retried only while that row can still
    /// exist: after it, a retry would be a NEW mutation under an old ID.
    static let adminOperationReplayWindow: TimeInterval = 29 * 24 * 60 * 60

    struct PendingAdminOperation: Equatable {
        var target: String
        var action: String
        var enabled: Bool?
        var operationId: String
        var stagedAt: String
    }

    enum AdminOperationPlan: Equatable {
        /// No usable pending operation: stage and send this new ID.
        case fresh(String)
        /// The same action, unfinished: retry its exact ID.
        case reuse(String)
        /// A different action while one may be in flight on the server. It
        /// must be retried (or expire) first, so a second capability is never
        /// issued beside one whose outcome is unknown.
        case blocked(pendingAction: String)
    }

    static func planAdminOperation(
        pending: PendingAdminOperation?,
        action: String,
        enabled: Bool?,
        proposedID: String,
        now: Date
    ) -> AdminOperationPlan {
        guard let pending else { return .fresh(proposedID) }
        if let staged = ISO8601DateFormatter().date(from: pending.stagedAt)
            ?? fractionalISO.date(from: pending.stagedAt),
           now.timeIntervalSince(staged) > adminOperationReplayWindow {
            return .fresh(proposedID)
        }
        if pending.action == action && pending.enabled == enabled { return .reuse(pending.operationId) }
        return .blocked(pendingAction: pending.action)
    }

    private static let fractionalISO: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// Failures that happen before a request is sent, or that the server
    /// answered without committing. Any other failure (a transport error, an
    /// unreadable response, a failed local save after the server committed)
    /// leaves the operation pending.
    private static let definiteAdminFailures: Set<String> = [
        "not-signed-in", "session", "configuration", "status-unavailable", "owner-changed",
        "already-running", "invalid-request", "rejectedSession", "rateLimited", "notFound",
        "operationConflict", "invalidConfiguration", "malformedSession", "operation-pending", "persist",
    ]

    /// Whether the outcome of an administration call settles its operation.
    /// `createdThisCall` is false for a retry of an earlier unknown outcome:
    /// such a retry that fails before sending says nothing new about the
    /// original request, so it stays pending (an operation conflict is the
    /// exception: the ID can never succeed).
    static func adminOutcomeSettlesOperation(failureReason: String?, unknown: Bool, createdThisCall: Bool) -> Bool {
        if unknown { return false }
        guard let reason = failureReason else { return true }
        if reason == "operationConflict" { return true }
        return definiteAdminFailures.contains(reason) && createdThisCall
    }

    // MARK: - Private helpers

    static func normalizedDate(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return NativeSchedule.isValidDate(value) ? value : nil
    }

    static func normalizedTime(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return NativeSchedule.isValidTime(value) ? value : nil
    }

    static func scheduleConfigsMatch(_ lhs: Canonical.ScheduleConfig?, _ rhs: Canonical.ScheduleConfig?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case let (l?, r?):
            return l.timeZone == r.timeZone
                && l.workDays == r.workDays
                && l.workDayStart == r.workDayStart
                && l.workDayEnd == r.workDayEnd
                && l.defaultDurationMinutes == r.defaultDurationMinutes
                && l.bufferMinutes == r.bufferMinutes
                && l.slotLeadHours == r.slotLeadHours
                && l.slotWindowDays == r.slotWindowDays
                && l.bookableSlotsEnabled == r.bookableSlotsEnabled
                && l.blackouts == r.blackouts
        default: return false
        }
    }

    static func mutationDraft<Record: Encodable>(
        table: String,
        id: String,
        record: Record
    ) -> Canonical.MutationDraft {
        let data = try! JSONEncoder().encode(record)
        let payload = try! JSONDecoder().decode(Canonical.JSONValue.self, from: data)
        return Canonical.MutationDraft(table: table, op: .upsert, recordId: id, payload: payload)
    }
}

private extension Canonical.Job {
    /// An empty baseline status means "no lifecycle assertion" (legacy
    /// callers that only pinned the schedule fields).
    func baselineStatusMatches(_ baseline: String) -> Bool {
        baseline.isEmpty || status == baseline
    }
}

private extension Canonical.ScheduleConfig {
    /// Construction for settings that never had a schedule block: every
    /// owned field stays nil so the first save writes only what the draft
    /// owns. All-optional decoding of `{}` cannot fail for this shape.
    init(decodingSkipped: Void) {
        self = try! JSONDecoder().decode(
            Canonical.ScheduleConfig.self,
            from: Data("{}".utf8)
        )
    }
}

extension Canonical.ScheduleBlackout: Equatable {
    public static func == (lhs: Canonical.ScheduleBlackout, rhs: Canonical.ScheduleBlackout) -> Bool {
        lhs.id == rhs.id && lhs.start == rhs.start && lhs.end == rhs.end && lhs.reason == rhs.reason
    }
}

// MARK: - Incomplete-work persistence and recovery (S3, S4, B2–B4, P1, P3)

/// One unit of owner-bound incomplete work: a server-acknowledged mutation
/// whose local mirror or queue publication did not finish, or a reschedule
/// proof awaiting its exact job-mutation acknowledgment. Recovery never
/// repeats a committed server mutation: mirror items re-apply display data
/// and re-enqueue; proof items resume at the verification step.
struct NativeScheduleBookingPendingWork: Codable, Equatable, Sendable {
    enum Kind: Codable, Equatable, Sendable {
        /// Display-only booking-link mirror (`token` nil for `set_enabled`).
        case bookingMirror(token: String?, enabled: Bool, revision: Int, operationId: String)
        /// Display-only portal mirror for one customer.
        case portalMirror(customerId: String, token: String?, enabled: Bool?, operationId: String)
        /// Reschedule proof awaiting exact job-mutation acknowledgment.
        case rescheduleProof(requestId: String, proof: NativeScheduleProof, writeStamp: String)
        /// Phase 12 (P12-028, fix plan F10): the exact batch of record
        /// upserts a local commit is about to queue, staged BEFORE the
        /// snapshot is saved. It is the only durable trace of records that
        /// are saved locally but not yet queued for the server (a queue-write
        /// failure, or the app ending between the snapshot save and the
        /// queue write). Unlike a mirror, this is business data: rollback
        /// readiness counts it as waiting changes.
        case stagedBatch(drafts: [NativeScheduleBookingStagedDraft], stage: String)
        /// Phase 12 (P12-027, fix plan F8): an owner-bound link-administration
        /// mutation (mint, rotate, enable, disable) whose outcome is not
        /// known. Staged BEFORE the request is sent and cleared only once the
        /// outcome is definite, so a timeout, a lost response or a relaunch
        /// retries the SAME operation ID (the server replays its stored
        /// response for 30 days instead of minting a second capability).
        /// `target` is `booking` or `portal/<customerId>`; `action` is
        /// `mint`, `set_enabled` or `rotate`. Display-only: it holds no token.
        case adminOperation(target: String, action: String, enabled: Bool?, operationId: String, stagedAt: String)
    }

    var kind: Kind
    /// Exact verified owner binding that owns this work. Items whose binding
    /// no longer matches are dropped, never adopted by another account.
    var ownerBinding: String

    init(kind: Kind, ownerBinding: String) {
        self.kind = kind
        self.ownerBinding = ownerBinding
    }
}

/// A codable copy of a queued record upsert (`Canonical.MutationDraft` itself
/// is not `Codable`). Only upserts are staged: the local commits that stage
/// are record creations and merges.
// `@unchecked`: `Canonical.JSONValue` is a value-type enum but not declared Sendable.
struct NativeScheduleBookingStagedDraft: Codable, Equatable, @unchecked Sendable {
    var table: String
    var recordId: String
    var payload: Canonical.JSONValue?
    var ifUnchangedSince: String?

    init(_ draft: Canonical.MutationDraft) {
        table = draft.table
        recordId = draft.recordId
        payload = draft.payload
        ifUnchangedSince = draft.ifUnchangedSince
    }

    var draft: Canonical.MutationDraft {
        Canonical.MutationDraft(
            table: table, op: .upsert, recordId: recordId, payload: payload,
            ifUnchangedSince: ifUnchangedSince
        )
    }
}

/// File-backed per-device store for 8.08 pending work. The document is keyed
/// by owner binding at the item level so an account switch can scrub exactly
/// the departing account's items without touching anything else.
struct NativeScheduleBookingPendingWorkStore: Sendable {
    struct Document: Codable {
        var schemaVersion: Int = 1
        var items: [NativeScheduleBookingPendingWork] = []
    }

    var fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func load() -> [NativeScheduleBookingPendingWork] {
        guard let data = try? Data(contentsOf: fileURL),
              let document = try? JSONDecoder().decode(Document.self, from: data),
              document.schemaVersion == 1
        else { return [] }
        return document.items
    }

    /// Phase 12 (12.06 fix round 1): `load()` for the rollback-readiness
    /// check, which must never read a file it cannot decode as "no work".
    /// No file is no work; a file that does not read, does not decode or
    /// carries another schema version is nil (unreadable).
    func loadIfReadable() -> [NativeScheduleBookingPendingWork]? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        guard let data = try? Data(contentsOf: fileURL),
              let document = try? JSONDecoder().decode(Document.self, from: data),
              document.schemaVersion == 1
        else { return nil }
        return document.items
    }

    func save(_ items: [NativeScheduleBookingPendingWork]) throws {
        let document = Document(items: items)
        let data = try JSONEncoder().encode(document)
        let parent = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }

    /// Stages one item, replacing any earlier item for the same owner-bound
    /// target (last-writer-wins per target, mirroring the mutation queue).
    func stage(_ item: NativeScheduleBookingPendingWork) throws {
        var items = load().filter { !replaces($0, with: item) }
        items.append(item)
        try save(items)
    }

    func remove(matching predicate: (NativeScheduleBookingPendingWork) -> Bool) throws {
        try save(load().filter { !predicate($0) })
    }

    /// Drops every item owned by `binding`. Called on the account boundary
    /// so no other account can inherit and act on this account's pending
    /// capability work.
    func scrubOwnerBoundWork(binding: String) throws {
        try save(load().filter { $0.ownerBinding != binding })
    }

    func removeAll() throws {
        try save([])
    }

    private func replaces(
        _ existing: NativeScheduleBookingPendingWork,
        with staged: NativeScheduleBookingPendingWork
    ) -> Bool {
        guard existing.ownerBinding == staged.ownerBinding else { return false }
        switch (existing.kind, staged.kind) {
        case (.bookingMirror, .bookingMirror):
            return true
        case let (.portalMirror(lID, _, _, _), .portalMirror(rID, _, _, _)):
            return lID == rID
        case let (.rescheduleProof(lReq, _, _), .rescheduleProof(rReq, _, _)):
            return lReq == rReq
        case let (.adminOperation(lTarget, _, _, _, _), .adminOperation(rTarget, _, _, _, _)):
            // One pending operation per target; a retry stages the same one.
            return lTarget == rTarget
        case (.stagedBatch, .stagedBatch):
            // Distinct commits stage distinct batches; an identical batch
            // staged twice (a retry of the same commit) is one item.
            return existing == staged
        default:
            return false
        }
    }
}
