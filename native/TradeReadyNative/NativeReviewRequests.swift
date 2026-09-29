import Foundation

/// Batch 1 — pure review-request policy.
///
/// Mirrors `utils/reviewRequest.ts` without any I/O, notification-center
/// access, or store access. Batch 2 wires these pure decisions into the
/// completion hook, the `review_` scheduling selector
/// (`NativeNotificationPlanItem`, owned by the Batch 0 coordinator in
/// `NativeEstimateFollowUpNotifications.swift`), and the review UI.
///
/// Semantics ported 1:1 from RN:
/// - Schedule only on a transition *into* `complete`, with the toggle on, a
///   reachable contact (phone or email), and no existing record (one-shot).
/// - Delay `max(1, delayHours || 3) * 3600` — nil/zero fall back to 3h.
/// - Identifier `review_<jobId>`, payload type `review_request`.
/// - `sent` cancels the pending notification, but a cancel failure must never
///   block the sent record (callers: attempt cancel, swallow errors, then
///   apply `recordsMarkingSent` unconditionally).
/// - A manual send for a never-scheduled job creates a sent record from the
///   live-customer fallback so the one-shot still applies.
/// - Only a successful or unreportable send consumes the one-shot
///   (`opened && outcome != .notSent`); cancel/draft/no-open does not.
/// - Live customer contact is preferred; the saved record is a fallback for
///   when the customer row is gone.
/// - Sending is blocked only when the template still references
///   `{googleReviewLink}` and the link is blank; an empty link is otherwise
///   cleaned out of the rendered message (dangling colon + blank lines).

struct NativeReviewRequestRecord: Codable, Equatable, Sendable {
    var jobId: String
    var customerId: String
    var customerName: String
    var customerPhone: String
    var customerEmail: String
    /// ISO-8601 instant the one-shot was armed (or created, for manual sends).
    var scheduledAt: String
    /// ISO-8601 instant the request was sent; nil while pending.
    var sentAt: String?
}

struct NativeReviewRequestFallbackContact: Equatable, Sendable {
    var customerId: String
    var customerName: String
    var customerPhone: String
    var customerEmail: String
}

struct NativeReviewRequestDraft: Equatable, Sendable {
    let jobID: String
    let jobTitle: String
    let customerID: String
    let customerName: String
    let customerPhone: String
    let customerEmail: String
    let message: String
    let missingLink: Bool
    let fallback: NativeReviewRequestFallbackContact
}

enum NativeReviewSendOutcome: String, Equatable, Sendable {
    case sent
    case unknown
    case notSent
}

enum NativeReviewRequests {
    static let notificationPayloadType = "review_request"
    static let defaultDelayHours = 3

    /// `max(1, delayHours || 3) * 3600`, matching
    /// `reviewRequestDelaySeconds` in `utils/reviewRequest.ts`. The `||`
    /// treats nil *and* zero as absent (both Settings editors coerce blank to
    /// the 3h default), so zero maps to 3h rather than the 1h floor.
    static func delaySeconds(delayHours: Int?) -> TimeInterval {
        let hours: Int
        if let delayHours, delayHours != 0 {
            hours = delayHours
        } else {
            hours = defaultDelayHours
        }
        return TimeInterval(max(1, hours) * 3600)
    }

