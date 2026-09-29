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

# Like expect_status, but under a UTF-8 locale (an owner's Terminal default),
# and also asserting that no awk error reached the output (final review items
# 28 and 30; Task 14 re-review 4, Minor 1 and out-of-scope 2).
expect_status_utf8() {
  expected_status=$1
  expected_text=$2
  shift 2

  set +e
  env LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 "$PREFLIGHT" "$@" >"$OUTPUT_PATH" 2>&1
  actual_status=$?
  set -e

  if [ "$actual_status" -ne "$expected_status" ]; then
    sed -n '1,200p' "$OUTPUT_PATH" >&2
    echo "Expected status $expected_status under UTF-8, got $actual_status (args: $*)" >&2
    exit 1
  fi
  if ! grep -F -q "$expected_text" "$OUTPUT_PATH"; then
    sed -n '1,200p' "$OUTPUT_PATH" >&2
    echo "Missing expected result under UTF-8: $expected_text (args: $*)" >&2
    exit 1
  fi
  if grep -q 'awk:' "$OUTPUT_PATH"; then
    sed -n '1,200p' "$OUTPUT_PATH" >&2
    echo "awk failed under UTF-8 (args: $*)" >&2
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

# 3b. Final review item 30 (Task 14 re-review 4, out-of-scope 2): the Status
#     line's excerpt is cut at 80 bytes whatever the locale. `cut -c` counts
#     characters under UTF-8 and bytes under C, so a long Status line with an
#     em dash used to print two more characters under UTF-8 than the C-locale
#     run the stage runbook pastes. The FAIL line must be identical.
DOCS_LONG_STATUS=$(make_docs_dir "stage-a-long-status" "charter-draft-long-status.md" "native-phase-12-cutover-charter.md")
set +e
env LC_ALL=C "$PREFLIGHT" --stage A --docs-dir "$DOCS_LONG_STATUS" --build-settings "$GOOD_SETTINGS" --rn-app-json "$GOOD_APP_JSON" 2>&1 \
  | grep '^FAIL: charter is owner-approved' >"$TEMP_ROOT/status-c.txt"
env LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 "$PREFLIGHT" --stage A --docs-dir "$DOCS_LONG_STATUS" --build-settings "$GOOD_SETTINGS" --rn-app-json "$GOOD_APP_JSON" 2>&1 \
  | grep '^FAIL: charter is owner-approved' >"$TEMP_ROOT/status-utf8.txt"
set -e
if [ ! -s "$TEMP_ROOT/status-c.txt" ] || ! cmp -s "$TEMP_ROOT/status-c.txt" "$TEMP_ROOT/status-utf8.txt"; then
  cat "$TEMP_ROOT/status-c.txt" "$TEMP_ROOT/status-utf8.txt" >&2
  echo "The Status-line FAIL differs between the C and UTF-8 locales" >&2
  exit 1
fi
if ! grep -F -q "(Status line reads: **Status: DRAFT — not owner-approved.** Written 2026-09-25 on branch native/ph)" "$TEMP_ROOT/status-c.txt"; then
  cat "$TEMP_ROOT/status-c.txt" >&2
  echo "The Status-line excerpt is not the first 80 bytes" >&2
  exit 1
fi

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

# 4c. The P12-012-style ruling gate, both directions.
#   - An open S1 with NO recorded ruling at all: FAIL, naming the ID.
DOCS_NO_RULING=$(make_docs_dir "stage-a-no-ruling" "charter-open-s1-no-ruling.md" "native-phase-12-cutover-charter.md")
expect_status 1 "FAIL: defect list: no open S1/S2 blocks stage entry (open, no recorded ruling: P12-903)" \
  --stage A --docs-dir "$DOCS_NO_RULING" --build-settings "$GOOD_SETTINGS" --rn-app-json "$GOOD_APP_JSON"

#   - A decision-log row that names the ID and mentions the ruling number, but
#     never says "ruled:" (e.g. "ruling requested, still pending"): FAIL.
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

# 4d. Fix round 3 (ruling R65): a strict grammar replaces the word-list
#     negation logic. A §9 row counts as a ruling only when its Decision cell,
#     trimmed, is EXACTLY "<id> ruled: R<n>" and its Decider cell, trimmed and
#     case-insensitive, is exactly "owner". Every one of the following fixture
#     rows deviates from that exact form in one way and must FAIL, naming
#     P12-903 as still blocking:
for variant in \
  charter-marker-combined-row.md \
  charter-marker-negated.md \
  charter-marker-non-owner-decider.md \
  charter-marker-different-defect.md \
  charter-marker-qualifier-after.md \
  charter-marker-unruled.md \
  charter-marker-overruled.md \
  charter-marker-to-be-ruled.md \
; do
  DOCS_VARIANT=$(make_docs_dir "stage-a-${variant%.md}" "$variant" "native-phase-12-cutover-charter.md")
  expect_status 1 "FAIL: defect list: no open S1/S2 blocks stage entry (open, no recorded ruling: P12-903)" \
    --stage A --docs-dir "$DOCS_VARIANT" --build-settings "$GOOD_SETTINGS" --rn-app-json "$GOOD_APP_JSON"
done

#   - The exact form, followed by a LATER row whose Decision cell is exactly
#     "P12-903 revoked: R900": re-blocks the defect (the log is append-only,
#     newest last, so the later row wins).
DOCS_REVOKED=$(make_docs_dir "stage-a-revoked-ruling" "charter-marker-revoked.md" "native-phase-12-cutover-charter.md")
expect_status 1 "FAIL: defect list: no open S1/S2 blocks stage entry (open, no recorded ruling: P12-903)" \
  --stage A --docs-dir "$DOCS_REVOKED" --build-settings "$GOOD_SETTINGS" --rn-app-json "$GOOD_APP_JSON"

#   - The correct owner row PASSes (OWNER line, not FAIL): already proved by
#     the docs-good assertions immediately above (P12-903 / R900).

# 4d-2. Fix round 4 (ruling R67): rulings stay strict, but revocation is
#       lenient and fails closed. After the exact owner ruling, ANY later §9
#       row that names P12-903 and says "revoked" (any case, any wording, any
#       Decider) re-blocks it: a draft revoke, a revoke with its reason inline,
#       a capitalized "Revoked:" and an exact revoke by a non-owner.
for variant in \
  charter-marker-revoked-draft.md \
  charter-marker-revoked-reason.md \
  charter-marker-revoked-capitalized.md \
  charter-marker-revoked-non-owner.md \
; do
  DOCS_VARIANT=$(make_docs_dir "stage-a-${variant%.md}" "$variant" "native-phase-12-cutover-charter.md")
  expect_status 1 "FAIL: defect list: no open S1/S2 blocks stage entry (open, no recorded ruling: P12-903)" \
    --stage A --docs-dir "$DOCS_VARIANT" --build-settings "$GOOD_SETTINGS" --rn-app-json "$GOOD_APP_JSON"
done

#   - A later exact owner re-rule after a revoke passes again (the last row
#     wins), even though its Evidence cell mentions the revoked row.
DOCS_RERULED=$(make_docs_dir "stage-a-revoked-then-reruled" "charter-marker-revoked-then-reruled.md" "native-phase-12-cutover-charter.md")
expect_status 0 "OWNER defect list: P12-903 (open S1, ruling R900 recorded — owner still authorizes stage entry)" \
  --stage A --docs-dir "$DOCS_RERULED" --build-settings "$GOOD_SETTINGS" --rn-app-json "$GOOD_APP_JSON"

# 4d-3. Final review item 28 (Task 14 re-review 4, Minor 1): a multibyte
#       character touching the ID ("P12-903’s", a smart apostrophe) in a
#       revoking row, under a UTF-8 locale. macOS awk decodes a regex match
#       to wide characters and used to exit on the partial byte `names()`
#       takes next to the ID, so every later row went unread. The row must
#       re-block the defect with no awk error, and a later exact owner
#       re-rule must still be read and clear it. Both also in the C locale.
DOCS_MB_REVOKED=$(make_docs_dir "stage-a-revoked-multibyte" "charter-marker-revoked-multibyte.md" "native-phase-12-cutover-charter.md")
expect_status_utf8 1 "FAIL: defect list: no open S1/S2 blocks stage entry (open, no recorded ruling: P12-903)" \
  --stage A --docs-dir "$DOCS_MB_REVOKED" --build-settings "$GOOD_SETTINGS" --rn-app-json "$GOOD_APP_JSON"
expect_status 1 "FAIL: defect list: no open S1/S2 blocks stage entry (open, no recorded ruling: P12-903)" \
  --stage A --docs-dir "$DOCS_MB_REVOKED" --build-settings "$GOOD_SETTINGS" --rn-app-json "$GOOD_APP_JSON"
DOCS_MB_RERULED=$(make_docs_dir "stage-a-revoked-multibyte-then-reruled" "charter-marker-revoked-multibyte-then-reruled.md" "native-phase-12-cutover-charter.md")
expect_status_utf8 0 "OWNER defect list: P12-903 (open S1, ruling R900 recorded — owner still authorizes stage entry)" \
  --stage A --docs-dir "$DOCS_MB_RERULED" --build-settings "$GOOD_SETTINGS" --rn-app-json "$GOOD_APP_JSON"
expect_status 0 "OWNER defect list: P12-903 (open S1, ruling R900 recorded — owner still authorizes stage entry)" \
  --stage A --docs-dir "$DOCS_MB_RERULED" --build-settings "$GOOD_SETTINGS" --rn-app-json "$GOOD_APP_JSON"

# 4e. Minor 6 continuation (fix rounds 2-3): a defect row this scanner cannot
#     parse cleanly must FAIL with a named line when it looks like it could
#     be S1/S2, not be silently skipped -- an odd ID, an extra "|" in a cell,
#     a missing leading "|", or a severity cell with no clean S-token at all.
DOCS_ODD_ID=$(make_docs_dir "stage-a-unparseable-odd-id" "charter-unparseable-odd-id.md" "native-phase-12-cutover-charter.md")
expect_status 1 "FAIL: defect list: no open S1/S2 blocks stage entry (open, no recorded ruling: [unparseable id: P12-999" \
  --stage A --docs-dir "$DOCS_ODD_ID" --build-settings "$GOOD_SETTINGS" --rn-app-json "$GOOD_APP_JSON"
DOCS_EXTRA_PIPE=$(make_docs_dir "stage-a-unparseable-extra-pipe" "charter-unparseable-extra-pipe.md" "native-phase-12-cutover-charter.md")
expect_status 1 "FAIL: defect list: no open S1/S2 blocks stage entry (open, no recorded ruling: [unparseable row (wrong column count): | P12-997" \
  --stage A --docs-dir "$DOCS_EXTRA_PIPE" --build-settings "$GOOD_SETTINGS" --rn-app-json "$GOOD_APP_JSON"
DOCS_NO_LEADING_PIPE=$(make_docs_dir "stage-a-no-leading-pipe" "charter-no-leading-pipe.md" "native-phase-12-cutover-charter.md")
expect_status 1 "FAIL: defect list: no open S1/S2 blocks stage entry (open, no recorded ruling: [unparseable row (wrong column count): P12-991" \
  --stage A --docs-dir "$DOCS_NO_LEADING_PIPE" --build-settings "$GOOD_SETTINGS" --rn-app-json "$GOOD_APP_JSON"
DOCS_AMBIGUOUS_SEV=$(make_docs_dir "stage-a-ambiguous-severity" "charter-severity-ambiguous.md" "native-phase-12-cutover-charter.md")
expect_status 1 "FAIL: defect list: no open S1/S2 blocks stage entry (open, no recorded ruling: [P12-992: ambiguous severity cell 'Sev-one']" \
  --stage A --docs-dir "$DOCS_AMBIGUOUS_SEV" --build-settings "$GOOD_SETTINGS" --rn-app-json "$GOOD_APP_JSON"

# 4f. Fix rounds 3-4, Minor 6 continuation: a severity cell that is not
#     exactly S1/S2/S3 resolves to its EFFECTIVE severity, which is the MOST
#     severe whole-word S1/S2/S3 token in the cell, case-insensitive (fix
#     round 4, ruling R67). The most severe token fails closed whichever way
#     an annotation runs: "S2 (was S3)" is S2, "S3 (was S2)" is S2 (over-blocks
#     safely), "~~S1~~ S2" is S1. Round 3's last-token rule read "S2 (was S3)"
#     as S3 and silently passed it; round 2's fixture for that suffix
#     notation, charter-unparseable-annotated-severity.md (P12-998), is
#     restored here under its round-2 name.
#     Each added row is Open and cites its own ruling, so:
#       (a) with no ruling on file, a correct resolution to S1/S2 blocks it by
#           name;
#       (b) with an exact owner ruling appended to §9, the OWNER line names the
#           resolved severity, which proves the most-severe rule directly.
for variant_case in \
  "charter-unparseable-annotated-severity.md:P12-998:R998:S2" \
  "charter-severity-suffix-s1-was-s3.md:P12-989:R989:S1" \
  "charter-severity-suffix-s3-was-s2.md:P12-988:R988:S2" \
  "charter-severity-strikethrough.md:P12-996:R996:S1" \
  "charter-severity-arrow.md:P12-995:R995:S2" \
  "charter-severity-was-annotation.md:P12-994:R994:S2" \
  "charter-severity-lowercase.md:P12-993:R993:S1" \
; do
  variant=${variant_case%%:*}
  rest=${variant_case#*:}
  expected_id=${rest%%:*}
  rest=${rest#*:}
  expected_ruling=${rest%%:*}
  expected_sev=${rest#*:}
  DOCS_SEV=$(make_docs_dir "stage-a-${variant%.md}" "$variant" "native-phase-12-cutover-charter.md")
  expect_status 1 "FAIL: defect list: no open S1/S2 blocks stage entry (open, no recorded ruling: $expected_id)" \
    --stage A --docs-dir "$DOCS_SEV" --build-settings "$GOOD_SETTINGS" --rn-app-json "$GOOD_APP_JSON"
  DOCS_SEV_RULED=$(make_docs_dir "stage-a-${variant%.md}-ruled" "$variant" "native-phase-12-cutover-charter.md")
  awk -v r="| 3 | 2026-09-02 | pre-A | $expected_id ruled: $expected_ruling | fixture accepts the risk | owner | n/a |" \
    '{ print } /^\| 2 \| 2026-09-01 \| pre-A \| P12-903 ruled: R900 \|/ { print r }' \
    "$VARIANTS/$variant" >"$DOCS_SEV_RULED/native-phase-12-cutover-charter.md"
  expect_status 0 "OWNER defect list: $expected_id (open $expected_sev, ruling $expected_ruling recorded" \
    --stage A --docs-dir "$DOCS_SEV_RULED" --build-settings "$GOOD_SETTINGS" --rn-app-json "$GOOD_APP_JSON"
done

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

# 6c. Fix round 3, item 2: the same strictness applies to the R59 line. The
#     runbook's own unfilled template line, reproduced verbatim
#     ("Production configuration decision: <what was decided> ruled: R59"),
#     must FAIL -- the "<...>" placeholder is never a filled-in decision.
DOCS_R59_TEMPLATE=$(make_docs_dir "stage-a-r59-unfilled-template" "readiness-r59-unfilled-template.md" "native-phase-12-release-readiness.md")
expect_status 1 "FAIL: production build configuration decision is recorded (R59) — the decision line still holds a <...> placeholder from the stage runbook's R59 template" \
  --stage A --docs-dir "$DOCS_R59_TEMPLATE" --build-settings "$GOOD_SETTINGS" --rn-app-json "$GOOD_APP_JSON"

# 6d. Fix round 4 (finding 3): the R59 decision gets the same lenient,
#     fail-closed revocation as a §9 ruling. After the decision line, any
#     later line that says "revoked" (any case) and names the decision or R59
#     re-blocks it; a later exact decision line passes again (last line wins).
for variant in \
  readiness-r59-revoked.md \
  readiness-r59-revoked-reason.md \
; do
  DOCS_VARIANT=$(make_docs_dir "stage-a-${variant%.md}" "$variant" "native-phase-12-release-readiness.md")
  expect_status 1 "FAIL: production build configuration decision is recorded (R59) — a later line in the release-readiness doc revokes it" \
    --stage A --docs-dir "$DOCS_VARIANT" --build-settings "$GOOD_SETTINGS" --rn-app-json "$GOOD_APP_JSON"
done
DOCS_R59_RERULED=$(make_docs_dir "stage-a-r59-revoked-then-reruled" "readiness-r59-revoked-then-reruled.md" "native-phase-12-release-readiness.md")
expect_status 0 "PASS: production build configuration decision is recorded (R59)" \
  --stage A --docs-dir "$DOCS_R59_RERULED" --build-settings "$GOOD_SETTINGS" --rn-app-json "$GOOD_APP_JSON"

# 6d-2. Final review item 28: the same multibyte case for the R59 line
#       ("R59’s decision is revoked"), under UTF-8: the revoking line gets the
#       "revokes it" FAIL (it used to get the generic "owner must rule" FAIL
#       after awk exited), and a later exact decision line still passes.
DOCS_R59_MB=$(make_docs_dir "stage-a-r59-revoked-multibyte" "readiness-r59-revoked-multibyte.md" "native-phase-12-release-readiness.md")
expect_status_utf8 1 "FAIL: production build configuration decision is recorded (R59) — a later line in the release-readiness doc revokes it" \
  --stage A --docs-dir "$DOCS_R59_MB" --build-settings "$GOOD_SETTINGS" --rn-app-json "$GOOD_APP_JSON"
DOCS_R59_MB_RERULED=$(make_docs_dir "stage-a-r59-revoked-multibyte-then-reruled" "readiness-r59-revoked-multibyte-then-reruled.md" "native-phase-12-release-readiness.md")
expect_status_utf8 0 "PASS: production build configuration decision is recorded (R59)" \
  --stage A --docs-dir "$DOCS_R59_MB_RERULED" --build-settings "$GOOD_SETTINGS" --rn-app-json "$GOOD_APP_JSON"

# 6e. Fix round 4 (finding 4): a spaced comparison in the decision text
#     ("p95 sync < 800 ms > baseline") is not a placeholder and passes; a
#     placeholder has no space just inside its brackets (<build>, <what was
#     decided>), and still fails (6c above).
DOCS_R59_COMPARISON=$(make_docs_dir "stage-a-r59-comparison" "readiness-r59-comparison.md" "native-phase-12-release-readiness.md")
expect_status 0 "PASS: production build configuration decision is recorded (R59)" \
  --stage A --docs-dir "$DOCS_R59_COMPARISON" --build-settings "$GOOD_SETTINGS" --rn-app-json "$GOOD_APP_JSON"

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
expect_status 1 "FAIL: evidence index: Stage A (12.04) has a recorded run (still holds a placeholder from the stage runbook's \"### Stage A (12.04)\" evidence template: <" \
  --stage B --docs-dir "$DOCS_TEMPLATE_ONLY" --build-settings "$GOOD_SETTINGS" --rn-app-json "$GOOD_APP_JSON"

# 7c. Fix round 4 (finding 4): only the runbook template's OWN placeholder
#     tokens (read from the template text) mark an unfilled record. A real
#     record that compares values with "<" and ">" ("latency < 200 ms >
#     baseline") passes.
DOCS_COMPARISON=$(make_docs_dir "stage-b-comparison-record" "evidence-index-comparison-record.md" "native-phase-12-evidence-index.md")
expect_status 0 "PASS: evidence index: Stage A (12.04) has a recorded run" \
  --stage B --docs-dir "$DOCS_COMPARISON" --build-settings "$GOOD_SETTINGS" --rn-app-json "$GOOD_APP_JSON"

# 7d. The template's placeholders cannot be ruled out without the template:
#     a missing stage runbook fails the predecessor check closed.
DOCS_NO_RUNBOOK=$(make_docs_dir "stage-b-no-runbook")
rm -f "$DOCS_NO_RUNBOOK/native-phase-12-stage-runbook.md"
expect_status 1 "FAIL: evidence index: Stage A (12.04) has a recorded run (cannot read the stage runbook's \"### Stage A (12.04)\" evidence template" \
  --stage B --docs-dir "$DOCS_NO_RUNBOOK" --build-settings "$GOOD_SETTINGS" --rn-app-json "$GOOD_APP_JSON"

# 7e. The same two cases against the REAL committed runbook's templates, so a
#     change to a real template cannot silently stop matching: its Stage A,
#     B and C templates pasted verbatim as the record FAIL; the comparison
#     record PASSes.
for real_case in "Stage A (12.04):B" "Stage B (12.05):C" "Stage C (12.07):exit"; do
  real_heading=${real_case%:*}
  real_stage=${real_case##*:}
  DOCS_REAL_TEMPLATE=$(make_docs_dir "stage-${real_stage}-real-runbook-template")
  cp "$ROOT_DIR/docs/native-phase-12-stage-runbook.md" "$DOCS_REAL_TEMPLATE/native-phase-12-stage-runbook.md"
  python3 - "$DOCS_REAL_TEMPLATE" "$real_heading" <<'EOF'
import sys
d, heading = sys.argv[1], sys.argv[2]
runbook = open(d + "/native-phase-12-stage-runbook.md").read().split("\n")
start = next(i for i, l in enumerate(runbook)
             if l.startswith("### ") and "Evidence template" in l and '"### ' + heading + '"' in l)
fence = next(i for i in range(start + 1, len(runbook)) if runbook[i].startswith("```"))
end = next(i for i in range(fence + 1, len(runbook)) if runbook[i].startswith("```"))
template = "\n".join(runbook[fence + 1:end])
p = d + "/native-phase-12-evidence-index.md"
lines = open(p).read().split("\n")
h = lines.index("### " + heading)
nxt = next((i for i in range(h + 1, len(lines)) if lines[i].startswith("### ")), len(lines))
lines[h + 1:nxt] = ["", template, ""]
open(p, "w").write("\n".join(lines))
EOF
  expect_status 1 "FAIL: evidence index: $real_heading has a recorded run (still holds a placeholder from the stage runbook's \"### $real_heading\" evidence template: <" \
    --stage "$real_stage" --docs-dir "$DOCS_REAL_TEMPLATE" --build-settings "$GOOD_SETTINGS" --rn-app-json "$GOOD_APP_JSON"
done
DOCS_REAL_COMPARISON=$(make_docs_dir "stage-b-real-runbook-comparison" "evidence-index-comparison-record.md" "native-phase-12-evidence-index.md")
cp "$ROOT_DIR/docs/native-phase-12-stage-runbook.md" "$DOCS_REAL_COMPARISON/native-phase-12-stage-runbook.md"
expect_status 0 "PASS: evidence index: Stage A (12.04) has a recorded run" \
  --stage B --docs-dir "$DOCS_REAL_COMPARISON" --build-settings "$GOOD_SETTINGS" --rn-app-json "$GOOD_APP_JSON"

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
