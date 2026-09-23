import Foundation

var failures = 0

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        failures += 1
        print("FAIL: \(message)")
    }
}

expect(!NativeAddressLookup.shouldLookup("123"), "queries shorter than four characters stay local")
expect(NativeAddressLookup.shouldLookup("  1234  "), "trimmed four-character queries are eligible")
expect(NativeAddressLookup.normalizedQuery("  12 Main St \n") == "12 Main St", "query normalization trims only edges")

expect(
    NativeAddressLookup.displayAddress(
        title: "123 Main St",
        subtitle: "Phoenix, AZ 85001, United States"
    ) == "123 Main St, Phoenix, AZ 85001",
    "US address completions omit the redundant country suffix"
)
expect(
    NativeAddressLookup.displayAddress(title: "Phoenix", subtitle: "Phoenix") == "Phoenix",
    "duplicate title and subtitle are not repeated"
)
expect(
    NativeAddressLookup.displayAddress(title: "", subtitle: "Mesa, AZ") == "Mesa, AZ",
    "subtitle-only completions stay usable"
)

let suggestions = NativeAddressLookup.suggestions(from: [
    ("123 Main St", "Phoenix, AZ, United States"),
    ("123 MAIN ST", "Phoenix, AZ"),
    ("", ""),
    ("1 First St", "Tempe, AZ"),
    ("2 Second St", "Tempe, AZ"),
    ("3 Third St", "Tempe, AZ"),
    ("4 Fourth St", "Tempe, AZ"),
    ("5 Fifth St", "Tempe, AZ"),
])
expect(suggestions.count == 5, "suggestions are deduplicated, empty values removed, and capped at five")
expect(suggestions.first?.address == "123 Main St, Phoenix, AZ", "suggestion order is preserved")

if failures == 0 {
    print("PASS: native address lookup tests")
} else {
    print("\(failures) native address lookup test(s) failed")
    exit(1)
}
