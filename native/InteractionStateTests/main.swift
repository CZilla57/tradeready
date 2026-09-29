import Foundation

private var failures = 0

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        failures += 1
        print("FAIL: \(message)")
    }
}

expect(
    NativeContentState.collection(visibleCount: 2, totalCount: 2, isLoading: true, hasError: true) == .content,
    "local content stays visible during background loading or sync failure"
)
expect(
    NativeContentState.collection(visibleCount: 0, totalCount: 0) == .empty,
    "a genuinely empty collection uses the creation-oriented empty state"
)
expect(
    NativeContentState.collection(visibleCount: 0, totalCount: 3, query: "  smith  ") == .noMatches(query: "smith"),
    "a query with no visible records uses a trimmed no-match state"
)
expect(
    NativeContentState.collection(visibleCount: 0, totalCount: 3, isFiltering: true) == .noMatches(query: ""),
    "a filter with no visible records is distinct from an empty collection"
)
expect(
    NativeContentState.collection(visibleCount: 0, totalCount: 0, isLoading: true) == .loading,
    "initial loading precedes an empty state"
)
expect(
    NativeContentState.collection(visibleCount: 0, totalCount: 0, hasError: true) == .error,
    "an initial error precedes an empty state"
)

if failures == 0 {
    print("PASS: native interaction state tests")
} else {
    print("\(failures) native interaction state test(s) failed")
    exit(1)
}
