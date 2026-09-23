#!/bin/sh
# Checks that repository paths cited in the native-migration docs exist.
#
# Scans backticked code spans in docs/native-*.md (or the files passed as
# arguments) for repo-relative paths (`N/…` = native/TradeReadyNative/…,
# native/, __tests__/, utils/, screens/, components/, context/, backend/,
# backend-workers/, targets/, modules/, docs/) and reports any that don't exist.
#
# A missing path whose own sentence or list item says it is new or planned
# ("new", "proposed", "create", "created by", "delivered by"; "edits to" ends
# the clause), or a missing docs/ path in a task's **Own:** list,
# is listed as PLANNED and does not fail the check. Every other missing path is
# MISSING and exits 1. A path marked planned anywhere in the scanned docs is
# treated as planned everywhere. Set SHOW_PLANNED=1 to list planned paths too.
#
# Limits: it only checks that a file exists. It cannot tell whether a doc
# describes that file's behavior correctly, and it skips globs/placeholders
# (`*`, `<…>`, `{…}`, `XX`) and bare filenames without a directory.
# A doc containing `doc-ref-check: ignore-file` is skipped (e.g. reviews that
# quote wrong paths on purpose).
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT_DIR"

if [ "$#" -gt 0 ]; then
  set -- "$@"
else
  set -- docs/native-*.md
fi

node - "$@" <<'EOF'
const fs = require("fs");
const path = require("path");

const PREFIXES = ["N/", "native/", "__tests__/", "utils/", "screens/", "components/",
  "context/", "backend/", "backend-workers/", "targets/", "modules/", "docs/"];
const PLANNED = /\b(new|proposed|create[sd]?|will be created|created by|delivered by|to be delivered|appended to)\b/i;
// A task's **Own:** list names deliverable docs that don't exist yet; for code
// paths it also lists existing files being edited, so it only counts for docs/.
const OWNS_DOC = /\*\*Own:\*\*/;
// "Planned" wording must be in the same sentence or list item as the path.
const CLAUSE_BREAK = /(?:\.\s|\n\s*(?:[-*]|\d+[a-z]?\.)\s|\bedits? to\b)/gi;
const WINDOW = 400;

function clauseBefore(para, index) {
  const window = para.slice(Math.max(0, index - WINDOW), index);
  let start = 0;
  let b;
  CLAUSE_BREAK.lastIndex = 0;
  while ((b = CLAUSE_BREAK.exec(window))) start = b.index + b[0].length;
  return window.slice(start);
}

let missing = 0;
let planned = 0;
let checked = 0;

// Pass 1 collects every missing path any scanned doc marks as planned, so a later
// mention of the same future file (in the same or another doc) is not MISSING.
// Pass 2 reports.
const plannedSet = new Set();
const results = [];

for (const doc of process.argv.slice(2)) {
  const text = fs.readFileSync(doc, "utf8");
  if (text.includes("doc-ref-check: ignore-file")) continue;
  const paragraphs = text.split(/\n\s*\n/);
  let lineOffset = 1;
  for (const para of paragraphs) {
    const spanRe = /`([^`\n]+)`/g;
    let m;
    while ((m = spanRe.exec(para))) {
      let ref = m[1].trim();
      if (/\s/.test(ref) || /[*<>{}]|XX/.test(ref)) continue;
      if (!PREFIXES.some((p) => ref.startsWith(p))) continue;
      ref = ref.replace(/#.*$/, "").replace(/(\.\w+):.*$/, "$1").replace(/[.,;:)]+$/, "");
      const rel = ref.startsWith("N/") ? "native/TradeReadyNative/" + ref.slice(2) : ref;
      checked++;
      if (fs.existsSync(rel)) continue;
      const line = lineOffset + para.slice(0, m.index).split("\n").length - 1;
      const before = clauseBefore(para, m.index);
      const isPlanned = PLANNED.test(before) ||
        (ref.startsWith("docs/") && OWNS_DOC.test(para.slice(Math.max(0, m.index - WINDOW), m.index)));
      if (isPlanned) plannedSet.add(ref);
      results.push({ where: `${doc}:${line}`, ref, isPlanned });
    }
    lineOffset += para.split("\n").length + 1;
  }
}

for (const r of results) {
  if (r.isPlanned || plannedSet.has(r.ref)) {
    planned++;
    if (process.env.SHOW_PLANNED) console.log(`PLANNED  ${r.where}  ${r.ref}`);
  } else {
    missing++;
    console.log(`MISSING  ${r.where}  ${r.ref}`);
  }
}

console.log(`\n${checked} path references checked: ${missing} missing, ${planned} planned (not yet created).`);
process.exit(missing > 0 ? 1 : 0);
EOF
