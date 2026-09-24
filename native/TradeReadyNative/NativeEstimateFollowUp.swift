import Foundation

struct NativeEstimateFollowUpReminder: Equatable, Sendable {
    let jobID: String
    let customerName: String
    let jobTitle: String
    let fireDate: Date
}

struct NativeEstimateFollowUpNotification: Equatable, Sendable, Identifiable {
    let identifier: String
    let jobID: String
    let title: String
    let body: String
    let fireDate: Date

    var id: String { identifier }
}

struct NativeEstimateFollowUpDraft: Equatable, Sendable, Identifiable {
    let jobID: String
    let customerName: String
    let customerPhone: String
    let customerEmail: String
    let jobTitle: String
    let estimateTotal: Decimal
    let sentDate: Date?
    let emailSubject: String
    let body: String

    var id: String { jobID }
}

/// Pure estimate follow-up policy ported from `utils/estimateFollowUps.ts`.
///
/// This module only selects eligible work and produces editable copy. It does
/// not schedule notifications, open a composer, record analytics, or mutate a
/// job. Keeping those boundaries explicit prevents a background refresh from
/// becoming an unattended customer-contact path.
enum NativeEstimateFollowUp {
    static let followUpDays = 3

    /// `estimateSentAt` deliberately wins even when malformed. Falling back to
    /// an older approval timestamp in that case could unexpectedly re-arm an
    /// estimate whose newest send stamp is corrupt.
    static func sentDate(
        for job: Canonical.Job,
        calendar: Calendar = .current
    ) -> Date? {
        guard let raw = job.estimateSentAt ?? job.approval?.sentAt else { return nil }
        return parseStoredDate(raw, calendar: calendar)
    }

    /// Future one-shot reminders, scheduled for 9:00 a.m. local time three
    /// calendar days after the send date. Once that instant passes, a later
    /// derivation cannot recreate the reminder.
    static func upcomingReminders(
        jobs: [Canonical.Job],
        now: Date,
        calendar: Calendar = .current
    ) -> [NativeEstimateFollowUpReminder] {
        jobs.enumerated().compactMap { offset, job -> (Int, NativeEstimateFollowUpReminder)? in
            guard job.status == "estimate_sent",
                  let sent = sentDate(for: job, calendar: calendar),
                  let fireDate = reminderDate(for: sent, calendar: calendar),
                  fireDate > now
            else { return nil }
            return (
                offset,
                .init(
                    jobID: job.id,
                    customerName: job.customerName,
                    jobTitle: job.title,
                    fireDate: fireDate
                )
            )
        }
        .sorted {
            if $0.1.fireDate != $1.1.fireDate { return $0.1.fireDate < $1.1.fireDate }
            return $0.0 < $1.0
        }
        .map(\.1)
    }

    /// Persistent Today-row eligibility. This intentionally overlaps the
    /// pending reminder on day three before 9:00 a.m., matching the React
    /// Native behavior.
    static func awaitingResponse(
        jobs: [Canonical.Job],
        now: Date,
        calendar: Calendar = .current
    ) -> [Canonical.Job] {
        let threshold = TimeInterval(followUpDays * 86_400)
        return jobs.filter { job in
            guard job.status == "estimate_sent",
                  let sent = sentDate(for: job, calendar: calendar)
            else { return false }
            return now.timeIntervalSince(sent) >= threshold
        }
    }

    static func awaitingResponseLabel(count: Int) -> String {
        "\(count) estimate\(count == 1 ? "" : "s") awaiting response"
    }

    static func notificationPlan(
        jobs: [Canonical.Job],
        now: Date,
        enabled: Bool,
        maximumCount: Int = 60,
        calendar: Calendar = .current
    ) -> [NativeEstimateFollowUpNotification] {
        guard enabled, maximumCount > 0 else { return [] }
        return upcomingReminders(jobs: jobs, now: now, calendar: calendar)
            .prefix(maximumCount)
            .map { reminder in
                .init(
                    identifier: "est_\(reminder.jobID)",
                    jobID: reminder.jobID,
                    title: "Estimate follow-up — \(reminder.customerName)",
                    body: "Estimate for \"\(reminder.jobTitle)\" sent \(followUpDays) days ago with no response. Tap to follow up.",
                    fireDate: reminder.fireDate
                )
            }
    }

