import Foundation

struct NativeEstimateFollowUpReminder: Equatable, Sendable {
    /// Phase 32 (spec 2026-10-03 §6.7): both kinds share the `est_` prefix,
    /// the `estimate_follow_up` tap type and the coordinator.
    enum Kind: Equatable, Sendable {
        /// `est_<jobId>`: 9:00 local, three calendar days after the send.
        case followUp
        /// `est_exp_<jobId>`: 9:00 local, two calendar days before `validUntil`.
        case expiry
    }

    let jobID: String
    let customerName: String
    let jobTitle: String
    let fireDate: Date
    var kind: Kind = .followUp
    /// Phase 32: the job's inclusive valid-until date, or `nil` when undated.
    var validUntil: String? = nil
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
    ///
    /// Phase 32 (spec 2026-10-03 §6.7): a dated estimate also gets an
    /// `.expiry` reminder at 9:00 local on `validUntil − 2 days`, scheduled
    /// only when that instant is in the future and after the three-day
    /// reminder's. A short validity folds into the three-day copy instead,
    /// which names the date.
    static func upcomingReminders(
        jobs: [Canonical.Job],
        now: Date,
        calendar: Calendar = .current
    ) -> [NativeEstimateFollowUpReminder] {
        jobs.enumerated().flatMap { offset, job -> [(Int, NativeEstimateFollowUpReminder)] in
            guard job.status == "estimate_sent" else { return [] }
            let validUntil = datedValidUntil(job)
            let followUpFire = sentDate(for: job, calendar: calendar)
                .flatMap { reminderDate(for: $0, calendar: calendar) }
            var reminders: [(Int, NativeEstimateFollowUpReminder)] = []
            if let followUpFire, followUpFire > now {
                reminders.append((offset, .init(
                    jobID: job.id,
                    customerName: job.customerName,
                    jobTitle: job.title,
                    fireDate: followUpFire,
                    kind: .followUp,
                    validUntil: validUntil
                )))
            }
            if let validUntil,
               let expiryFire = expiryReminderDate(validUntil: validUntil, calendar: calendar),
               expiryFire > now,
               followUpFire.map({ expiryFire > $0 }) ?? true {
                reminders.append((offset, .init(
                    jobID: job.id,
                    customerName: job.customerName,
                    jobTitle: job.title,
                    fireDate: expiryFire,
                    kind: .expiry,
                    validUntil: validUntil
                )))
            }
            return reminders
        }
        .sorted {
            if $0.1.fireDate != $1.1.fireDate { return $0.1.fireDate < $1.1.fireDate }
            return $0.0 < $1.0
        }
        .map(\.1)
    }

