import Foundation

// MARK: - CSV parser + content hash (task 9.07, requirements I1)
//
// Pure port of `utils/csvImport.ts`: an in-house RFC-4180 tokenizer plus a stable
// non-crypto FNV-1a-style hash for the same-file re-import warning. Total — it
// never throws on malformed input; a broken quote just ends the field where the
// data ends. All higher-level meaning lives in `NativeImportMapping`.

struct NativeParsedCsv: Equatable {
    var headers: [String]
    var rows: [[String]]
    var rowCount: Int
    /// True when the soft row cap dropped trailing rows.
    var truncated: Bool
}

enum NativeCSVImport {
    static let defaultMaxRows = 5000

    /// Tokenise a full CSV document into rows of raw string cells (RFC-4180).
    /// Iterates UNICODE SCALARS, not Characters: in Swift a CRLF pair is a single
    /// grapheme cluster, so a Character-based scan would never see the newline.
    private static func tokenize(_ text: String) -> [[String]] {
        var records: [[String]] = []
        var field = ""
        var row: [String] = []
        var inQuotes = false
        let scalars = Array(text.unicodeScalars)
        var index = 0

        func endField() { row.append(field); field = "" }
        func endRow() { endField(); records.append(row); row = [] }

        let quote: UInt32 = 0x22
        let comma: UInt32 = 0x2C
        let carriageReturn: UInt32 = 0x0D
        let lineFeed: UInt32 = 0x0A

        while index < scalars.count {
            let character = scalars[index].value
            if inQuotes {
                if character == quote {
                    if index + 1 < scalars.count, scalars[index + 1].value == quote {
                        field.unicodeScalars.append(Unicode.Scalar(quote)!)
                        index += 2
                        continue
                    }
                    inQuotes = false
                    index += 1
                    continue
                }
                field.unicodeScalars.append(scalars[index])
                index += 1
                continue
            }
            if character == quote { inQuotes = true; index += 1; continue }
            if character == comma { endField(); index += 1; continue }
            if character == carriageReturn { index += 1; continue }   // swallow CR
            if character == lineFeed { endRow(); index += 1; continue }
            field.unicodeScalars.append(scalars[index])
            index += 1
        }
        // Flush the final field/row unless the file ended on a clean newline.
        if !field.isEmpty || !row.isEmpty { endRow() }
        return records
    }

    static func parseCsv(_ text: String, maxRows: Int = defaultMaxRows) -> NativeParsedCsv {
        if text.isEmpty { return NativeParsedCsv(headers: [], rows: [], rowCount: 0, truncated: false) }
        // Strip a leading BOM.
        let clean = text.unicodeScalars.first?.value == 0xFEFF ? String(text.unicodeScalars.dropFirst()) : text
        let records = tokenize(clean)
        guard !records.isEmpty else { return NativeParsedCsv(headers: [], rows: [], rowCount: 0, truncated: false) }

        let headers = records[0].map { $0.trimmingCharacters(in: .whitespaces) }
        let width = headers.count
        let dataRecords = records.dropFirst().filter { !($0.count == 1 && $0[0].isEmpty) }

        let truncated = dataRecords.count > maxRows
        let kept = truncated ? Array(dataRecords.prefix(maxRows)) : Array(dataRecords)
        let rows = kept.map { record -> [String] in
            var padded = Array(record.prefix(width))
            while padded.count < width { padded.append("") }
            return padded
        }
        return NativeParsedCsv(headers: headers, rows: rows, rowCount: rows.count, truncated: truncated)
    }

    /// Stable FNV-1a-ish hash of the file text (re-import warning only, not security).
    static func hashCsv(_ text: String) -> String {
        var hash: UInt32 = 0x811C_9DC5
        for unit in text.utf16 {
            hash ^= UInt32(unit)
            hash = hash &* 0x0100_0193
        }
        return String(hash, radix: 16)
    }
}
