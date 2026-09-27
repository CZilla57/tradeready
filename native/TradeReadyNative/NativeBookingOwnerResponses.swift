import Foundation

/// Phase 12 (12.00b.2-L): the outcomes of the owner's responses to a booking
/// request (Decline, and accepting a reschedule request), what they wait for
/// (P12-017), and what the acting screen shows. The accept's types moved here
/// unchanged from `AppStore.swift` (Task 12c review M8), apart from review
/// M1, M4 and M5.
extension AppStore {
    /// Phase 12 (12.00b.2-J, P12-015): the owner's accept of a customer's
    /// reschedule request from a request row (`acceptBookingReschedule`).
    /// Every case has a notice for the acting screen (`ownerNotice`). The
    /// accept makes no schedule write and sends nothing before the job's
    /// current schedule is known, so it has no `scheduleConflict` or
    /// `superseded` case; the server's `schedule_changed` is `needsReview`.
    enum BookingRescheduleAcceptOutcome: Equatable {
        /// The server confirmed the booking for the job's current schedule.
        case confirmed(BookingRescheduleConfirmation)
        /// The request has no job on this device: no proof, nothing sent.
        case notLinkedToJob
        /// The job has no date and start time, so there is no proof to send
        /// (contract §7 step 4: native never sends a proof-less resolve).
        case jobUnscheduled
        /// A change to the job (contract §7 step 1) or to the request has not
        /// reached the server yet: still queued, or refused and waiting in
        /// Settings › Cloud Sync (Phase 12 12.00b.2-L, review M1). Nothing was
        /// sent; the staged proof stays.
        case awaitingAck(OwnerResponseWait)
        /// The request no longer asks for a reschedule (the pull, or a 409
        /// `invalid_state`), or the server's job schedule differs (409
        /// `schedule_changed`, status still `reschedule_requested`).
        case needsReview(currentStatus: String)
        /// The resolve may have committed. Never resent automatically.
        case unknownOutcome
        /// The request is gone (the pull, or a 404).
        case missing
        /// The account changed during an await: nothing was applied.
        case accountChanged
        /// Local data is read-only: nothing was applied.
        case readOnly
        /// Any other refusal from the respond client.
        case failed(NativeBookingResponseError)

        /// The acting screen's alert. `actionLabel` is the button the owner
        /// tapped there. Failures use RN's alert title ("Couldn't update
        /// booking", `screens/TodayScreen.tsx:557`). RN shows nothing on
        /// success; native names the time the booking is now confirmed for,
        /// so a tap before moving the job is never silent. A booking another
        /// device already confirmed (or a retry the server had already
        /// committed) is not a failure (12.00b.2-L, review M4).
        func ownerNotice(actionLabel: String) -> BookingRescheduleNotice {
            let failure = "Couldn't update booking"
            let tapAgain = "tap \u{201C}\(actionLabel)\u{201D} again"
            switch self {
            case let .confirmed(confirmation):
                let when = NativeTodayBriefing.formatDisplayDate(confirmation.date) + ", "
                    + NativeTodayBriefing.formatTimeRange(confirmation.start, confirmation.end)
                var message = confirmation.keptOriginalTime
                    ? "The job wasn't moved, so the booking is confirmed for its original time, \(when)."
                    : "The booking is confirmed for the job's new time, \(when)."
                if !confirmation.savedLocally {
                    message += " This device couldn't save the change yet. Pull down to refresh."
                }
                return .init(title: "Booking updated", message: message)
            case .notLinkedToJob:
                // 12.00b.2-L (review M5): since P12-016 a booking becomes a
                // job at launch and at each activation whose sync completes
                // (`runBookingIntakeIfPossible`); a pull to refresh does not
                // convert (RN parity). A converted booking whose job was
                // deleted never converts again.
                return .init(title: failure, message: "This booking doesn't have a job on this device yet. "
                             + "New bookings become jobs the next time you open the app and it syncs, so try again then. "
                             + "If you deleted its job, decline the booking or contact the customer instead.")
            case .jobUnscheduled:
                return .init(title: failure, message: "Give the job a date and start time first, then \(tapAgain).")
            case .awaitingAck(.queued):
                return .init(title: failure, message: "Your latest changes haven't reached the server yet. "
                             + "Check your connection, then \(tapAgain).")
            case .awaitingAck(.refused):
                return .init(title: failure, message: "The server refused a change to this booking or its job. "
                             + "Review it in Settings \u{203A} Cloud Sync, then \(tapAgain).")
            case .needsReview("confirmed"):
                return .init(title: "Booking confirmed", message: "This booking is already confirmed.")
            case let .needsReview(currentStatus):
                let message = switch currentStatus {
                case "declined": "This booking was already declined."
                case "cancelled": "The customer cancelled this booking."
                case "reschedule_requested":
                    "The job's time on the server doesn't match this device. "
                        + "Pull down to refresh, check the job, then \(tapAgain)."
                default: "This booking changed on another device. Pull down to refresh and check it."
                }
                return .init(title: failure, message: message)
            case .unknownOutcome:
                return .init(title: failure, message: "We couldn't tell whether the booking was updated. "
                             + "Check your connection, then pull down to refresh before trying again.")
            case .missing:
                return .init(title: failure, message: "This booking request wasn't found. "
                             + "It may have been removed on another device.")
            case .accountChanged:
                return .init(title: failure, message: "The signed-in account changed, so nothing was saved on this device.")
            case .readOnly:
                return .init(title: failure, message: "This device can't save changes right now. Nothing changed on this device.")
            case let .failed(error):
                // RN's fallback (`utils/bookingRespond.ts:40`).
                return .init(title: failure, message: error.errorDescription ?? "Please try again.")
            }
        }
    }

