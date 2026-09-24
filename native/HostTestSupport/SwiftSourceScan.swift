import Foundation

// Shared host-test support: a Swift source model for the source-scan suites.
// Extracted unchanged from `native/AccessibilityAuditTests/main.swift` (11.10a)
// by 11.11 so the accessibility audit and the layout-metrics suite share one
// comment/string masker and one construct walker instead of two copies.
// Compiled into `run-accessibility-audit-tests.sh` and
// `run-layout-metrics-tests.sh`. Pure Foundation; no test harness state.

// MARK: - Source model

/// One Swift file: the raw text plus a same-length "code mask" where comment
/// bodies are blanked and string-literal contents are replaced by `x` (the
/// quote delimiters are kept). Brace/paren matching and token search run on the
/// mask, so braces, parens and keywords inside strings or comments never count.
struct SourceFile {
    let relativePath: String
    let raw: [Character]
    let code: [Character]
    let lineStarts: [Int]

    init(relativePath: String, text: String) {
        self.relativePath = relativePath
        raw = Array(text)
        code = SourceFile.mask(raw)
        var starts = [0]
        for (index, char) in raw.enumerated() where char == "\n" { starts.append(index + 1) }
        lineStarts = starts
    }

    var codeText: String { String(code) }

    func line(of index: Int) -> Int {
        var low = 0, high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid] <= index { low = mid } else { high = mid - 1 }
        }
        return low + 1
    }

    func rawSlice(_ range: Range<Int>) -> String { String(raw[range]) }
    func codeSlice(_ range: Range<Int>) -> String { String(code[range]) }

    // MARK: Masking

    static func mask(_ source: [Character]) -> [Character] {
        let masker = SourceMasker(source)
        _ = masker.maskCode(from: 0, untilParen: false)
        return masker.out
    }

    // MARK: Structure helpers (on the code mask)

    /// Index of the bracket matching the opener at `open`, or nil.
    func matching(_ open: Int) -> Int? {
        let pairs: [Character: Character] = ["(": ")", "{": "}", "[": "]"]
        guard open < code.count, let close = pairs[code[open]] else { return nil }
        let opener = code[open]
        var depth = 0
        var k = open
        while k < code.count {
            if code[k] == opener { depth += 1 }
            else if code[k] == close {
                depth -= 1
                if depth == 0 { return k }
            }
            k += 1
        }
        return nil
    }

    func skipSpace(_ start: Int) -> Int {
        var k = start
        while k < code.count, code[k] == " " || code[k] == "\n" || code[k] == "\t" || code[k] == "\r" { k += 1 }
        return k
    }

    func identifier(at start: Int) -> (String, Int)? {
        var k = start
        while k < code.count, code[k].isLetter || code[k].isNumber || code[k] == "_" { k += 1 }
        return k > start ? (String(code[start..<k]), k) : nil
    }

    /// Every index where `token` appears as a whole identifier.
    func occurrences(of token: String) -> [Int] {
        let t = Array(token)
        var result: [Int] = []
        guard code.count >= t.count else { return result }
        var k = 0
        while k <= code.count - t.count {
            if code[k] == t[0], Array(code[k..<(k + t.count)]) == t {
                let before: Character? = k > 0 ? code[k - 1] : nil
                let after: Character? = k + t.count < code.count ? code[k + t.count] : nil
                let isIdent: (Character?) -> Bool = { c in
                    guard let c else { return false }
                    return c.isLetter || c.isNumber || c == "_"
                }
                if !isIdent(before), !isIdent(after) { result.append(k) }
            }
            k += 1
        }
        return result
    }

    /// Consumes a modifier chain (`.a(...)`, `.b { }`, `.c(...) { } label: { }`)
    /// starting at `start`; returns the index just past it.
    func chainEnd(from start: Int) -> Int {
        var k = start
        while true {
            let next = skipSpace(k)
            guard next < code.count, code[next] == ".",
                  let (_, afterName) = identifier(at: next + 1) else { return k }
            var j = afterName
            let open = skipSpace(j)
            if open < code.count, code[open] == "(", let close = matching(open) { j = close + 1 }
            j = trailingClosuresEnd(from: j).end
            k = j
        }
    }

    /// Consumes trailing closures after a call, including labelled ones
    /// (`label:`, `primaryAction:`). Returns the closures and the end index.
    func trailingClosuresEnd(from start: Int) -> (closures: [(label: String?, range: Range<Int>)], end: Int) {
        var closures: [(String?, Range<Int>)] = []
        var k = start
        while true {
            let next = skipSpace(k)
            guard next < code.count else { break }
            if code[next] == "{", let close = matching(next) {
                // Only the first trailing closure may be unlabelled.
                if !closures.isEmpty { break }
                closures.append((nil, (next + 1)..<close))
                k = close + 1
                continue
            }
            if !closures.isEmpty, let (name, afterName) = identifier(at: next) {
                let colon = skipSpace(afterName)
                guard colon < code.count, code[colon] == ":" else { break }
                let brace = skipSpace(colon + 1)
                guard brace < code.count, code[brace] == "{", let close = matching(brace) else { break }
                closures.append((name, (brace + 1)..<close))
                k = close + 1
                continue
            }
            break
        }
        return (closures, k)
    }
}

