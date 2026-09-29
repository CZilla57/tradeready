import Foundation

@main
struct AppointmentMessagingTests {
    static func main() {
        var failures = 0
        func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
            if !condition() { failures += 1; print("FAIL: \(label)") }
        }

        func input(
            phone: String = "5551234567",
            email: String = "alice@example.test",
            customerAddress: String = "12 Oak St",
            jobAddress: String = "",
            date: String? = "2026-07-19",
            time: String? = "09:00",
            businessName: String = "Bob Plumbing",
            confirmationTemplate: String = "",
            onMyWayTemplate: String = ""
        ) -> NativeAppointmentMessageInput {
            .init(
                customerName: "Alice", customerPhone: phone, customerEmail: email,
                customerAddress: customerAddress, jobAddress: jobAddress,
                scheduledDate: date, scheduledStartTime: time,
                businessName: businessName,
                appointmentConfirmationTemplate: confirmationTemplate,
                onMyWayTemplate: onMyWayTemplate
            )
        }

        func draft(
            _ kind: NativeAppointmentMessageKind,
            _ value: NativeAppointmentMessageInput
        ) -> NativeAppointmentMessageDraft? {
            guard case let .draft(result) = NativeAppointmentMessaging.draft(kind: kind, input: value) else {
                return nil
            }
            return result
        }

        let sms = draft(.onMyWay, input())
        expect(sms?.channel == .sms && sms?.recipient == "5551234567",
               "SMS is preferred when phone and email are present")
        expect(sms?.subject == nil, "SMS drafts have no subject")
        expect(sms?.body == NativeAppointmentMessaging.defaultOnMyWayTemplate
            .replacingOccurrences(of: "{customerName}", with: "Alice")
            .replacingOccurrences(of: "{businessName}", with: "Bob Plumbing"),
               "blank on-my-way template uses the React Native default")

        let email = draft(.onMyWay, input(phone: ""))
        expect(email?.channel == .email && email?.recipient == "alice@example.test",
               "email is used when phone is absent")
        expect(email?.subject == "On my way", "on-my-way email subject matches React Native")

        let whitespacePhone = draft(.confirmation, input(phone: "  \n", email: "alice@example.test"))
        expect(whitespacePhone?.channel == .email,
               "whitespace-only phone falls back to email")
        expect(whitespacePhone?.subject == "Appointment confirmation",
               "confirmation email has the matching subject")
        expect(whitespacePhone?.body.contains("Sunday, July 19 at 9:00 AM") == true,
               "confirmation default formats the local date and start time")

        let noContact = NativeAppointmentMessaging.draft(
            kind: .onMyWay,
            input: input(phone: " \t", email: "\n")
        )
        expect(noContact == .noContactInformation,
               "whitespace-only contact fields produce no draft")

        let custom = draft(
            .onMyWay,
            input(
                customerAddress: "",
                jobAddress: "99 Job Lane",
                businessName: "Cash$1 Services",
                onMyWayTemplate: "  {customerName}|{customerName}|{businessName}|{date}|{time}|{address}|{unknown}  "
            )
        )
        expect(custom?.body == "Alice|Alice|Cash$1 Services|Sunday, July 19|9:00 AM|99 Job Lane|{unknown}",
               "custom templates trim edges, replace all known placeholders globally, preserve dollar text, and retain unknown placeholders")

        let customerAddressWins = draft(
            .onMyWay,
            input(
                customerAddress: "12 Oak St",
                jobAddress: "99 Job Lane",
                onMyWayTemplate: "{address}"
            )
        )
        expect(customerAddressWins?.body == "12 Oak St",
               "customer address takes precedence over job address")

        let missingSchedule = draft(
            .confirmation,
            input(date: nil, time: nil, confirmationTemplate: "{date}|{time}")
        )
        expect(missingSchedule?.body == "your upcoming appointment|the scheduled time",
               "missing schedule uses neutral fallback phrases")

        let emptyBusiness = draft(
            .onMyWay,
            input(businessName: "", onMyWayTemplate: "{businessName}")
        )
        expect(emptyBusiness?.body == "your contractor",
               "empty business name uses the React Native fallback")

        let whitespaceTemplate = draft(
            .confirmation,
            input(confirmationTemplate: " \n ")
        )
        expect(whitespaceTemplate?.body.contains("confirming your appointment") == true,
               "whitespace-only custom template uses the default")

        if failures == 0 { print("Appointment messaging tests passed") }
        else { fatalError("\(failures) appointment messaging test(s) failed") }
    }
}
