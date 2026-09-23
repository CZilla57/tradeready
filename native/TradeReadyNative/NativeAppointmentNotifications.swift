import Foundation

struct NativeAppointmentReminder: Equatable, Sendable {
    let jobID: String
    let customerName: String
    let fireDate: Date
    let appointmentDate: String
}

/// Pure appointment-confirmation policy. Scheduling is deliberately kept in
/// the shared notification coordinator; this type only selects and describes
/// future, user-reviewed reminders.
/// Analytics instrumentation is intentionally deferred to Phase 11.
enum NativeAppointmentNotifications {
    private static let activeStatuses: Set<String> = ["approved", "scheduled", "in_progress"]

    static func fireDate(
        for scheduledDate: String,
        calendar: Calendar = .current
    ) -> Date? {
        let fields = scheduledDate.split(separator: "-", omittingEmptySubsequences: false)
        guard fields.count == 3,
              let year = Int(fields[0]), let month = Int(fields[1]), let day = Int(fields[2])
        else { return nil }
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = 17
        components.minute = 0
        components.second = 0
        components.nanosecond = 0
        guard let appointmentDay = calendar.date(from: components),
              calendar.dateComponents([.year, .month, .day], from: appointmentDay).year == year,
              calendar.dateComponents([.year, .month, .day], from: appointmentDay).month == month,
              calendar.dateComponents([.year, .month, .day], from: appointmentDay).day == day
        else { return nil }
        return calendar.date(byAdding: .day, value: -1, to: appointmentDay)
    }

    static func reminders(
        jobs: [Canonical.Job],
        customers: [Canonical.Customer],
        enabled: Bool,
        now: Date,
        calendar: Calendar = .current
    ) -> [NativeAppointmentReminder] {
        guard enabled else { return [] }
        return jobs.enumerated().compactMap { offset, job -> (Int, NativeAppointmentReminder)? in
            guard activeStatuses.contains(job.status),
                  let scheduledDate = job.scheduledDate,
                  let fireDate = fireDate(for: scheduledDate, calendar: calendar),
                  fireDate > now,
                  let customer = resolveCustomer(job: job, customers: customers),
                  !customer.phone.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      || !customer.email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return nil }
            return (offset, .init(
                jobID: job.id,
                customerName: customer.name,
                fireDate: fireDate,
                appointmentDate: scheduledDate
            ))
        }
        .sorted { lhs, rhs in
            lhs.1.fireDate == rhs.1.fireDate ? lhs.0 < rhs.0 : lhs.1.fireDate < rhs.1.fireDate
        }
        .map(\.1)
    }

    static func notificationPlan(
        jobs: [Canonical.Job],
        customers: [Canonical.Customer],
        enabled: Bool,
        now: Date,
        calendar: Calendar = .current
    ) -> [NativeNotificationPlanItem] {
        reminders(jobs: jobs, customers: customers, enabled: enabled, now: now, calendar: calendar)
            .map { reminder in
                let date = displayDate(reminder.appointmentDate, calendar: calendar)
                return NativeNotificationPlanItem(
                    identifier: "appt_\(reminder.jobID)",
                    jobID: reminder.jobID,
                    title: "Confirm tomorrow's job — \(reminder.customerName)",
                    body: "Tap to send \(reminder.customerName) a confirmation for \(date).",
                    route: .appointmentConfirm(jobID: reminder.jobID),
                    fireDate: reminder.fireDate
                )
            }
    }

    /// Notification taps may still open a job after its visible appointment
    /// button has disappeared. Only the exact signed-in job is required here;
    /// the review screen performs the current contact/draft check. Fails
    /// closed only for a missing job or a non-exact (foreign/signed-out)
    /// workspace. Final-review I1 (RN parity, contract §9.6): an archived job
    /// opens normally — `reminders` above still schedules `appt_` for it (RN
    /// `utils/archive.ts`: notifications deliberately still see archived
    /// records) and RN's `appointment_confirm` tap navigates to JobDetail
    /// with no archive check. (The `est_` route keeps its own recorded
    /// estimate_sent + not-archived rule in `NativeEstimateFollowUp`.)
    static func canOpenNotification(
        exactOwnerWorkspace: Bool,
        signedIn: Bool,
        job: Canonical.Job?
    ) -> Bool {
        guard exactOwnerWorkspace, signedIn, job != nil else { return false }
        return true
    }

    private static func resolveCustomer(
        job: Canonical.Job,
        customers: [Canonical.Customer]
    ) -> Canonical.Customer? {
        customers.first { $0.id == job.customerId }
            ?? customers.first { $0.name.caseInsensitiveCompare(job.customerName) == .orderedSame }
    }

    private static func displayDate(_ value: String, calendar: Calendar) -> String {
        let fields = value.split(separator: "-").compactMap { Int($0) }
        guard fields.count == 3,
              let date = calendar.date(from: .init(year: fields[0], month: fields[1], day: fields[2]))
        else { return value }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEEE, MMMM d"
        return formatter.string(from: date)
    }
}
