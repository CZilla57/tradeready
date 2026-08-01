// __tests__/chatMarkdown.test.ts
// formatChatText flattens common markdown from AI replies into plain text
// while leaving trade shorthand (lumber sizes, spaced math, snake_case)
// untouched — the "leave it alone" cases matter as much as the stripping.

import { formatChatText } from "../utils/chatMarkdown";

describe("formatChatText", () => {
  describe("strips markdown markers", () => {
    it("strips bold", () => {
      expect(formatChatText("**Total: $450**")).toBe("Total: $450");
    });

    it("strips bold mid-sentence", () => {
      expect(formatChatText("Your total is **$450** for labor.")).toBe(
        "Your total is $450 for labor.",
      );
    });

    it("strips italics", () => {
      expect(formatChatText("This is *important* to note.")).toBe(
        "This is important to note.",
      );
    });

    it("strips bold-italics", () => {
      expect(formatChatText("***Urgent:*** call them back.")).toBe(
        "Urgent: call them back.",
      );
    });

    it("strips double-underscore emphasis", () => {
      expect(formatChatText("__Follow up__ on Friday.")).toBe(
        "Follow up on Friday.",
      );
    });

    it("converts dash and star bullets to dots", () => {
      expect(formatChatText("- Labor: $200\n- Materials: $100")).toBe(
        "• Labor: $200\n• Materials: $100",
      );
      expect(formatChatText("* First\n* Second")).toBe(
        "• First\n• Second",
      );
    });

    it("preserves bullet indentation", () => {
      expect(formatChatText("  - Nested item")).toBe("  • Nested item");
    });

    it("strips headers", () => {
      expect(formatChatText("## Summary\nRevenue is up.")).toBe(
        "Summary\nRevenue is up.",
      );
    });

    it("strips blockquote markers", () => {
      expect(formatChatText("> Pay by Friday")).toBe("Pay by Friday");
    });

    it("strips inline code backticks", () => {
      expect(formatChatText("Use the `estimate` feature.")).toBe(
        "Use the estimate feature.",
      );
    });

    it("drops code-fence lines but keeps their content", () => {
      expect(formatChatText("```\nHi Sam,\nInvoice attached.\n```")).toBe(
        "Hi Sam,\nInvoice attached.\n",
      );
    });
  });

  describe("leaves non-markdown text alone", () => {
    it("keeps lumber sizes intact", () => {
      expect(formatChatText("Use 2*4 and 2*6 studs.")).toBe(
        "Use 2*4 and 2*6 studs.",
      );
    });

    it("keeps spaced multiplication intact", () => {
      expect(formatChatText("5 * 3 = 15 hours total")).toBe(
        "5 * 3 = 15 hours total",
      );
    });

    it("keeps snake_case intact", () => {
      expect(formatChatText("The estimate_sent status")).toBe(
        "The estimate_sent status",
      );
    });

    it("keeps plain prose untouched", () => {
      const plain = "Hi Sam, your invoice INV-1042 for $450 is due Friday.";
      expect(formatChatText(plain)).toBe(plain);
    });

    it("keeps a lone asterisk untouched", () => {
      expect(formatChatText("Rated 5* by customers")).toBe(
        "Rated 5* by customers",
      );
    });
  });

  it("handles a realistic mixed reply", () => {
    const reply = [
      "## This month",
      "Revenue: **$4,200** (up 12%)",
      "- Overdue: $850 across 2 invoices",
      "- Top customer: *Sam Reilly*",
    ].join("\n");
    expect(formatChatText(reply)).toBe(
      [
        "This month",
        "Revenue: $4,200 (up 12%)",
        "• Overdue: $850 across 2 invoices",
        "• Top customer: Sam Reilly",
      ].join("\n"),
    );
  });
});
