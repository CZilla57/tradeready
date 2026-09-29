import Foundation

enum NativeAppointmentMessageKind: Equatable, Sendable {
    case confirmation
    case onMyWay
}

enum NativeAppointmentMessageChannel: Equatable, Hashable, Sendable {
    case sms
    case email
}

struct NativeAppointmentMessageInput: Equatable, Sendable {
    var customerName: String
    var customerPhone: String
    var customerEmail: String
    var customerAddress: String
    var jobAddress: String
    var scheduledDate: String?
    var scheduledStartTime: String?
    var businessName: String
    var appointmentConfirmationTemplate: String
    var onMyWayTemplate: String
}

struct NativeAppointmentMessageDraft: Equatable, Sendable {
    let channel: NativeAppointmentMessageChannel
    let recipient: String
    let subject: String?
    let body: String
    /// Mail attachments (PDF data). SMS ignores them. Defaults to none so
    /// existing call sites are unaffected.
    let attachments: [NativeMessageAttachment]

    init(
        channel: NativeAppointmentMessageChannel,
        recipient: String,
        subject: String?,
        body: String,
        attachments: [NativeMessageAttachment] = []
    ) {
        self.channel = channel
        self.recipient = recipient
        self.subject = subject
        self.body = body
        self.attachments = attachments
    }
}

struct NativeMessageAttachment: Equatable, Sendable {
    let data: Data
    let mimeType: String
    let fileName: String
}

enum NativeAppointmentMessageDraftResult: Equatable, Sendable {
    case draft(NativeAppointmentMessageDraft)
    case noContactInformation
}

/// Dependency-free message drafting shared by in-app appointment actions and
/// reviewed deep-link actions. This produces content only; callers must present
/// a user-reviewed composer and must never send a message automatically.
enum NativeAppointmentMessaging {
    static let defaultConfirmationTemplate =
        "Hi {customerName}, this is {businessName} confirming your appointment for {date} at {time}. "
        + "Reply here if you need to reschedule — see you then!"

    static let defaultOnMyWayTemplate =
        "Hi {customerName}, this is {businessName} — I'm on my way now. See you shortly!"

    static func draft(
        kind: NativeAppointmentMessageKind,
        input: NativeAppointmentMessageInput
    ) -> NativeAppointmentMessageDraftResult {
        let channel: NativeAppointmentMessageChannel
        let recipient: String
        if !input.customerPhone.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            channel = .sms
            recipient = input.customerPhone
        } else if !input.customerEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            channel = .email
            recipient = input.customerEmail
        } else {
            return .noContactInformation
        }

        let suppliedTemplate = switch kind {
        case .confirmation: input.appointmentConfirmationTemplate
        case .onMyWay: input.onMyWayTemplate
        }
        let trimmedTemplate = suppliedTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        let template = if trimmedTemplate.isEmpty {
            switch kind {
            case .confirmation: defaultConfirmationTemplate
            case .onMyWay: defaultOnMyWayTemplate
            }
        } else {
            trimmedTemplate
        }

        let appointment = formattedAppointment(
            date: input.scheduledDate,
            startTime: input.scheduledStartTime
        )
        let variables = [
            "customerName": input.customerName,
            "businessName": input.businessName.isEmpty ? "your contractor" : input.businessName,
            "date": appointment.date,
            "time": appointment.time,
            "address": input.customerAddress.isEmpty ? input.jobAddress : input.customerAddress
        ]
        let body = render(template: template, variables: variables)
        let subject: String? = channel == .email
            ? (kind == .confirmation ? "Appointment confirmation" : "On my way")
            : nil
        return .draft(.init(channel: channel, recipient: recipient, subject: subject, body: body))
    }

    static func render(template: String, variables: [String: String]) -> String {
        variables.reduce(template) { rendered, entry in
            rendered.replacingOccurrences(of: "{\(entry.key)}", with: entry.value)
        }
    }

    private static func formattedAppointment(
        date: String?,
        startTime: String?
    ) -> (date: String, time: String) {
        guard let rawDate = date, !rawDate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ("your upcoming appointment", "the scheduled time")
        }

        let dateParts = rawDate.split(separator: "-", omittingEmptySubsequences: false)
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        guard dateParts.count == 3,
              let year = Int(dateParts[0]),
              let month = Int(dateParts[1]),
              let day = Int(dateParts[2]),
              let localDate = calendar.date(from: DateComponents(year: year, month: month, day: day))
        else {
            return ("your upcoming appointment", formattedTime(startTime))
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.dateFormat = "EEEE, MMMM d"
        return (formatter.string(from: localDate), formattedTime(startTime))
    }

    private static func formattedTime(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "the scheduled time" }
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 2,
              let hour24 = Int(parts[0]), (0...23).contains(hour24),
              let minute = Int(parts[1]), (0...59).contains(minute)
        else { return "the scheduled time" }
        let period = hour24 >= 12 ? "PM" : "AM"
        let hour12 = hour24 % 12 == 0 ? 12 : hour24 % 12
        return String(format: "%d:%02d %@", hour12, minute, period)
    }
}
