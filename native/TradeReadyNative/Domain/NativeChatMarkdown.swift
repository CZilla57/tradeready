import Foundation

// MARK: - Markdown-lite chat rendering (task 10.10, requirement C4)
//
// Byte-for-byte port of `utils/chatMarkdown.ts` `formatChatText`. The chat
// bubble renders plain text, so model output like `**Total: $450**` or
// `- bullet` would otherwise show its literal markers. Conservative on
// purpose: only paired emphasis markers and line-leading syntax are touched,
// so trade shorthand like "2*4 and 2*6", spaced math, and snake_case
// identifiers survive — single-underscore emphasis is deliberately not
// stripped for that reason (see the oracle `__tests__/chatMarkdown.test.ts`).
//
// Applied in this exact order (contract §8):
//   1. Fenced code blocks: strip the fence lines, keep their content.
//   2. Per line, indent-preserving: headers, bullets ("• "), blockquotes.
//   3. Paired emphasis, closing-guarded so it never eats into a word:
//      ***x*** -> x, **x** -> x, *x* -> x, __x__ -> x.
//   4. Inline code spans: `x` -> x.

enum NativeChatMarkdown {
    /// A pure text transform — no state, no I/O, and it never throws (every
    /// input, including malformed markdown, produces a best-effort flattened
    /// string).
    static func formatChatText(_ raw: String) -> String {
        var text = raw

        // 1. Fenced code blocks: drop the fence lines, keep the content.
        text = replacing(text, pattern: "^```[^\\n]*\\n?", options: [.anchorsMatchLines], template: "")

        // 2. Line-leading syntax (headers, bullets, blockquotes), indent
        //    preserved. Applied per line, matching RN's `.split("\n").map(...)`.
        text = text
            .components(separatedBy: "\n")
            .map { line -> String in
                var result = line
                result = replacing(result, pattern: "^(\\s*)#{1,6}\\s+", template: "$1")
                result = replacing(result, pattern: "^(\\s*)[-*]\\s+", template: "$1\u{2022} ")
                result = replacing(result, pattern: "^(\\s*)>\\s+", template: "$1")
                return result
            }
            .joined(separator: "\n")

        // 3. Paired emphasis. The `(?!\w)` guard on the closing marker is what
        //    keeps "2*4 and 2*6" and spaced math intact while still stripping
        //    real emphasis — order matters (bold-italic, then bold, then
        //    italic, then double-underscore).
        text = replacing(text, pattern: "\\*\\*\\*([^*\\n]+)\\*\\*\\*(?!\\w)", template: "$1")
        text = replacing(text, pattern: "\\*\\*([^*\\n]+)\\*\\*(?!\\w)", template: "$1")
        text = replacing(text, pattern: "\\*([^*\\s][^*\\n]*?)\\*(?!\\w)", template: "$1")
        text = replacing(text, pattern: "__([^_\\n]+)__(?!\\w)", template: "$1")

        // 4. Inline code spans.
        text = replacing(text, pattern: "`([^`\\n]+)`", template: "$1")

        return text
    }

    /// One `NSRegularExpression` replace-all, matching JS `.replace(/…/g, …)`.
    private static func replacing(
        _ text: String,
        pattern: String,
        options: NSRegularExpression.Options = [],
        template: String
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: template)
    }
}
