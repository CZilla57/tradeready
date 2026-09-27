import Foundation

/// Pure booking/portal attention selector (Phase 8, task 8.02; requirements
/// B3, P3). Ports `utils/bookingAttention.ts` onto canonical records and adds
/// the states task 8.00 decision D-B3-1 requires: unconverted active bookings
/// must surface for inspection so a confirmed booking can never disappear
/// from owner intake, and a converted booking whose job is gone must surface
/// as missing rather than silently clearing.
///
/// Row model:
///
/// - `rescheduleRequested`: actionable. A `reschedule_requested` slot booking
///   (converted or not) carries the customer's latest reschedule note.
/// - `portalChange`: actionable. An unhandled `portal_change_requested` row
///   carries `jobRef` and the server-templated details. Dismissal is an
///   explicit `handledAt` stamp (`stampedHandled`), never job-state driven.
/// - `cancelled`: actionable while the converted job still holds the slot on
///   the calendar (exact RN current-job comparison). Clearing, moving,
///   archiving or terminal-ing the job self-dismisses the row.
/// - `missingJob`: actionable. A booked-family request points at
///   `convertedJobId` (or a portal change at `jobRef`) with no matching job —
///   e.g. the job was deleted on another device. RN drops these silently;
///   native surfaces them so the owner can reconcile.
/// - `unconvertedActive`: inspection. A convertible request with no
///   `convertedJobId` (`new`, unconverted `booked`/`confirmed`) that has no
///   more specific actionable row. `reschedule_requested` rows already
///   surface as `rescheduleRequested`, so they are not duplicated here.
/// - Handled rows (`converted`, stamped slot bookings outside the conditions
///   above, handled portal changes) and unknown statuses produce no rows and
///   stay intact/inert.
///
/// Phase 12 (12.00b.2-L fix round 1, Task 12e review I1): a booking-family
/// request with no `convertedJobId` whose lead job `jbk_<requestId>` is on the
/// device is treated as linked to that job (`linkedJobID`). Intake makes the
/// lead job and stamps the request together, but the stamp is a guarded push
/// that is dropped when the customer changed the request on the server first
/// (defect `P12-017`), and a cancelled request is never stamped again. The
/// cancel then shows as `cancelled` on the lead job while that job still holds
/// the slot, a reschedule request opens that job, and a booking with a job is
/// not `unconvertedActive`.
///
/// Unknown/preserved server fields are never read or rewritten here; rows
/// hold references to the original request records.
public enum NativeBookingAttention {
    public enum Kind: String, Equatable {
        case rescheduleRequested
        case portalChange
        case cancelled
        case missingJob
        case unconvertedActive
    }

    public struct Row: Equatable {
        public var kind: Kind
        public var request: Canonical.BookingRequest
        public var jobID: String?
        public var note: String?

        public init(kind: Kind, request: Canonical.BookingRequest, jobID: String?, note: String? = nil) {
            self.kind = kind
            self.request = request
            self.jobID = jobID
            self.note = note
        }

        public static func == (lhs: Row, rhs: Row) -> Bool {
            lhs.kind == rhs.kind && lhs.request.id == rhs.request.id
                && lhs.jobID == rhs.jobID && lhs.note == rhs.note
        }
    }

    /// Job statuses whose schedules are history — never hold a slot.
    /// Mirrors `TERMINAL_STATUSES` in `utils/scheduleSmarts.ts`.
    public static let terminalJobStatuses: Set<String> = [
        "complete", "invoiced", "paid", "declined",
    ]