    /// Phase 32: `est_<jobId>` for the three-day reminder, `est_exp_<jobId>`
    /// for the expiry reminder. Both fall inside the coordinator's `est_`
    /// prefix, and both carry `jobId` in the payload, so taps route alike.
    static func notificationIdentifier(jobID: String, kind: NativeEstimateFollowUpReminder.Kind) -> String {
        switch kind {
        case .followUp: "est_\(jobID)"
        case .expiry: "est_exp_\(jobID)"
        }
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
                    identifier: notificationIdentifier(jobID: reminder.jobID, kind: reminder.kind),
                    jobID: reminder.jobID,
                    title: notificationTitle(reminder),
                    body: notificationBody(reminder, calendar: calendar),
                    fireDate: reminder.fireDate
                )
            }
    }

    private static func notificationTitle(_ reminder: NativeEstimateFollowUpReminder) -> String {
        switch reminder.kind {
        case .followUp: "Estimate follow-up — \(reminder.customerName)"
        case .expiry: "Estimate expiring — \(reminder.customerName)"
        }
    }

    /// Phase 32: dated copy names the date, phrased for the local day the
    /// notification fires on ("expires" through `validUntil`, then "expired").
    private static func notificationBody(_ reminder: NativeEstimateFollowUpReminder, calendar: Calendar) -> String {
        let sentence = "Estimate for \"\(reminder.jobTitle)\" sent \(followUpDays) days ago with no response."
        guard let validUntil = reminder.validUntil else {
            return "\(sentence) Tap to follow up."
        }
        let date = NativeQuoteExpiry.displayDate(validUntil, style: .short)
        switch reminder.kind {
        case .expiry:
            return "Your estimate for \"\(reminder.jobTitle)\" expires in \(NativeQuoteExpiry.expiryReminderLeadDays) days (\(date)). Tap to follow up or extend it."
        case .followUp:
            let fireDay = NativeQuoteExpiry.today(now: reminder.fireDate, calendar: calendar)
            let phrase = fireDay > validUntil ? "It expired \(date)." : "It expires \(date)."
            return "\(sentence) \(phrase) Tap to follow up."
        }
    }

    static func draft(
        job: Canonical.Job,
        customerName: String,
        customerPhone: String,
        customerEmail: String,
        businessName: String,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> NativeEstimateFollowUpDraft? {
        guard job.status == "estimate_sent" else { return nil }
        let trimmedName = customerName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return nil }
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
            body: message(job: job, customerFirstName: firstName(trimmedName), now: now, calendar: calendar)
        )
    }

    /// Phase 32 (spec 2026-10-03 §6.7): the "Let the customer know" notice
    /// after an owner extends a sent estimate. `job` is the extended job, so
    /// its `estimateValidUntil` is the new date; `approvalLink` is the
    /// customer's (unchanged) approval link when the estimate has one. Opens
    /// in the same reviewed composer as the follow-up draft.
    static func extensionDraft(
        job: Canonical.Job,
        approvalLink: URL?,
        customerName: String,
        customerPhone: String,
        customerEmail: String,
        businessName: String,
        calendar: Calendar = .current
    ) -> NativeEstimateFollowUpDraft? {
        guard job.status == "estimate_sent", job.approval?.decision == nil else { return nil }
        let trimmedName = customerName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return nil }
        let amount = undecidedOptionsFromTotal(job).map { "from \(quote($0))" } ?? quote(job.estimateTotal)
        let extended = datedValidUntil(job).map {
            "I've extended your estimate for \(job.title) (\(amount)) until \(NativeQuoteExpiry.displayDate($0, style: .long))."
        } ?? "I've extended your estimate for \(job.title) (\(amount)), and it no longer expires."
        let action = approvalLink.map { "You can review and approve it here: \($0.absoluteString)" }
            ?? "Just reply to approve and I'll get you on the schedule."
        return .init(
            jobID: job.id,
            customerName: trimmedName,
            customerPhone: customerPhone.trimmingCharacters(in: .whitespacesAndNewlines),
            customerEmail: customerEmail.trimmingCharacters(in: .whitespacesAndNewlines),
            jobTitle: job.title,
            estimateTotal: job.estimateTotal,
            sentDate: sentDate(for: job, calendar: calendar),
            emailSubject: "Your estimate from \(businessName) has been extended"
                .trimmingCharacters(in: .whitespacesAndNewlines),
            body: "Hi \(firstName(trimmedName)), good news — \(extended) \(action)"
        )
    }

    private static func firstName(_ trimmedName: String) -> String {
        trimmedName.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? trimmedName
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
    ///
    /// Phase 25 (spec 2026-10-02 §6.4): while good/better/best options are
    /// undecided the copy names the options and quotes the lowest tier
    /// ("from $X"). Accepted options read as a normal single estimate.
    ///
    /// Phase 32 (spec 2026-10-03 §6.7): a dated estimate names its date —
    /// "It's valid until …" (options: "They're valid until …") while open on
    /// `now`'s local day, or the expired copy offering an updated estimate
    /// once past. An undated estimate keeps the earlier copy exactly.
    static func message(
        job: Canonical.Job,
        customerFirstName: String,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> String {
        let state = NativeQuoteExpiry.state(job: job, today: NativeQuoteExpiry.today(now: now, calendar: calendar))
        if case let .expired(validUntil, _)? = state {
            return "Hi \(customerFirstName), just checking in on the estimate I sent over for "
                + "\(job.title). It expired on \(NativeQuoteExpiry.displayDate(validUntil, style: .long)), "
                + "but I'm happy to put together an updated one — want me to take another look?"
        }
        var openValidUntil: String?
        if case let .open(validUntil, _)? = state { openValidUntil = validUntil }
        if let fromTotal = undecidedOptionsFromTotal(job) {
            let validity = openValidUntil.map {
                " They're valid until \(NativeQuoteExpiry.displayDate($0, style: .long))."
            } ?? ""
            return "Hi \(customerFirstName), just checking in on your quote options for "
                + "\(job.title) (from \(quote(fromTotal))).\(validity) Happy to answer any "
                + "questions — want me to get you on the schedule?"
        }
        let validity = openValidUntil.map {
            " It's valid until \(NativeQuoteExpiry.displayDate($0, style: .long))."
        } ?? ""
        return "Hi \(customerFirstName), just checking in on the estimate I sent over for "
            + "\(job.title) (\(quote(job.estimateTotal))).\(validity) Happy to answer any "
            + "questions — want me to get you on the schedule?"
    }

    /// Phase 32: the job's `estimateValidUntil` when it is a real date.
    private static func datedValidUntil(_ job: Canonical.Job) -> String? {
        guard let validUntil = job.estimateValidUntil,
              NativeQuoteExpiry.addDays(validUntil, 0) != nil
        else { return nil }
        return validUntil
    }

    /// Phase 32: 9:00 local on `validUntil − expiryReminderLeadDays`.
    private static func expiryReminderDate(validUntil: String, calendar: Calendar) -> Date? {
        guard let day = NativeQuoteExpiry.addDays(validUntil, -NativeQuoteExpiry.expiryReminderLeadDays) else {
            return nil
        }
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: parts[0],
            month: parts[1],
            day: parts[2],
            hour: 9
        ))
    }

    /// Phase 25: the lowest tier total of undecided quote options, or `nil`
    /// for a single-total estimate, accepted options, or options without
    /// tiers. Computed here rather than in `NativeQuoteOptions.swift`, which
    /// several runners that compile this file do not include.
    private static func undecidedOptionsFromTotal(_ job: Canonical.Job) -> Decimal? {
        guard let options = job.quoteOptions, options.acceptance == nil else { return nil }
        return options.tiers.map(\.estimateTotal).min()
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
