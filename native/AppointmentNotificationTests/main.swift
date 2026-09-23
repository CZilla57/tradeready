import Foundation

private var failures = 0
private func expect(_ value: @autoclosure () -> Bool, _ message: String) {
    if !value() { failures += 1; fputs("FAIL: \(message)\n", stderr) }
}

@main
struct AppointmentNotificationTests {
    static func main() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let fire = NativeAppointmentNotifications.fireDate(for: "2026-07-19", calendar: calendar)
        expect(fire == calendar.date(from: .init(year: 2026, month: 7, day: 18, hour: 17)), "fires at 5pm local on the preceding day")
        expect(NativeAppointmentNotifications.fireDate(for: "2026-02-30", calendar: calendar) == nil, "rejects invalid calendar dates")
        expect(NativeAppointmentNotifications.canOpenNotification(exactOwnerWorkspace: true, signedIn: true, job: nil) == false, "requires the exact current job for a tap")
        if failures == 0 { print("PASS: appointment notification tests") } else { exit(1) }
    }
}