/// Blanks comments and string contents (see `SourceFile`). A class so the
/// string and code walkers can recurse into each other for interpolations.
final class SourceMasker {
    let source: [Character]
    var out: [Character]
    let n: Int

    init(_ source: [Character]) {
        self.source = source
        out = source
        n = source.count
    }

    func at(_ k: Int) -> Character? { k >= 0 && k < n ? source[k] : nil }

    /// Masks a string literal starting at `start` (the first `"` or the first
    /// `#` of a raw string). Returns the index just past it.
    func maskString(_ start: Int) -> Int {
        var k = start
        var hashes = 0
        while at(k) == "#" { hashes += 1; k += 1 }
        guard at(k) == "\"" else { return start + 1 }
        let multiline = at(k + 1) == "\"" && at(k + 2) == "\""
        k += multiline ? 3 : 1
        let closeQuotes = multiline ? 3 : 1
        while k < n {
            let c = source[k]
            if c == "\\" {
                // Interpolation: `\(` in plain strings, `\#(` in raw ones.
                var h = 0
                while at(k + 1 + h) == "#" { h += 1 }
                if h == hashes, at(k + 1 + h) == "(" {
                    for m in k...(k + 1 + h) { out[m] = "x" }
                    k = maskCode(from: k + 2 + h, untilParen: true)
                    continue
                }
                if hashes == 0 {
                    out[k] = "x"
                    if k + 1 < n, source[k + 1] != "\n" { out[k + 1] = "x" }
                    k += 2
                    continue
                }
            }
            if c == "\"" {
                var q = 0
                while q < closeQuotes, at(k + q) == "\"" { q += 1 }
                if q == closeQuotes {
                    var h = 0
                    while h < hashes, at(k + q + h) == "#" { h += 1 }
                    if h == hashes { return k + q + h }
                }
            }
            if c != "\n" { out[k] = "x" }
            k += 1
        }
        return k
    }

    /// Walks code from `start`. With `untilParen`, stops after the `)` that
    /// closes an interpolation (that `)` is masked as `x`).
    func maskCode(from start: Int, untilParen: Bool) -> Int {
        var k = start
        var depth = 0
        while k < n {
            let c = source[k]
            if c == "/", at(k + 1) == "/" {
                while k < n, source[k] != "\n" { out[k] = " "; k += 1 }
                continue
            }
            if c == "/", at(k + 1) == "*" {
                var nest = 0
                while k < n {
                    if source[k] == "/", at(k + 1) == "*" { nest += 1; out[k] = " "; out[k + 1] = " "; k += 2; continue }
                    if source[k] == "*", at(k + 1) == "/" {
                        nest -= 1; out[k] = " "; out[k + 1] = " "; k += 2
                        if nest == 0 { break }
                        continue
                    }
                    if source[k] != "\n" { out[k] = " " }
                    k += 1
                }
                continue
            }
            if c == "\"" || (c == "#" && (at(k + 1) == "\"" || at(k + 1) == "#")) {
                k = maskString(k)
                continue
            }
            if untilParen {
                if c == "(" { depth += 1 }
                if c == ")" {
                    if depth == 0 { out[k] = "x"; return k + 1 }
                    depth -= 1
                }
            }
            k += 1
        }
        return k
    }
}

func loadSources(root: URL) -> [SourceFile] {
    let base = root.appendingPathComponent("native/TradeReadyNative")
    guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else { return [] }
    var files: [SourceFile] = []
    for case let url as URL in walker where url.pathExtension == "swift" {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
        let relative = String(url.path.dropFirst(base.path.count + 1))
        files.append(SourceFile(relativePath: relative, text: text))
    }
    return files.sorted { $0.relativePath < $1.relativePath }
}

func read(_ root: URL, _ path: String) -> String? {
    try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
}

// MARK: - Construct helpers

/// The brace-matched body of `func <name>(` in `file` (empty if missing).
func functionBody(_ file: SourceFile, _ name: String) -> String {
    for hit in file.occurrences(of: name) where hit >= 5 && file.codeSlice((hit - 5)..<hit) == "func " {
        guard let paren = (hit..<file.code.count).first(where: { file.code[$0] == "(" }),
              let parenClose = file.matching(paren),
              let brace = ((parenClose + 1)..<file.code.count).first(where: { file.code[$0] == "{" }),
              let close = file.matching(brace) else { return "" }
        return file.rawSlice((brace + 1)..<close).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return ""
}

/// The brace-matched text of `struct <name>` in `file` (empty if missing).
func structText(_ file: SourceFile, _ name: String) -> String {
    for hit in file.occurrences(of: name) where hit >= 7 && file.codeSlice((hit - 7)..<hit) == "struct " {
        guard let brace = (hit..<file.code.count).first(where: { file.code[$0] == "{" }),
              let close = file.matching(brace) else { return "" }
        return file.rawSlice(hit..<(close + 1))
    }
    return ""
}
