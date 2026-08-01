// utils/csvExport.ts
// The accounting export (roadmap #7): pure CSV builders + the share tail.
// Builders do NO I/O — everything above shareCsv is unit-testable strings.
// Spec: docs/superpowers/specs/2026-07-31-csv-export-design.md

/**
 * RFC-4180 field escaping: quote when the value contains a comma, quote,
 * or line break; double embedded quotes. Everything else passes through
 * so accented customer names stay readable in the file.
 */
export function escapeCsvField(value: string): string {
  if (/[",\r\n]/.test(value)) {
    return '"' + value.replace(/"/g, '""') + '"';
  }
  return value;
}

/**
 * Assemble a CSV document: header + rows, CRLF line endings (Excel's
 * expectation), trailing newline. No totals rows — they poison imports.
 */
export function toCsv(header: string[], rows: string[][]): string {
  const lines = [header, ...rows].map((fields) =>
    fields.map(escapeCsvField).join(",")
  );
  return lines.join("\r\n") + "\r\n";
}
