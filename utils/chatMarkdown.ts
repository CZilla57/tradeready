// utils/chatMarkdown.ts
// Markdown-lite flattener for AI chat replies. The chat renders plain <Text>,
// so model output like **Total: $450** or "- bullet" shows literal markers.
// Full markdown rendering is out of scope; this strips the common markers
// into clean plain text — readable in a bubble, pasteable into a customer
// message. Conservative on purpose: only paired emphasis markers and
// line-leading syntax are touched, so trade shorthand like "2*4 and 2*6",
// spaced math, and snake_case identifiers survive (single-underscore
// emphasis is deliberately not stripped for that reason).

export function formatChatText(raw: string): string {
  let text = raw;

  // Fenced code blocks: drop the fence lines, keep the content.
  text = text.replace(/^```[^\n]*\n?/gm, "");

  // Line-leading syntax (headers, bullets, blockquotes), indent preserved.
  text = text
    .split("\n")
    .map((line) =>
      line
        .replace(/^(\s*)#{1,6}\s+/, "$1")
        .replace(/^(\s*)[-*]\s+/, "$1• ")
        .replace(/^(\s*)>\s+/, "$1"),
    )
    .join("\n");

  // Paired emphasis, only when the content starts non-space and the closing
  // marker isn't glued to a word character — that last check is what keeps
  // "2*4 and 2*6" intact while still stripping *emphasis*.
  text = text.replace(/\*\*\*([^*\n]+)\*\*\*(?!\w)/g, "$1");
  text = text.replace(/\*\*([^*\n]+)\*\*(?!\w)/g, "$1");
  text = text.replace(/\*([^*\s][^*\n]*?)\*(?!\w)/g, "$1");
  text = text.replace(/__([^_\n]+)__(?!\w)/g, "$1");

  // Inline code spans.
  text = text.replace(/`([^`\n]+)`/g, "$1");

  return text;
}