    static func draft(
        job: Canonical.Job,
        customerName: String,
        customerPhone: String,
        customerEmail: String,
        businessName: String,
        calendar: Calendar = .current
    ) -> NativeEstimateFollowUpDraft? {
        guard job.status == "estimate_sent" else { return nil }
        let trimmedName = customerName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return nil }
        let firstName = trimmedName.split(whereSeparator: \.isWhitespace).first.map(String.init)
            ?? trimmedName
        return .init(
            jobID: job.id,
            customerName: trimmedName,
            customerPhone: customerPhone.trimmingCharacters(in: .whitespacesAndNewlines),
            customerEmail: customerEmail.trimmingCharacters(in: .whitespacesAndNewlines),
            jobTitle: job.title,
            estimateTotal: job.estimateTotal,
            sentDate: sentDate(for: job, calendar: calendar),
            emailSubject: "Checking in on your estimate — \(businessName)"
                .trimmingCharacters(in: .whitespacesAndNewlines),
            body: message(job: job, customerFirstName: firstName)
        )
    }

    /// Task 11.06 (P8, contract C11 resolved): an ARCHIVED `estimate_sent`
    /// job opens like any other. `upcomingReminders` (like RN
    /// `selectEstimateFollowUps`) still schedules `est_` for archived jobs,
    /// because RN `utils/archive.ts` keeps notifications seeing them, and RN's
    /// `estimate_follow_up` tap routes with no archive check. So a delivered
    /// `est_` notification is never a dead tap, the rule every other family
    /// already follows (Phase 10 contract §9.6). Only a missing job, an
    /// answered estimate or a non-exact/signed-out workspace fail closed.
    static func canOpenNotification(
        exactOwnerWorkspace: Bool,
        signedIn: Bool,
        job: Canonical.Job?
    ) -> Bool {
        guard exactOwnerWorkspace, signedIn, let job else { return false }
        return job.status == "estimate_sent"
    }

    static func notificationJobID(userInfo: [AnyHashable: Any]) -> String? {
        guard userInfo["type"] as? String == "estimate_follow_up",
              let rawJobID = userInfo["jobId"] as? String
        else { return nil }
        let jobID = rawJobID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !jobID.isEmpty, jobID.utf8.count <= 256 else { return nil }
        return jobID
    }

    /// Default copy only. The eventual UI must keep it editable and require a
    /// user-reviewed Apple composer or explicit copy action.
    static func message(
        job: Canonical.Job,
        customerFirstName: String
    ) -> String {
        "Hi \(customerFirstName), just checking in on the estimate I sent over for "
            + "\(job.title) (\(quote(job.estimateTotal))). Happy to answer any "
            + "questions — want me to get you on the schedule?"
    }

    private static func reminderDate(for sent: Date, calendar: Calendar) -> Date? {
        let sentComponents = calendar.dateComponents([.year, .month, .day], from: sent)
        guard let year = sentComponents.year,
              let month = sentComponents.month,
              let day = sentComponents.day,
              let localNine = calendar.date(
                from: DateComponents(
                    calendar: calendar,
                    timeZone: calendar.timeZone,
                    year: year,
                    month: month,
                    day: day,
                    hour: 9
                )
              )
        else { return nil }
        return calendar.date(byAdding: .day, value: followUpDays, to: localNine)
    }

    private static func parseStoredDate(_ raw: String, calendar: Calendar) -> Date? {
        if let dateOnly = parseDateOnly(raw, calendar: calendar) { return dateOnly }
        if looksLikeDateOnly(raw) { return nil }
        return isoWithFractional.date(from: raw) ?? iso.date(from: raw)
    }

    private static func looksLikeDateOnly(_ raw: String) -> Bool {
        raw.count == 10 && raw[raw.index(raw.startIndex, offsetBy: 4)] == "-"
            && raw[raw.index(raw.startIndex, offsetBy: 7)] == "-"
    }

    private static func parseDateOnly(_ raw: String, calendar: Calendar) -> Date? {
        guard looksLikeDateOnly(raw) else { return nil }
        let parts = raw.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts.allSatisfy({ $0.allSatisfy(\.isNumber) }),
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]),
              let result = calendar.date(
                from: DateComponents(
                    calendar: calendar,
                    timeZone: calendar.timeZone,
                    year: year,
                    month: month,
                    day: day
                )
              )
        else { return nil }
        let roundTrip = calendar.dateComponents([.year, .month, .day], from: result)
        guard roundTrip.year == year, roundTrip.month == month, roundTrip.day == day else { return nil }
        return result
    }

    private static func quote(_ amount: Decimal) -> String {
        var source = amount
        var rounded = Decimal()
        NSDecimalRound(&rounded, &source, 2, .plain)

        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.maximumFractionDigits = 2
        formatter.minimumFractionDigits = rounded == Decimal(Int(truncating: rounded as NSNumber)) ? 0 : 2
        return formatter.string(from: rounded as NSNumber) ?? "$0"
    }

    private static let isoWithFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let iso = ISO8601DateFormatter()
}