    /// True when the rendered message would be missing its review link: the
    /// template still references `{googleReviewLink}` but no link is set.
    /// False when the placeholder was removed or a URL was hardcoded.
    static func messageMissingLink(template: String, googleReviewLink: String) -> Bool {
        template.contains("{googleReviewLink}")
            && googleReviewLink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func buildMessage(
        template: String,
        businessName: String,
        customerName: String,
        googleReviewLink: String
    ) -> String {
        var rendered = template
            .replacingOccurrences(of: "{businessName}", with: businessName)
            .replacingOccurrences(of: "{customerName}", with: customerName)
        if googleReviewLink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Drop the placeholder along with a dangling colon and the blank
            // line it would otherwise leave, so the preview reads cleanly.
            // (Sending is blocked in this state via `messageMissingLink`.)
            rendered = replacing(
                pattern: ":?[ \\t]*\\n*\\{googleReviewLink\\}\\n*[ \\t]*",
                in: rendered,
                with: "\n\n"
            )
            rendered = replacing(pattern: "\\n{3,}", in: rendered, with: "\n\n")
            return rendered.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return rendered.replacingOccurrences(of: "{googleReviewLink}", with: googleReviewLink)
    }

    static func notificationIdentifier(jobId: String) -> String {
        "review_\(jobId)"
    }

    static func notificationTitle() -> String {
        "Time to ask for a review!"
    }

    static func notificationBody(customerName: String, jobTitle: String) -> String {
        "Send \(customerName) a review request for \"\(jobTitle)\"."
    }

    /// Whether the completion transition should arm the one-shot. `previous`
    /// and `current` are raw `JobStatus` values so this stays dependency-free;
    /// Batch 2 passes the real transition (only `.complete` entry qualifies).
    /// Re-completing an already-complete job must not re-arm.
    static func shouldSchedule(
        previousStatusRaw: String,
        currentStatusRaw: String,
        reviewRequestEnabled: Bool,
        customerPhone: String,
        customerEmail: String,
        hasExistingRecord: Bool
    ) -> Bool {
        guard currentStatusRaw == "complete", previousStatusRaw != "complete" else { return false }
        guard reviewRequestEnabled else { return false }
        guard hasContact(phone: customerPhone, email: customerEmail) else { return false }
        guard !hasExistingRecord else { return false }
        return true
    }

    static func hasContact(phone: String, email: String) -> Bool {
        !phone.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The `review_` plan item for the Batch 0 coordinator. The fire date is
    /// `scheduledAt + delaySeconds(delayHours)` so rebuilds after the sweep's
    /// cancel-all never move the original fire instant (RN parity with the
    /// `utils/notifications.ts` rebuild branch).
    static func planItem(
        jobId: String,
        customerName: String,
        jobTitle: String,
        scheduledAt: Date,
        delayHours: Int?
    ) -> NativeNotificationPlanItem {
        NativeNotificationPlanItem(
            identifier: notificationIdentifier(jobId: jobId),
            jobID: jobId,
            title: notificationTitle(),
            body: notificationBody(customerName: customerName, jobTitle: jobTitle),
            route: .reviewRequest(jobID: jobId),
            fireDate: scheduledAt.addingTimeInterval(delaySeconds(delayHours: delayHours))
        )
    }

    /// Only a real (or unreportable-platform) send consumes the one-shot.
    /// Cancelling or draft-saving the composer, or a composer that never
    /// opened, leaves both the sent record and the pending reminder intact.
    static func consumesOneShot(opened: Bool, outcome: NativeReviewSendOutcome) -> Bool {
        opened && outcome != .notSent
    }

    /// Live customer contact drives every send; the record is sent-state truth
    /// plus a last-resort snapshot for when the customer row itself is gone.
    static func preferredContact(
        liveName: String,
        livePhone: String,
        liveEmail: String,
        record: NativeReviewRequestRecord?
    ) -> (name: String, phone: String, email: String) {
        if hasContact(phone: livePhone, email: liveEmail) {
            return (liveName, livePhone, liveEmail)
        }
        guard let record else { return (liveName, livePhone, liveEmail) }
        if hasContact(phone: record.customerPhone, email: record.customerEmail) {
            return (record.customerName, record.customerPhone, record.customerEmail)
        }
        return (liveName, livePhone, liveEmail)
    }

    /// Pure record update for marking a request sent. Mirrors
    /// `markReviewRequestSent`: an existing record wins (only `sentAt` is
    /// refreshed — the schedule-time contact snapshot is kept); otherwise the
    /// live-customer `fallback` creates a sent record so the one-shot block
    /// applies to manual sends too; with neither, records are unchanged.
    /// Callers attempt the `review_<jobId>` cancel first and swallow its
    /// error — a failed cancel must not block this update.
    static func recordsMarkingSent(
        _ records: [NativeReviewRequestRecord],
        jobId: String,
        fallback: NativeReviewRequestFallbackContact?,
        nowISO: String
    ) -> [NativeReviewRequestRecord] {
        if records.contains(where: { $0.jobId == jobId }) {
            return records.map { record in
                guard record.jobId == jobId else { return record }
                var updated = record
                updated.sentAt = nowISO
                return updated
            }
        }
        guard let fallback else { return records }
        return records + [NativeReviewRequestRecord(
            jobId: jobId,
            customerId: fallback.customerId,
            customerName: fallback.customerName,
            customerPhone: fallback.customerPhone,
            customerEmail: fallback.customerEmail,
            scheduledAt: nowISO,
            sentAt: nowISO
        )]
    }

    private static func replacing(pattern: String, in value: String, with replacement: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return value }
        return regex.stringByReplacingMatches(
            in: value,
            range: NSRange(value.startIndex..., in: value),
            withTemplate: replacement
        )
    }
}
