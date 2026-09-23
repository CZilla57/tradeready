import Foundation

// CSV parser + hash tests (task 9.07).
//
// Ports __tests__/csvImport.test.ts: RFC-4180 quoting, BOM/CRLF handling, row
// padding, total (never-throwing) parsing, the soft row cap, and the stable
// content hash.

private var failures = 0

private func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
    if !condition() {
        failures += 1
        print("FAIL: \(label)")
    }
}

private func expectEqual<T: Equatable>(_ actual: T?, _ expected: T, _ label: String) {
    if actual != expected {
        failures += 1
        print("FAIL: \(label) — expected \(expected), got \(String(describing: actual))")
    }
}

private func testParseCsv() {
    let simple = NativeCSVImport.parseCsv("Name,Phone\nAda,555-1\nGrace,555-2\n")
    expectEqual(simple.headers, ["Name", "Phone"], "simple headers")
    expectEqual(simple.rows, [["Ada", "555-1"], ["Grace", "555-2"]], "simple rows")
    expectEqual(simple.rowCount, 2, "row count")
    expect(!simple.truncated, "not truncated")

    let quoted = NativeCSVImport.parseCsv("Name,Notes\n\"Smith, Bob\",\"line1\nline2\"\n\"She said \"\"hi\"\"\",ok\n")
    expectEqual(quoted.rows[0], ["Smith, Bob", "line1\nline2"], "embedded comma and newline")
    expectEqual(quoted.rows[1], ["She said \"hi\"", "ok"], "doubled quotes")

    let bom = NativeCSVImport.parseCsv("\u{FEFF}Name,Phone\r\nAda,555\r\n")
    expectEqual(bom.headers, ["Name", "Phone"], "BOM stripped, CRLF handled")
    expectEqual(bom.rows, [["Ada", "555"]], "CRLF row")

    let ragged = NativeCSVImport.parseCsv("A,B,C\n1,2\n\n")
    expectEqual(ragged.rows, [["1", "2", ""]], "short rows padded, trailing blank line ignored")

    expectEqual(NativeCSVImport.parseCsv("").headers, [], "empty text yields empty headers")
    // An unterminated quote just swallows the rest as one field; the point is
    // that the parser is total and never throws.
    let malformed = NativeCSVImport.parseCsv("\"unterminated,quote\nrow")
    expectEqual(malformed.headers.count, 1, "malformed input yields one header")
    expectEqual(malformed.headers.first, "unterminated,quote\nrow", "unterminated quote keeps the remaining text")
    expectEqual(malformed.rows, [], "malformed input yields no data rows")

    let body = (0..<10).map { "r\($0)" }.joined(separator: "\n")
    let capped = NativeCSVImport.parseCsv("H\n\(body)\n", maxRows: 4)
    expectEqual(capped.rows.count, 4, "soft cap keeps maxRows")
    expect(capped.truncated, "soft cap flags truncation")
    expectEqual(capped.headers, ["H"], "capped headers")
}

private func testHash() {
    expectEqual(NativeCSVImport.hashCsv("A,B\n1,2\n"), NativeCSVImport.hashCsv("A,B\n1,2\n"), "hash is stable")
    expect(NativeCSVImport.hashCsv("A,B\n1,2\n") != NativeCSVImport.hashCsv("A,B\n1,3\n"), "hash differs for different content")
    // FNV-1a 32-bit of the ASCII bytes; pinned to the React Native value.
    expectEqual(NativeCSVImport.hashCsv("A,B\n1,2\n"), "a0842561", "hash matches the RN oracle")
}

testParseCsv()
testHash()

if failures == 0 {
    print("CSVImportTests: all checks passed")
} else {
    print("CSVImportTests: \(failures) failure(s)")
    exit(1)
}
