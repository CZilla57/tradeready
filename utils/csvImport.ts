// utils/csvImport.ts
// In-house RFC-4180 CSV parser + a stable non-crypto content hash.
// Pure and total: never throws on malformed input — a broken quote just ends
// the field where the data ends. Zero dependencies (parser hand-rolled so the
// import feature needs no new package). All higher-level meaning (which column
// is what, how a date reads) lives in importMapping.ts, not here.

const DEFAULT_MAX_ROWS = 5000;

export interface ParsedCsv {
  headers: string[];
  rows: string[][];
  rowCount: number;
  /** True when the soft row cap dropped trailing rows. */
  truncated: boolean;
}

/** Tokenise a full CSV document into rows of raw string cells (RFC-4180). */
function tokenize(text: string): string[][] {
  const records: string[][] = [];
  let field = "";
  let row: string[] = [];
  let inQuotes = false;
  let i = 0;
  const n = text.length;

  const endField = () => { row.push(field); field = ""; };
  const endRow = () => { endField(); records.push(row); row = []; };

  while (i < n) {
    const ch = text[i];
    if (inQuotes) {
      if (ch === '"') {
        if (text[i + 1] === '"') { field += '"'; i += 2; continue; }
        inQuotes = false; i += 1; continue;
      }
      field += ch; i += 1; continue;
    }
    if (ch === '"') { inQuotes = true; i += 1; continue; }
    if (ch === ",") { endField(); i += 1; continue; }
    if (ch === "\r") { i += 1; continue; }          // swallow CR (CRLF/lone CR)
    if (ch === "\n") { endRow(); i += 1; continue; }
    field += ch; i += 1;
  }
  // Flush the final field/row unless the file ended on a clean newline.
  if (field.length > 0 || row.length > 0) endRow();
  return records;
}

export function parseCsv(text: string, opts: { maxRows?: number } = {}): ParsedCsv {
  const maxRows = opts.maxRows ?? DEFAULT_MAX_ROWS;
  if (!text) return { headers: [], rows: [], rowCount: 0, truncated: false };

  const clean = text.charCodeAt(0) === 0xfeff ? text.slice(1) : text; // strip BOM
  const records = tokenize(clean);
  if (records.length === 0) return { headers: [], rows: [], rowCount: 0, truncated: false };

  const headers = records[0].map((h) => h.trim());
  const width = headers.length;
  const dataRecords = records.slice(1).filter((r) => !(r.length === 1 && r[0] === ""));

  const truncated = dataRecords.length > maxRows;
  const kept = truncated ? dataRecords.slice(0, maxRows) : dataRecords;
  const rows = kept.map((r) => {
    const padded = r.slice(0, width);
    while (padded.length < width) padded.push("");
    return padded;
  });

  return { headers, rows, rowCount: rows.length, truncated };
}

/** Stable FNV-1a-ish hash of the file text (re-import warning only, not security). */
export function hashCsv(text: string): string {
  let h = 0x811c9dc5;
  for (let i = 0; i < text.length; i += 1) {
    h ^= text.charCodeAt(i);
    h = Math.imul(h, 0x01000193);
  }
  return (h >>> 0).toString(16);
}