    public static func select(
        requests: [Canonical.BookingRequest],
        jobs: [Canonical.Job]
    ) -> [Row] {
        let jobsByID = Dictionary(jobs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var rows: [Row] = []
        for request in requests {
            // Portal change rows carry no kind/slot — handled before the
            // booked-family guards below.
            if request.status == "portal_change_requested" {
                guard isUnhandled(request) else { continue }
                if let ref = request.jobRef, !ref.isEmpty, jobsByID[ref] == nil {
                    rows.append(Row(kind: .missingJob, request: request, jobID: ref,
                                    note: request.details.isEmpty ? nil : request.details))
                } else {
                    rows.append(Row(kind: .portalChange, request: request,
                                    jobID: request.jobRef,
                                    note: request.details.isEmpty ? nil : request.details))
                }
                continue
            }
            guard request.kind == "booked" else {
                // Free-text intake states: only unconverted `new` needs eyes
                // (D-B3-1 inspection); everything else is handled or inert.
                if request.status == "new" && request.convertedJobId == nil {
                    rows.append(Row(kind: .unconvertedActive, request: request,
                                    jobID: nil, note: nil))
                }
                continue
            }
            let linked = linkedJobID(request, jobsByID: jobsByID)
            if request.status == "reschedule_requested" {
                if let stamped = request.convertedJobId, jobsByID[stamped] == nil {
                    rows.append(Row(kind: .missingJob, request: request, jobID: stamped,
                                    note: lastRescheduleNote(request)))
                } else {
                    rows.append(Row(kind: .rescheduleRequested, request: request,
                                    jobID: linked,
                                    note: lastRescheduleNote(request)))
                }
                continue
            }
            if request.status == "cancelled" || request.status == "declined" {
                guard let stamped = linked else { continue }
                guard let job = jobsByID[stamped] else {
                    // The linked job is gone — surface for reconciliation
                    // instead of silently clearing the row.
                    rows.append(Row(kind: .missingJob, request: request, jobID: stamped,
                                    note: nil))
                    continue
                }
                if jobStillHoldsSlot(request: request, job: job) {
                    rows.append(Row(kind: .cancelled, request: request, jobID: stamped,
                                    note: nil))
                }
                continue
            }
            if linked == nil
                && (request.status == "new"
                    || NativeBookingIntake.convertibleSlotStatuses.contains(request.status)) {
                rows.append(Row(kind: .unconvertedActive, request: request,
                                jobID: nil, note: nil))
                continue
            }
            if let stamped = request.convertedJobId, jobsByID[stamped] == nil
                && (request.status == "booked" || request.status == "confirmed") {
                rows.append(Row(kind: .missingJob, request: request, jobID: stamped,
                                note: nil))
            }
        }
        let rank: [Kind: Int] = [
            .rescheduleRequested: 0, .portalChange: 1, .cancelled: 2,
            .missingJob: 3, .unconvertedActive: 4,
        ]
        return rows.sorted {
            if $0.kind != $1.kind { return (rank[$0.kind] ?? 9) < (rank[$1.kind] ?? 9) }
            let lDate = $0.request.slot?.date ?? ""
            let rDate = $1.request.slot?.date ?? ""
            if lDate != rDate { return lDate < rDate }
            return $0.request.id < $1.request.id
        }
    }

    /// Pure `handledAt` dismissal plan for a portal change request. Returns
    /// the stamped copy, or nil when there is nothing to do (already
    /// handled). Existence checks and the synced save stay in the store
    /// layer (task 8.08); a save re-enqueues the whole collection, so a nil
    /// result must not write.
    public static func stampedHandled(
        _ request: Canonical.BookingRequest,
        nowISO: String
    ) -> Canonical.BookingRequest? {
        guard isUnhandled(request) else { return nil }
        var next = request
        next.handledAt = nowISO
        return next
    }

    public static func isUnhandled(_ request: Canonical.BookingRequest) -> Bool {
        (request.handledAt ?? "").isEmpty
    }

    /// Fix round 1 (Task 12e review I1): the job a booking-family request is
    /// linked to: its stamp, or, when the stamp never landed, the lead job
    /// intake made for it, whose id is deterministic (`jbk_<requestId>`, RN
    /// `utils/storage/bookingConversion.ts:66`). RN reads the stamp only
    /// (`utils/bookingAttention.ts:33-35`, `:67-70`) and never reaches this
    /// state: its whole-row stamp push overwrote the customer's change instead.
    /// A stamp always wins; nil when neither is there.
    static func linkedJobID(_ request: Canonical.BookingRequest, jobsByID: [String: Canonical.Job]) -> String? {
        if let stamped = request.convertedJobId { return stamped }
        let lead = "jbk_\(request.id)"
        return jobsByID[lead] == nil ? nil : lead
    }

    // MARK: - Private

    /// True while the converted job still occupies the booked slot (exact RN
    /// current-job comparison: same date AND start, not archived, not
    /// terminal).
    static func jobStillHoldsSlot(request: Canonical.BookingRequest, job: Canonical.Job) -> Bool {
        guard let slot = request.slot else { return false }
        guard (job.archivedAt ?? "").isEmpty else { return false }
        guard !terminalJobStatuses.contains(job.status) else { return false }
        return job.scheduledDate == slot.date && job.scheduledStartTime == slot.start
    }

    private static func lastRescheduleNote(_ request: Canonical.BookingRequest) -> String? {
        let notes = (request.history ?? []).filter {
            $0.actor == "customer" && $0.event == "request_reschedule" && ($0.note?.isEmpty == false)
        }
        return notes.last?.note
    }
}
