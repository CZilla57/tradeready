#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
PREFLIGHT="$ROOT_DIR/native/run-phase-12-stage-preflight.sh"
FIXTURES="$ROOT_DIR/native/Phase12StagePreflightTests/fixtures"
GOOD_DOCS="$FIXTURES/docs-good"
VARIANTS="$FIXTURES/docs-variants"
GOOD_SETTINGS="$FIXTURES/good-build-settings.txt"
GOOD_APP_JSON="$FIXTURES/fixture-app.json"

TEMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/tradeready-phase12-preflight-tests.XXXXXX")
trap 'rm -rf "$TEMP_ROOT"' EXIT HUP INT TERM

OUTPUT_PATH="$TEMP_ROOT/output"

# One cached real-repo build-settings capture, reused by every real-repo
# assertion below instead of re-invoking xcodebuild per call (Minor 11).
REAL_BUILD_SETTINGS="$TEMP_ROOT/real-build-settings.txt"
xcodebuild -project "$ROOT_DIR/native/TradeReadyNative.xcodeproj" -scheme TradeReadyNative \
  -configuration Release -sdk iphoneos -showBuildSettings >"$REAL_BUILD_SETTINGS" 2>/dev/null || true

# Builds a fresh docs directory from the good fixture set, optionally
# replacing one file with a named variant. Prints the directory path.
make_docs_dir() {
  name=$1
  variant_file=${2:-}
  variant_dest=${3:-}
  dir="$TEMP_ROOT/$name"
  rm -rf "$dir"
  mkdir -p "$dir"
  cp "$GOOD_DOCS"/*.md "$dir"/
  if [ -n "$variant_file" ]; then
    cp "$VARIANTS/$variant_file" "$dir/$variant_dest"
  fi
  printf '%s' "$dir"
}

expect_status() {
  expected_status=$1
  expected_text=$2
  shift 2

  set +e
  "$PREFLIGHT" "$@" >"$OUTPUT_PATH" 2>&1
  actual_status=$?
  set -e

  if [ "$actual_status" -ne "$expected_status" ]; then
    sed -n '1,200p' "$OUTPUT_PATH" >&2
    echo "Expected status $expected_status, got $actual_status (args: $*)" >&2
    exit 1
  fi

  if ! grep -F -q "$expected_text" "$OUTPUT_PATH"; then
    sed -n '1,200p' "$OUTPUT_PATH" >&2
    echo "Missing expected result: $expected_text (args: $*)" >&2
    exit 1
  fi
}

expect_no_match() {
  # Like expect_status, but also asserts a pattern is ABSENT from the output
  # (grep -F, so a literal substring, not a regex).
  expected_status=$1
  absent_text=$2
  shift 2

  set +e
  "$PREFLIGHT" "$@" >"$OUTPUT_PATH" 2>&1
  actual_status=$?
  set -e

  if [ "$actual_status" -ne "$expected_status" ]; then
    sed -n '1,200p' "$OUTPUT_PATH" >&2
    echo "Expected status $expected_status, got $actual_status (args: $*)" >&2
    exit 1
  fi
  if grep -F -q "$absent_text" "$OUTPUT_PATH"; then
    sed -n '1,200p' "$OUTPUT_PATH" >&2
    echo "Did not expect to find: $absent_text (args: $*)" >&2
    exit 1
  fi
}

DOCS_A=$(make_docs_dir "stage-a-good")

# ---------------------------------------------------------------------------
# Important 1 / Minor 1-3: fail-closed defect list, status, R59, predecessor.
# ---------------------------------------------------------------------------

# 1. Placeholder staging backend fails.
expect_status 1 "FAIL: backend URL is not the placeholder" \
  --stage A --docs-dir "$DOCS_A" --build-settings "$FIXTURES/placeholder-build-settings.txt" --rn-app-json "$GOOD_APP_JSON"

# 2. Production-matched Supabase URL fails (origin-based, not exact-string).
expect_status 1 "FAIL: Supabase URL matches the production project outside a production build" \
  --stage A --docs-dir "$DOCS_A" --build-settings "$FIXTURES/production-matched-build-settings.txt" --rn-app-json "$GOOD_APP_JSON"

# 2a. Production-matched Supabase URL still catches an origin that differs only
#     by case, an explicit default port and a trailing slash (Minor 1, Important 7).
expect_status 1 "FAIL: Supabase URL matches the production project outside a production build" \
  --stage A --docs-dir "$DOCS_A" --build-settings "$FIXTURES/production-matched-origin-variant-build-settings.txt" --rn-app-json "$GOOD_APP_JSON"

# 2b. Production-matched Supabase publishable key fails even when the URL differs
#     (Minor 1: "the publishable-key match is not checked at all").
expect_status 1 "FAIL: Supabase publishable key matches the production key outside a production build" \
  --stage A --docs-dir "$DOCS_A" --build-settings "$FIXTURES/production-matched-key-only-build-settings.txt" --rn-app-json "$GOOD_APP_JSON"

# 2c. Production-matched backend URL fails (read from the RN app config at run
#     time, never a hardcoded host in this script -- Important 7).
expect_status 1 "FAIL: backend URL matches the production project (app.json) outside a production build" \
  --stage A --docs-dir "$DOCS_A" --build-settings "$FIXTURES/production-matched-backend-build-settings.txt" --rn-app-json "$GOOD_APP_JSON"

# 2d. Supabase placeholder fails (Minor 2 gap).
expect_status 1 "FAIL: Supabase URL is not the placeholder" \
  --stage A --docs-dir "$DOCS_A" --build-settings "$FIXTURES/supabase-placeholder-build-settings.txt" --rn-app-json "$GOOD_APP_JSON"

# 3. DRAFT charter fails.
DOCS_DRAFT=$(make_docs_dir "stage-a-draft" "charter-draft.md" "native-phase-12-cutover-charter.md")
expect_status 1 "FAIL: charter is owner-approved" \
  --stage A --docs-dir "$DOCS_DRAFT" --build-settings "$GOOD_SETTINGS" --rn-app-json "$GOOD_APP_JSON"

# 3a. A Status line that is merely "proposed" (no DRAFT, no owner-approved) also
#     fails -- Minor 3: absence of DRAFT is not enough.
DOCS_PROPOSED=$(make_docs_dir "stage-a-proposed" "charter-status-proposed.md" "native-phase-12-cutover-charter.md")
expect_status 1 "FAIL: charter is owner-approved (Status line does not say owner-approved" \
  --stage A --docs-dir "$DOCS_PROPOSED" --build-settings "$GOOD_SETTINGS" --rn-app-json "$GOOD_APP_JSON"

# 4. An open blocking defect (12.00b.2) fails, by name.
DOCS_OPEN=$(make_docs_dir "stage-a-open-blocker" "charter-open-blocker.md" "native-phase-12-cutover-charter.md")
expect_status 1 "FAIL: defect list: no open S1/S2 blocks stage entry (open, no recorded ruling: L130)" \
  --stage A --docs-dir "$DOCS_OPEN" --build-settings "$GOOD_SETTINGS" --rn-app-json "$GOOD_APP_JSON"

# 4a. Important 1(b): renaming the enclosing "### 12.00b.2" heading does not let
#     an open S1/S2 row inside it slip through -- the scan covers the whole §10
#     body, not named subsections.
DOCS_RENAMED=$(make_docs_dir "stage-a-renamed-heading" "charter-renamed-heading.md" "native-phase-12-cutover-charter.md")
expect_status 1 "FAIL: defect list: no open S1/S2 blocks stage entry (open, no recorded ruling: L130)" \
  --stage A --docs-dir "$DOCS_RENAMED" --build-settings "$GOOD_SETTINGS" --rn-app-json "$GOOD_APP_JSON"

# 4b. Important 1: the "## 10. Defect list" heading itself missing/renamed fails
#     closed (a heading rename must never look like "zero open rows").
DOCS_NO_HEADING=$(make_docs_dir "stage-a-no-defect-heading" "charter-no-defect-heading.md" "native-phase-12-cutover-charter.md")
expect_status 1 "FAIL: defect list: no open S1/S2 blocks stage entry (§10 Defect list heading not found)" \
  --stage A --docs-dir "$DOCS_NO_HEADING" --build-settings "$GOOD_SETTINGS" --rn-app-json "$GOOD_APP_JSON"

# 4c. The P12-012-style ruling gate, both directions (Important 1(e), the
#     coverage gap the review named explicitly).
#   - An open S1 with NO recorded ruling at all: FAIL, naming the ID.
DOCS_NO_RULING=$(make_docs_dir "stage-a-no-ruling" "charter-open-s1-no-ruling.md" "native-phase-12-cutover-charter.md")
expect_status 1 "FAIL: defect list: no open S1/S2 blocks stage entry (open, no recorded ruling: P12-903)" \
  --stage A --docs-dir "$DOCS_NO_RULING" --build-settings "$GOOD_SETTINGS" --rn-app-json "$GOOD_APP_JSON"

#   - A decision-log row that names the ID and mentions the ruling number, but
#     never says "ruled:" (e.g. "ruling requested, still pending"): FAIL. This
#     is the exact review reproduction of issue (a).
DOCS_UNRELATED=$(make_docs_dir "stage-a-unrelated-ruling" "charter-unrelated-ruling.md" "native-phase-12-cutover-charter.md")
expect_status 1 "FAIL: defect list: no open S1/S2 blocks stage entry (open, no recorded ruling: P12-903)" \
  --stage A --docs-dir "$DOCS_UNRELATED" --build-settings "$GOOD_SETTINGS" --rn-app-json "$GOOD_APP_JSON"

#   - A real "ruled: R<n>" row naming the ID: the row becomes an OWNER line,
#     never a FAIL, and never a silent PASS either (docs-good already has this
#     case built in as P12-903 / R900; see the all-good assertions below).
expect_no_match 0 "FAIL:" \
  --stage A --docs-dir "$DOCS_A" --build-settings "$GOOD_SETTINGS" --rn-app-json "$GOOD_APP_JSON"
expect_status 0 "OWNER defect list: P12-903 (open S1, ruling R900 recorded — owner still authorizes stage entry)" \
  --stage A --docs-dir "$DOCS_A" --build-settings "$GOOD_SETTINGS" --rn-app-json "$GOOD_APP_JSON"

# 4d. Fix round 2, Important 1(a) (still open after round 1): the ruling token
#     must be bound to its own "ruled:" marker, not merely present anywhere
#     after some "ruled:" in the row, and the Decider cell must read "owner".
#   - A row that rules a DIFFERENT ruling and, in the same row, separately
#     notes this defect's ruling number as "still pending": FAIL. This is the
#     re-review's exact fail-open reproduction.
DOCS_COMBINED_ROW=$(make_docs_dir "stage-a-combined-ruling-row" "charter-marker-combined-row.md" "native-phase-12-cutover-charter.md")
expect_status 1 "FAIL: defect list: no open S1/S2 blocks stage entry (open, no recorded ruling: P12-903)" \
  --stage A --docs-dir "$DOCS_COMBINED_ROW" --build-settings "$GOOD_SETTINGS" --rn-app-json "$GOOD_APP_JSON"
#   - A negated marker ("not yet ruled: R900"): FAIL even though the exact
#     token immediately follows "ruled:".
DOCS_NEGATED=$(make_docs_dir "stage-a-negated-ruling" "charter-marker-negated.md" "native-phase-12-cutover-charter.md")
expect_status 1 "FAIL: defect list: no open S1/S2 blocks stage entry (open, no recorded ruling: P12-903)" \
  --stage A --docs-dir "$DOCS_NEGATED" --build-settings "$GOOD_SETTINGS" --rn-app-json "$GOOD_APP_JSON"
#   - The exact right marker text, but the Decider cell is not "owner": FAIL.
DOCS_NON_OWNER=$(make_docs_dir "stage-a-non-owner-decider" "charter-marker-non-owner-decider.md" "native-phase-12-cutover-charter.md")
expect_status 1 "FAIL: defect list: no open S1/S2 blocks stage entry (open, no recorded ruling: P12-903)" \
  --stage A --docs-dir "$DOCS_NON_OWNER" --build-settings "$GOOD_SETTINGS" --rn-app-json "$GOOD_APP_JSON"
#   - The correct owner row PASSes (OWNER line, not FAIL): already proved by
#     the docs-good assertions immediately above (P12-903 / R900).

# 4e. Fix round 2, Minor 6: a defect row this scanner cannot parse cleanly
#     (an odd ID, an annotated severity cell, or an extra "|" in a cell) must
#     FAIL with a named line when it looks like it could be S1/S2, not be
#     silently skipped.
DOCS_ODD_ID=$(make_docs_dir "stage-a-unparseable-odd-id" "charter-unparseable-odd-id.md" "native-phase-12-cutover-charter.md")
expect_status 1 "FAIL: defect list: no open S1/S2 blocks stage entry (open, no recorded ruling: [unparseable id: P12-999" \
  --stage A --docs-dir "$DOCS_ODD_ID" --build-settings "$GOOD_SETTINGS" --rn-app-json "$GOOD_APP_JSON"
DOCS_ANNOTATED_SEV=$(make_docs_dir "stage-a-unparseable-severity" "charter-unparseable-annotated-severity.md" "native-phase-12-cutover-charter.md")
expect_status 1 "FAIL: defect list: no open S1/S2 blocks stage entry (open, no recorded ruling: [P12-998: unparseable severity" \
  --stage A --docs-dir "$DOCS_ANNOTATED_SEV" --build-settings "$GOOD_SETTINGS" --rn-app-json "$GOOD_APP_JSON"
DOCS_EXTRA_PIPE=$(make_docs_dir "stage-a-unparseable-extra-pipe" "charter-unparseable-extra-pipe.md" "native-phase-12-cutover-charter.md")
expect_status 1 "FAIL: defect list: no open S1/S2 blocks stage entry (open, no recorded ruling: [unparseable row, extra '|', starts 'P12-997']" \
  --stage A --docs-dir "$DOCS_EXTRA_PIPE" --build-settings "$GOOD_SETTINGS" --rn-app-json "$GOOD_APP_JSON"

# 5. A missing required doc fails.
DOCS_MISSING=$(make_docs_dir "stage-a-missing-doc")
rm -f "$DOCS_MISSING/native-phase-12-monitoring.md"
expect_status 1 "FAIL: required doc present: monitoring doc" \
  --stage A --docs-dir "$DOCS_MISSING" --build-settings "$GOOD_SETTINGS" --rn-app-json "$GOOD_APP_JSON"

# 5a. A missing charter fails multiple checks, closed (Minor 2 gap).
DOCS_NO_CHARTER=$(make_docs_dir "stage-a-no-charter")
rm -f "$DOCS_NO_CHARTER/native-phase-12-cutover-charter.md"
expect_status 1 "FAIL: required doc present: cutover charter" \
  --stage A --docs-dir "$DOCS_NO_CHARTER" --build-settings "$GOOD_SETTINGS" --rn-app-json "$GOOD_APP_JSON"
expect_status 1 "FAIL: charter is owner-approved (charter doc missing)" \
  --stage A --docs-dir "$DOCS_NO_CHARTER" --build-settings "$GOOD_SETTINGS" --rn-app-json "$GOOD_APP_JSON"

# 6. R59: a marker that only says "pending" (no "ruled:") still fails (Minor 1/2).
DOCS_R59_PENDING=$(make_docs_dir "stage-a-r59-pending" "readiness-r59-pending.md" "native-phase-12-release-readiness.md")
expect_status 1 "FAIL: production build configuration decision is recorded (R59)" \
  --stage A --docs-dir "$DOCS_R59_PENDING" --build-settings "$GOOD_SETTINGS" --rn-app-json "$GOOD_APP_JSON"

# 6a. R59: no marker line at all also fails (Minor 2 gap).
DOCS_R59_MISSING=$(make_docs_dir "stage-a-r59-missing" "readiness-no-marker.md" "native-phase-12-release-readiness.md")
expect_status 1 "FAIL: production build configuration decision is recorded (R59)" \
  --stage A --docs-dir "$DOCS_R59_MISSING" --build-settings "$GOOD_SETTINGS" --rn-app-json "$GOOD_APP_JSON"

# 6b. R59: a real "ruled: R59" marker passes (paired with the all-good stage-C
#     assertion below, which already carries this marker via docs-good).

# 7. A stage whose predecessor has no run record fails, for every stage that
#    checks one: rehearsal (needs Stage A), B (needs Stage A), C (needs Stage
#    B) and exit (needs Stage C) -- Minor 2's "C and exit predecessor cases" gap.
DOCS_NO_RUN=$(make_docs_dir "stage-no-run" "evidence-index-no-run.md" "native-phase-12-evidence-index.md")
expect_status 1 'FAIL: evidence index: Stage A (12.04) has a recorded run (still says "No run recorded yet.")' \
  --stage rehearsal --docs-dir "$DOCS_NO_RUN" --build-settings "$GOOD_SETTINGS" --rn-app-json "$GOOD_APP_JSON"
expect_status 1 'FAIL: evidence index: Stage A (12.04) has a recorded run (still says "No run recorded yet.")' \
  --stage B --docs-dir "$DOCS_NO_RUN" --build-settings "$GOOD_SETTINGS" --rn-app-json "$GOOD_APP_JSON"
expect_status 1 'FAIL: evidence index: Stage B (12.05) has a recorded run (still says "No run recorded yet.")' \
  --stage C --docs-dir "$DOCS_NO_RUN" --build-settings "$GOOD_SETTINGS" --rn-app-json "$GOOD_APP_JSON"
expect_status 1 'FAIL: evidence index: Stage C (12.07) has a recorded run (still says "No run recorded yet.")' \
  --stage exit --docs-dir "$DOCS_NO_RUN" --build-settings "$GOOD_SETTINGS" --rn-app-json "$GOOD_APP_JSON"

# 7a. A predecessor section holding "No run recorded yet." plus extra text
#     still fails (substring match, not exact-equality -- Important 1(d)).
DOCS_NO_RUN_PLUS_NOTE="$TEMP_ROOT/stage-b-no-run-plus-note"
rm -rf "$DOCS_NO_RUN_PLUS_NOTE"
mkdir -p "$DOCS_NO_RUN_PLUS_NOTE"
cp "$GOOD_DOCS"/*.md "$DOCS_NO_RUN_PLUS_NOTE"/
python3 - "$DOCS_NO_RUN_PLUS_NOTE/native-phase-12-evidence-index.md" <<'EOF'
import sys
p = sys.argv[1]
t = open(p).read()
t = t.replace(
"""Run 1, 2026-09-10, build 100 (200), team accounts alpha/beta, REL/STG. Every
Stage-A-eligible row ran; no defect raised.""",
"No run recorded yet. A dry run is scheduled for next week."
)
open(p, "w").write(t)
EOF
expect_status 1 'FAIL: evidence index: Stage A (12.04) has a recorded run (still says "No run recorded yet.")' \
  --stage B --docs-dir "$DOCS_NO_RUN_PLUS_NOTE" --build-settings "$GOOD_SETTINGS" --rn-app-json "$GOOD_APP_JSON"

# 7b. Fix round 2, item 3 (predecessor check, now in scope): a predecessor
#     section holding only the unfilled evidence template (its own literal
#     placeholders, e.g. "Run <N>, <DATE>") is not a real run record. FAIL.
DOCS_TEMPLATE_ONLY=$(make_docs_dir "stage-a-template-only" "evidence-index-template-only.md" "native-phase-12-evidence-index.md")
expect_status 1 "FAIL: evidence index: Stage A (12.04) has a recorded run (still the unfilled evidence template, not real values)" \
  --stage B --docs-dir "$DOCS_TEMPLATE_ONLY" --build-settings "$GOOD_SETTINGS" --rn-app-json "$GOOD_APP_JSON"

# 8. Minor 3: --stage B checks the 12.06 rehearsal record itself, not only
#    Stage A's run; --stage rehearsal checks Stage A's run (already proved above).
DOCS_REHEARSAL_MISSING=$(make_docs_dir "stage-b-rehearsal-not-recorded" "evidence-index-rehearsal-not-recorded.md" "native-phase-12-evidence-index.md")
expect_status 1 "FAIL: evidence index: the 12.06 rehearsal is recorded" \
  --stage B --docs-dir "$DOCS_REHEARSAL_MISSING" --build-settings "$GOOD_SETTINGS" --rn-app-json "$GOOD_APP_JSON"

# ---------------------------------------------------------------------------
# All-good fixtures pass with only OWNER lines beyond PASS (and, on the
# P12-903 case, a specific ruling-recorded OWNER line -- never silently
# dropped, never a FAIL).
# ---------------------------------------------------------------------------

assert_all_good() {
  stage=$1
  docs_dir=$2
  set +e
  "$PREFLIGHT" --stage "$stage" --docs-dir "$docs_dir" --build-settings "$GOOD_SETTINGS" --rn-app-json "$GOOD_APP_JSON" \
    >"$OUTPUT_PATH" 2>&1
  status=$?
  set -e
  if [ "$status" -ne 0 ]; then
    sed -n '1,200p' "$OUTPUT_PATH" >&2
    echo "Expected the all-good fixture to pass for stage $stage (status 0), got $status" >&2
    exit 1
  fi
  if grep -q '^FAIL:' "$OUTPUT_PATH"; then
    sed -n '1,200p' "$OUTPUT_PATH" >&2
    echo "The all-good fixture produced a FAIL line for stage $stage" >&2
    exit 1
  fi
  if ! grep -q '^OWNER ' "$OUTPUT_PATH"; then
    echo "Expected at least one OWNER line even on the all-good fixture (stage $stage)" >&2
    exit 1
  fi
  if ! grep -q '^READY' "$OUTPUT_PATH"; then
    sed -n '1,200p' "$OUTPUT_PATH" >&2
    echo "Expected a READY summary line for stage $stage" >&2
    exit 1
  fi
}

assert_all_good A "$DOCS_A"
DOCS_B_GOOD=$(make_docs_dir "stage-b-good")
assert_all_good B "$DOCS_B_GOOD"
DOCS_C_GOOD=$(make_docs_dir "stage-c-good")
assert_all_good C "$DOCS_C_GOOD"
DOCS_EXIT_GOOD=$(make_docs_dir "stage-exit-good")
assert_all_good exit "$DOCS_EXIT_GOOD"
DOCS_REHEARSAL_GOOD=$(make_docs_dir "stage-rehearsal-good")
assert_all_good rehearsal "$DOCS_REHEARSAL_GOOD"

# ---------------------------------------------------------------------------
# Identifiers (Important 7 / R61): no output line contains a URL, a real
# production host, or the owner's team ID, across every fixture run above
# plus a run against the real committed docs.
# ---------------------------------------------------------------------------

ALL_OUTPUT="$TEMP_ROOT/all-output.txt"
: >"$ALL_OUTPUT"
for stage in A rehearsal B C exit; do
  "$PREFLIGHT" --stage "$stage" --docs-dir "$DOCS_A" --build-settings "$GOOD_SETTINGS" --rn-app-json "$GOOD_APP_JSON" >>"$ALL_OUTPUT" 2>&1 || true
  "$PREFLIGHT" --stage "$stage" --build-settings "$REAL_BUILD_SETTINGS" >>"$ALL_OUTPUT" 2>&1 || true
done
# URL/host check is case-insensitive; the team-ID shape check below is
# deliberately case-SENSITIVE (an Apple team ID is upper-case alphanumeric)
# so it does not also match an ordinary 10-letter lower-case English word.
if grep -Eiq 'https?://|[a-z0-9.-]+\.supabase\.co|[a-z0-9.-]+\.workers\.dev' "$ALL_OUTPUT"; then
  grep -Ein 'https?://|[a-z0-9.-]+\.supabase\.co|[a-z0-9.-]+\.workers\.dev' "$ALL_OUTPUT" >&2
  echo "A preflight output line contains a URL or bare host" >&2
  exit 1
fi
if grep -Eoq '\b[A-Z0-9]{10}\b' "$ALL_OUTPUT"; then
  grep -Eon '\b[A-Z0-9]{10}\b' "$ALL_OUTPUT" >&2
  echo "A preflight output line contains a 10-character upper-case alphanumeric token (an Apple team ID is shaped like this)" >&2
  exit 1
fi

# 10. Bad --stage value is refused.
set +e
"$PREFLIGHT" --stage bogus >/dev/null 2>&1
bad_stage_status=$?
set -e
if [ "$bad_stage_status" -ne 64 ]; then
  echo "Expected exit 64 for an invalid --stage, got $bad_stage_status" >&2
  exit 1
fi

echo "Phase 12 stage preflight tests passed."
