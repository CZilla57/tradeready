import Foundation

/// Phase 12 (12.00b.2-L, P12-017): what the owner's responses to a booking
/// request (Decline, and accepting a reschedule request) wait for, and what
/// the acting screen shows after a decline.
extension AppStore {
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
