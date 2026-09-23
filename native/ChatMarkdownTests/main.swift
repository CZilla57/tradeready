import Foundation

// Chat markdown-lite tests (task 10.10, requirement C4).
//
// Every vector here is copied verbatim from `__tests__/chatMarkdown.test.ts`
// (the RN oracle for `utils/chatMarkdown.ts` `formatChatText`) so the Swift
// port is pinned byte-for-byte, including the "leave it alone" cases that
// matter as much as the stripping ones.

private var failures = 0

private func expectEqual(_ actual: String, _ expected: String, _ label: String) {
    if actual != expected {
        failures += 1
        print("FAIL: \(label) — expected \(String(reflecting: expected)), got \(String(reflecting: actual))")
    }
}

private func run() {
    // MARK: strips markdown markers

    expectEqual(NativeChatMarkdown.formatChatText("**Total: $450**"), "Total: $450", "strips bold")

    expectEqual(
        NativeChatMarkdown.formatChatText("Your total is **$450** for labor."),
        "Your total is $450 for labor.",
        "strips bold mid-sentence"
    )

    expectEqual(
        NativeChatMarkdown.formatChatText("This is *important* to note."),
        "This is important to note.",
        "strips italics"
    )

    expectEqual(
        NativeChatMarkdown.formatChatText("***Urgent:*** call them back."),
        "Urgent: call them back.",
        "strips bold-italics"
    )

    expectEqual(
        NativeChatMarkdown.formatChatText("__Follow up__ on Friday."),
        "Follow up on Friday.",
        "strips double-underscore emphasis"
    )

    expectEqual(
        NativeChatMarkdown.formatChatText("- Labor: $200\n- Materials: $100"),
        "\u{2022} Labor: $200\n\u{2022} Materials: $100",
        "converts dash bullets to dots"
    )
    expectEqual(
        NativeChatMarkdown.formatChatText("* First\n* Second"),
        "\u{2022} First\n\u{2022} Second",
        "converts star bullets to dots"
    )

    expectEqual(
        NativeChatMarkdown.formatChatText("  - Nested item"),
        "  \u{2022} Nested item",
        "preserves bullet indentation"
    )

    expectEqual(
        NativeChatMarkdown.formatChatText("## Summary\nRevenue is up."),
        "Summary\nRevenue is up.",
        "strips headers"
    )

    expectEqual(
        NativeChatMarkdown.formatChatText("> Pay by Friday"),
        "Pay by Friday",
        "strips blockquote markers"
    )

    expectEqual(
        NativeChatMarkdown.formatChatText("Use the `estimate` feature."),
        "Use the estimate feature.",
        "strips inline code backticks"
    )

    expectEqual(
        NativeChatMarkdown.formatChatText("```\nHi Sam,\nInvoice attached.\n```"),
        "Hi Sam,\nInvoice attached.\n",
        "drops code-fence lines but keeps their content"
    )

    // MARK: leaves non-markdown text alone

    expectEqual(
        NativeChatMarkdown.formatChatText("Use 2*4 and 2*6 studs."),
        "Use 2*4 and 2*6 studs.",
        "keeps lumber sizes intact"
    )

    expectEqual(
        NativeChatMarkdown.formatChatText("5 * 3 = 15 hours total"),
        "5 * 3 = 15 hours total",
        "keeps spaced multiplication intact"
    )

    expectEqual(
        NativeChatMarkdown.formatChatText("The estimate_sent status"),
        "The estimate_sent status",
        "keeps snake_case intact"
    )

    let plain = "Hi Sam, your invoice INV-1042 for $450 is due Friday."
    expectEqual(NativeChatMarkdown.formatChatText(plain), plain, "keeps plain prose untouched")

    expectEqual(
        NativeChatMarkdown.formatChatText("Rated 5* by customers"),
        "Rated 5* by customers",
        "keeps a lone asterisk untouched"
    )

    // MARK: realistic mixed reply

    let reply = [
        "## This month",
        "Revenue: **$4,200** (up 12%)",
        "- Overdue: $850 across 2 invoices",
        "- Top customer: *Sam Reilly*",
    ].joined(separator: "\n")
    let expected = [
        "This month",
        "Revenue: $4,200 (up 12%)",
        "\u{2022} Overdue: $850 across 2 invoices",
        "\u{2022} Top customer: Sam Reilly",
    ].joined(separator: "\n")
    expectEqual(NativeChatMarkdown.formatChatText(reply), expected, "handles a realistic mixed reply")
}

run()

if failures == 0 {
    print("ChatMarkdownTests: all checks passed")
} else {
    print("ChatMarkdownTests: \(failures) failure(s)")
    exit(1)
}
