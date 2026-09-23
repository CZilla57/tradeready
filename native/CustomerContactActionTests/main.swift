import Foundation

@main
struct CustomerContactActionTests {
    static func main() {
        var failures = 0
        func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
            if !condition() { failures += 1; print("FAIL: \(label)") }
        }

        let all = NativeCustomerContactActions.targets(
            phone: " +1 (602) 555-0199 ",
            email: " alice+work@example.test "
        )
        expect(all.map(\.action) == [.call, .text, .email],
               "phone and email expose call, text, and email in stable order")
        expect(all[0].recipient == "+16025550199",
               "phone normalization retains one leading plus and ASCII digits")
        expect(all[1].externalURL?.absoluteString == "sms:+16025550199",
               "text fallback produces a recipient-only SMS URL")
        expect(all[2].recipient == "alice+work@example.test",
               "email normalization trims surrounding whitespace")
        expect(all[2].externalURL?.absoluteString == "mailto:alice+work@example.test",
               "email fallback produces a recipient-only mail URL")

        let emailOnly = NativeCustomerContactActions.targets(
            phone: "extension only",
            email: "person@example.test"
        )
        expect(emailOnly.map(\.action) == [.email],
               "phone values without digits do not create call or text actions")

        let none = NativeCustomerContactActions.targets(phone: " \n ", email: "\u{0007}")
        expect(none.isEmpty,
               "blank or control-only contacts never cross a composer or URL boundary")
        expect(
            NativeCustomerContactActions.target(
                for: .text,
                phone: "555-0100",
                email: "person@example.test"
            )?.recipient == "5550100",
            "single-action lookup returns the matching normalized target"
        )

        if failures == 0 { print("PASS: native customer contact action tests") }
        else { fatalError("\(failures) customer contact action test(s) failed") }
    }
}
