#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
PREFLIGHT="$ROOT_DIR/native/run-phase-12-stage-preflight.sh"
FIXTURES="$ROOT_DIR/native/Phase12StagePreflightTests/fixtures"
GOOD_DOCS="$FIXTURES/docs-good"
VARIANTS="$FIXTURES/docs-variants"
GOOD_SETTINGS="$FIXTURES/good-build-settings.txt"
OUTPUT_PATH="${TMPDIR:-/tmp}/tradeready-phase12-preflight-test-output"

TEMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/tradeready-phase12-preflight-tests.XXXXXX")
trap 'rm -rf "$TEMP_ROOT"' EXIT HUP INT TERM

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

# 1. Placeholder staging backend fails.
DOCS_A=$(make_docs_dir "stage-a-good")
expect_status 1 "FAIL: backend URL is not the placeholder" \
  --stage A --docs-dir "$DOCS_A" --build-settings "$FIXTURES/placeholder-build-settings.txt"

# 2. Production-matched Supabase value fails.
expect_status 1 "FAIL: Supabase URL does not match the production project" \
  --stage A --docs-dir "$DOCS_A" --build-settings "$FIXTURES/production-matched-build-settings.txt"

# 3. DRAFT charter fails.
DOCS_DRAFT=$(make_docs_dir "stage-a-draft" "charter-draft.md" "native-phase-12-cutover-charter.md")
expect_status 1 "FAIL: charter is owner-approved" \
  --stage A --docs-dir "$DOCS_DRAFT" --build-settings "$GOOD_SETTINGS"

# 4. An open blocking defect (12.00b.2) fails.
DOCS_OPEN=$(make_docs_dir "stage-a-open-blocker" "charter-open-blocker.md" "native-phase-12-cutover-charter.md")
expect_status 1 "FAIL: defect list: 12.00b.2 (S1/S2 code fixes) rows are Fixed (open: L130)" \
  --stage A --docs-dir "$DOCS_OPEN" --build-settings "$GOOD_SETTINGS"

# 5. A missing required doc fails.
DOCS_MISSING=$(make_docs_dir "stage-a-missing-doc")
rm -f "$DOCS_MISSING/native-phase-12-monitoring.md"
expect_status 1 "FAIL: required doc present: monitoring doc" \
  --stage A --docs-dir "$DOCS_MISSING" --build-settings "$GOOD_SETTINGS"

# 6. A stage whose predecessor has no run record fails (Stage B needs Stage A recorded).
DOCS_NO_RUN=$(make_docs_dir "stage-b-no-run" "evidence-index-no-run.md" "native-phase-12-evidence-index.md")
expect_status 1 'FAIL: evidence index: Stage A (12.04) has a recorded run (still "No run recorded yet.")' \
  --stage B --docs-dir "$DOCS_NO_RUN" --build-settings "$GOOD_SETTINGS"

# 7. An all-good fixture passes with only OWNER lines beyond PASS (stage A: every
#    local check can pass, since P12-012 does not exist in this fixture charter).
set +e
"$PREFLIGHT" --stage A --docs-dir "$DOCS_A" --build-settings "$GOOD_SETTINGS" >"$OUTPUT_PATH" 2>&1
status=$?
set -e
if [ "$status" -ne 0 ]; then
  sed -n '1,200p' "$OUTPUT_PATH" >&2
  echo "Expected the all-good fixture to pass (status 0), got $status" >&2
  exit 1
fi
if grep -q '^FAIL:' "$OUTPUT_PATH"; then
  sed -n '1,200p' "$OUTPUT_PATH" >&2
  echo "The all-good fixture produced a FAIL line" >&2
  exit 1
fi
if ! grep -q '^OWNER ' "$OUTPUT_PATH"; then
  echo "Expected at least one OWNER line even on the all-good fixture" >&2
  exit 1
fi
if ! grep -q '^READY' "$OUTPUT_PATH"; then
  sed -n '1,200p' "$OUTPUT_PATH" >&2
  echo "Expected a READY summary line" >&2
  exit 1
fi

# 8. An all-good fixture also passes for stage B (predecessor recorded) and exit
#    (predecessor recorded, exit-report doc present), confirming the stage-specific
#    branches do not accidentally fail on good input.
DOCS_B_GOOD=$(make_docs_dir "stage-b-good")
expect_status 0 "READY" --stage B --docs-dir "$DOCS_B_GOOD" --build-settings "$GOOD_SETTINGS"
DOCS_EXIT_GOOD=$(make_docs_dir "stage-exit-good")
expect_status 0 "READY" --stage exit --docs-dir "$DOCS_EXIT_GOOD" --build-settings "$GOOD_SETTINGS"
DOCS_C_GOOD=$(make_docs_dir "stage-c-good")
expect_status 0 "READY" --stage C --docs-dir "$DOCS_C_GOOD" --build-settings "$GOOD_SETTINGS"
DOCS_REHEARSAL_GOOD=$(make_docs_dir "stage-rehearsal-good")
expect_status 0 "READY" --stage rehearsal --docs-dir "$DOCS_REHEARSAL_GOOD" --build-settings "$GOOD_SETTINGS"

# 9. No output line contains a URL, across every fixture run above plus a run
#    against the real committed docs (which do carry real content, but the
#    preflight itself must never print one).
ALL_OUTPUT="$TEMP_ROOT/all-output.txt"
: >"$ALL_OUTPUT"
for stage in A rehearsal B C exit; do
  "$PREFLIGHT" --stage "$stage" --docs-dir "$DOCS_A" --build-settings "$GOOD_SETTINGS" >>"$ALL_OUTPUT" 2>&1 || true
  "$PREFLIGHT" --stage "$stage" >>"$ALL_OUTPUT" 2>&1 || true
done
if grep -Eiq 'https?://|[a-z0-9.-]+\.supabase\.co|[a-z0-9.-]+\.workers\.dev' "$ALL_OUTPUT"; then
  grep -Ein 'https?://|[a-z0-9.-]+\.supabase\.co|[a-z0-9.-]+\.workers\.dev' "$ALL_OUTPUT" >&2
  echo "A preflight output line contains a URL or bare host" >&2
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
