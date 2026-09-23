import Foundation

private var failures = 0

private func expect<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
    if actual != expected {
        failures += 1
        fputs("FAIL: \(message) — got \(actual), expected \(expected)\n", stderr)
    }
}

@main
enum EstimateDeliveryTests {
    static func main() {
        expect(
            NativeEstimateDeliveryPolicy.resolution(for: .sent),
            .recordDelivery,
            "a composer-confirmed send records delivery"
        )
        expect(
            NativeEstimateDeliveryPolicy.resolution(for: .cancelled),
            .keepReview,
            "cancelling keeps the editable review without side effects"
        )
        expect(
            NativeEstimateDeliveryPolicy.resolution(for: .saved),
            .keepReviewWithSavedDraftNotice,
            "a saved Mail draft is not treated as sent"
        )
        expect(
            NativeEstimateDeliveryPolicy.resolution(for: .failed),
            .keepReviewWithFailureNotice,
            "a composer failure keeps the draft and reports the failure"
        )

        if failures == 0 {
            print("PASS: native estimate delivery policy tests")
        } else {
            exit(1)
        }
    }
}
