import Foundation

// Task 11.04 (A1, A2): the spoken text for every Siri intent outcome.
//
// App target only (`N/Intents/`), Foundation-only so host tests
// (native/run-app-intent-queue-tests.sh) assert each intent's answer. The
// RN wording (`targets/widget/_shared/SiriIntents.swift`) is kept, plus the
// contract's native dialogs: the §4.5 sign-in refusal, the §3.3 stale
// refusal and the §4.3 queue-cap refusal.

enum SiriIntentDialogs {
    static let signInFirst = "Open TradeReady and sign in first."
    static let refreshSchedule = "Open TradeReady to refresh your schedule."
    static let tooManyPending = "TradeReady has too many pending actions \u{2014} open the app to sync."
    static let couldNotSave = "TradeReady couldn't save that \u{2014} open the app and try again."
    /// Read-only intents (Next Job, Outstanding) never save, so a container
    /// failure there must not claim a save failed.
    static let couldNotRead = "TradeReady couldn't check that \u{2014} open the app and try again."
    static let noUpcomingJobs = "You have no upcoming jobs scheduled."
    static let badOdometer = "That odometer reading doesn't look right. Try again with a number of miles."

    /// The refusal for a failure shared by every writer.
    static func failure(_ failure: WidgetIntentFailure) -> String {
        switch failure {
        case .signInRequired: return signInFirst
        case .queueFull: return tooManyPending
        case .unavailable, .malformedQueue, .duplicateConflict, .invalidAction, .writeFailed:
            return couldNotSave
        }
    }

    /// The refusal for a read-only intent: no snapshot or tag is the §4.5
    /// sign-in refusal; anything else (no container) is a read failure.
    static func readFailure(_ failure: WidgetIntentFailure) -> String {
        failure == .signInRequired ? signInFirst : couldNotRead
    }

    static func nextJob(
        _ outcome: WidgetNextJobOutcome,
        now: Date,
        timeZone: TimeZone = .current,
        locale: Locale = .current
    ) -> String {
        switch outcome {
        case .failed(let failure): return readFailure(failure)
        case .stale: return refreshSchedule
        case .noUpcomingJob: return noUpcomingJobs
        case .nextJob(let job):
            var message = "Your next job is \(job.title) for \(job.customerName), "
                + whenLabel(job, now: now, timeZone: timeZone, locale: locale)
            if !job.address.isEmpty { message += ", at \(job.address)" }
            return message + "."
        }
    }

    static func startTrip(_ outcome: WidgetStartTripOutcome, odometerStart: Double) -> String {
        switch outcome {
        case .failed(.signInRequired): return signInFirst
        case .failed: return "I couldn't start the trip. Open TradeReady and try again."
        case .alreadyRunning: return "A trip is already running. Say 'stop my trip' to finish it."
        case .invalidOdometer: return badOdometer
        case .started(replacedStale: true, _):
            return "Your previous trip was never finished \u{2014} starting a new one."
        case .started(replacedStale: false, _):
            return "Trip started at \(formatMiles(odometerStart)) miles."
        }
    }

    static func stopTrip(_ outcome: WidgetStopTripOutcome) -> String {
        switch outcome {
        case .failed(.signInRequired): return signInFirst
        case .failed(.queueFull): return tooManyPending
        case .failed: return "Something went wrong saving the trip \u{2014} try again."
        case .noTrip: return "No trip is running."
        case .discardedStale:
            return "That trip started more than a day ago, so it wasn't logged. Start a new trip next time."
        case .invalidOdometer: return badOdometer
        case .logged(let miles, _): return "Logged \(formatMiles(miles)) miles."
        }
    }

    static func onMyWay(_ outcome: WidgetOnMyWayOutcome) -> String {
        switch outcome {
        case .failed(.signInRequired): return signInFirst
        case .failed: return "I couldn't open that. Open TradeReady and try again."
        case .stale: return refreshSchedule
        case .noUpcomingJob: return noUpcomingJobs
        case .opening(_, let customerName, _): return "Opening a message for \(customerName)."
        }
    }

    static func clockIn(_ outcome: WidgetClockInOutcome) -> String {
        switch outcome {
        case .failed(let failure): return self.failure(failure)
        case .stale: return refreshSchedule
        case .alreadyClockedIn: return "You're already clocked in."
        case .noUpcomingJob: return "No upcoming job to clock into."
        case .clockedIn(let jobTitle, _): return "Clocked in to \(jobTitle)."
        }
    }

    static func clockOut(_ outcome: WidgetClockOutOutcome) -> String {
        switch outcome {
        case .failed(let failure): return self.failure(failure)
        case .notClockedIn: return "You're not clocked in."
        case .clockedOut: return "Clocked out."
        }
    }

    static func logExpense(_ outcome: WidgetLogExpenseOutcome) -> String {
        switch outcome {
        case .failed(let failure): return self.failure(failure)
        case .invalidAmount: return "That amount doesn't look right."
        case .logged(let amount, let category, _):
            return "Logged $\(formatDollars(amount)) for \(category.label)."
        }
    }

    static func outstanding(_ outcome: WidgetOutstandingOutcome) -> String {
        switch outcome {
        case .failed(let failure): return readFailure(failure)
        case .stale: return refreshSchedule
        case .nothingOutstanding: return "Nothing outstanding \u{2014} you're fully collected."
        case .owed(let total): return "You're owed $\(formatDollars(total)) in outstanding invoices."
        }
    }

    // MARK: Formatting (RN `siriWhenLabel`, `siriFormatMiles`, `siriFormatDollars`)

    /// "today at 9:00 AM", "tomorrow", "Monday, August 10 at 2:30 PM". The
    /// date strings are local-frame, parsed in the device calendar (FA-039).
    static func whenLabel(
        _ job: WidgetSnapshot.NextJob,
        now: Date,
        timeZone: TimeZone = .current,
        locale: Locale = .current
    ) -> String {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = timeZone
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

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let startDay = calendar.startOfDay(for: start)
        let today = calendar.startOfDay(for: now)
        let dayDelta = calendar.dateComponents([.day], from: today, to: startDay).day
        let dayLabel: String
        switch dayDelta {
        case 0: dayLabel = "today"
        case 1: dayLabel = "tomorrow"
        default:
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.timeZone = timeZone
            formatter.dateFormat = "EEEE, MMMM d"
            dayLabel = formatter.string(from: start)
        }
        guard hasTime else { return dayLabel }
        let timeFormatter = DateFormatter()
        timeFormatter.locale = locale
        timeFormatter.timeZone = timeZone
        timeFormatter.dateStyle = .none
        timeFormatter.timeStyle = .short
        return "\(dayLabel) at \(timeFormatter.string(from: start))"
    }

    /// "12" for whole miles, "12.4" otherwise. Rounds first (RN v1 bug).
    static func formatMiles(_ miles: Double) -> String {
        let rounded = (miles * 10).rounded() / 10
        if rounded == rounded.rounded() { return String(format: "%.0f", rounded) }
        return String(format: "%.1f", rounded)
    }

    /// "12" for whole dollars, "12.50" otherwise. Rounds to cents first.
    static func formatDollars(_ amount: Double) -> String {
        let rounded = (amount * 100).rounded() / 100
        if rounded == rounded.rounded() { return String(format: "%.0f", rounded) }
        return String(format: "%.2f", rounded)
    }
}