    struct BookingRescheduleConfirmation: Equatable {
        var status: String
        var alreadyApplied: Bool
        /// The job's schedule the proof carried.
        var date: String
        var start: String
        var end: String?
        /// The job was still at the request's original slot.
        var keptOriginalTime: Bool
        /// False when the local copy could not be saved; the next pull
        /// brings the server's row.
        var savedLocally: Bool
    }

    /// What the acting screen shows after the owner's accept, or (Phase 12
    /// 12.00b.2-L) decline.
    struct BookingRescheduleNotice: Equatable {
        var title: String
        var message: String
    }

    /// Why an owner response was not sent: a change to the request (or, for
    /// the accept, to its job) has not reached the server. Sent anyway, the
    /// server would write the response first and the change after it, over
    /// the status and history the server wrote.
    enum OwnerResponseWait: Equatable {
        /// Still queued: offline, or its push failed.
        case queued
        /// The server refused it; it waits in Settings › Cloud Sync, where a
        /// Retry would push it.
        case refused
    }
}

extension AppStore.OwnerResponseOutcome {
    /// The acting screen's alert after the owner's decline, or nil when the
    /// server declined the booking. RN clears the row without an alert and
    /// otherwise shows "Couldn't update booking" with a message
    /// (`screens/TodayScreen.tsx:554-558`). `actionLabel` is the button the
    /// owner tapped there.
    func declineNotice(actionLabel: String) -> AppStore.BookingRescheduleNotice? {
        let failure = "Couldn't update booking"
        let tapAgain = "tap \u{201C}\(actionLabel)\u{201D} again"
        switch self {
        case .applied:
            return nil
        case .awaitingAck(.queued):
            return .init(title: failure, message: "Your latest changes haven't reached the server yet. "
                         + "Check your connection, then \(tapAgain).")
        case .awaitingAck(.refused):
            return .init(title: failure, message: "The server refused a change to this booking. "
                         + "Review it in Settings \u{203A} Cloud Sync, then \(tapAgain).")
        case let .needsReview(currentStatus):
            switch currentStatus {
            case "declined":
                return .init(title: "Booking declined", message: "This booking was already declined.")
            case "cancelled":
                return .init(title: failure, message: "The customer cancelled this booking.")
            default:
                return .init(title: failure, message: "This booking changed on another device. "
                             + "Pull down to refresh and check it.")
            }
        case .unknownOutcome:
            return .init(title: failure, message: "We couldn't tell whether the booking was declined. "
                         + "Check your connection, then pull down to refresh before trying again.")
        case .missing:
            return .init(title: failure, message: "This booking request wasn't found. "
                         + "It may have been removed on another device.")
        case let .failed(reason):
            let message = switch reason {
            case "session": "Your session has expired. Sign in again before responding to bookings."
            case "configuration": "Booking responses are not configured for this build."
            case "owner-changed": "The signed-in account changed, so nothing was saved on this device."
            case "read-only": "This device can't save changes right now. Nothing changed on this device."
            case "invalid-request": "This booking response was invalid and was not sent."
            // RN's network fallback (`utils/bookingRespond.ts:44`).
            default: "Please check your connection and try again."
            }
            return .init(title: failure, message: message)
        }
    }
}
