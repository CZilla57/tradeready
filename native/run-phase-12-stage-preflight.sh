#!/bin/sh
# Phase 12 — offline, fail-closed readiness check for an owner-run stage.
#
# Usage: run-phase-12-stage-preflight.sh --stage A|rehearsal|B|C|exit
#            [--docs-dir DIR] [--build-settings FILE] [--pbxproj FILE]
#
# Checks only what this repository can prove without a network call, an
# App Store Connect/TestFlight session or a signed build. It never fixes a
# placeholder or production-matched value, and it prints no URL, credential,
# device identifier or record value. Every line is exactly one of:
#   PASS: <check>
#   FAIL: <check>
#   OWNER <check> — not checkable offline
# Exit status is non-zero if any local check fails (OWNER lines never count
# as a failure, and never count as a pass either).
set -u

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
DOCS_DIR="$ROOT_DIR/docs"
BUILD_SETTINGS_FILE=
PBXPROJ_FILE="$ROOT_DIR/native/TradeReadyNative.xcodeproj/project.pbxproj"
STAGE=

usage() {
  echo "Usage: $0 --stage A|rehearsal|B|C|exit [--docs-dir DIR] [--build-settings FILE] [--pbxproj FILE]"
  echo ""
  echo "Offline, fail-closed readiness check for a Phase 12 owner-run stage."
  echo "Prints one PASS/FAIL/OWNER line per check and exits non-zero on any FAIL."
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --stage)
      [ "$#" -ge 2 ] || { usage >&2; exit 64; }
      STAGE=$2
      shift 2
      ;;
    --docs-dir)
      [ "$#" -ge 2 ] || { usage >&2; exit 64; }
      DOCS_DIR=$2
      shift 2
      ;;
    --build-settings)
      [ "$#" -ge 2 ] || { usage >&2; exit 64; }
      BUILD_SETTINGS_FILE=$2
      shift 2
      ;;
    --pbxproj)
      [ "$#" -ge 2 ] || { usage >&2; exit 64; }
      PBXPROJ_FILE=$2
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 64
      ;;
  esac
done

case "$STAGE" in
  A|rehearsal|B|C|exit) ;;
  *) usage >&2; exit 64 ;;
esac

CHARTER="$DOCS_DIR/native-phase-12-cutover-charter.md"
EVIDENCE="$DOCS_DIR/native-phase-12-evidence-index.md"
MONITORING="$DOCS_DIR/native-phase-12-monitoring.md"
PLAYBOOK="$DOCS_DIR/native-phase-12-rollback-playbook.md"
READINESS="$DOCS_DIR/native-phase-12-release-readiness.md"
EXIT_REPORT="$DOCS_DIR/native-phase-12-exit-report.md"

TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/tradeready-phase12-preflight.XXXXXX")
trap 'rm -rf "$TEMP_DIR"' EXIT HUP INT TERM

failures=0

pass() {
  printf 'PASS: %s\n' "$1"
}

fail() {
  failures=$((failures + 1))
  printf 'FAIL: %s\n' "$1"
}

owner() {
  printf 'OWNER %s — not checkable offline\n' "$1"
}

# ---------------------------------------------------------------------------
# 1. Staging / production-match config (phase-3/4 preflight logic, extended
#    with an explicit production-match check the phase-3/4 scripts do not
#    make: a runtime value that resolves to a real production host).
# ---------------------------------------------------------------------------

configured_value() {
  key=$1
  sed -n "s/^[[:space:]]*$key = //p" "$BUILD_SETTINGS_FILE" | tail -n 1
}

is_placeholder_https() {
  case "$1" in
    https://staging.invalid|https://*.invalid|https://localhost*|https://127.0.0.1*|http://127.0.0.1*|http://localhost*) return 0 ;;
    *) return 1 ;;
  esac
}

# Public, non-secret production hosts (shipped in the app bundle; already
# printed in plaintext in docs/native-phase-12-release-readiness.md §3.2 and
# backend-workers/wrangler.toml's committed [vars] block). Never a secret.
PRODUCTION_BACKEND_HOST="tradeready-backend.tradeready.workers.dev"
PRODUCTION_SUPABASE_HOST="ncbqswfdvckmdocbawaa.supabase.co"

build_settings_available=1
if [ -z "$BUILD_SETTINGS_FILE" ]; then
  BUILD_SETTINGS_FILE="$TEMP_DIR/release-build-settings.txt"
  if ! xcodebuild \
    -project "$ROOT_DIR/native/TradeReadyNative.xcodeproj" \
    -scheme TradeReadyNative \
    -configuration Release \
    -sdk iphoneos \
    -showBuildSettings >"$BUILD_SETTINGS_FILE" 2>"$TEMP_DIR/xcodebuild.stderr"; then
    fail "release build settings resolve (xcodebuild could not resolve them)"
    build_settings_available=0
  fi
elif [ ! -r "$BUILD_SETTINGS_FILE" ]; then
  fail "release build settings resolve (the supplied file is unreadable)"
  build_settings_available=0
fi

if [ "$build_settings_available" -eq 1 ]; then
  environment=$(configured_value TRADEREADY_ENVIRONMENT)
  backend_url=$(configured_value TRADEREADY_BACKEND_URL)
  supabase_url=$(configured_value TRADEREADY_SUPABASE_URL)
  production_writes=$(configured_value TRADEREADY_ALLOW_PRODUCTION_WRITES)

  if is_placeholder_https "$backend_url"; then
    fail "backend URL is not the placeholder (staging.invalid/local host)"
  else
    case "$backend_url" in
      https://*) pass "backend URL is not the placeholder (staging.invalid/local host)" ;;
      *) fail "backend URL is not the placeholder (staging.invalid/local host)" ;;
    esac
  fi

  if [ "$environment" != production ] && [ "$backend_url" = "https://$PRODUCTION_BACKEND_HOST" ]; then
    fail "backend URL does not resolve to the production Worker outside a production build"
  else
    pass "backend URL does not resolve to the production Worker outside a production build"
  fi

  if is_placeholder_https "$supabase_url"; then
    fail "Supabase URL is not the placeholder (staging.invalid/local host)"
  else
    case "$supabase_url" in
      https://*) pass "Supabase URL is not the placeholder (staging.invalid/local host)" ;;
      *) fail "Supabase URL is not the placeholder (staging.invalid/local host)" ;;
    esac
  fi

  if [ "$environment" != production ] && [ "$supabase_url" = "https://$PRODUCTION_SUPABASE_HOST" ]; then
    fail "Supabase URL does not match the production project outside a production build"
  else
    pass "Supabase URL does not match the production project outside a production build"
  fi

  if [ "$environment" = production ]; then
    if [ "$production_writes" = YES ]; then
      pass "production writes are enabled only in a production build"
    else
      fail "a production build must enable production writes under a recorded ruling"
    fi
  else
    if [ "$production_writes" = NO ]; then
      pass "production writes are disabled outside a production build"
    else
      fail "production writes are disabled outside a production build"
    fi
  fi
fi

# ---------------------------------------------------------------------------
# 2. Required docs exist for this stage.
# ---------------------------------------------------------------------------

require_doc() {
  path=$1
  label=$2
  if [ -r "$path" ]; then
    pass "required doc present: $label"
  else
    fail "required doc present: $label ($path)"
  fi
}

require_doc "$CHARTER" "cutover charter"
require_doc "$EVIDENCE" "evidence index"
require_doc "$MONITORING" "monitoring doc"
require_doc "$PLAYBOOK" "rollback playbook"
require_doc "$READINESS" "release readiness"
if [ "$STAGE" = exit ]; then
  require_doc "$EXIT_REPORT" "exit report template"
fi

# ---------------------------------------------------------------------------
# 3. Charter is owner-approved (its Status line is not DRAFT).
# ---------------------------------------------------------------------------

if [ -r "$CHARTER" ]; then
  status_line=$(grep -m1 '^\*\*Status:' "$CHARTER" || true)
  if [ -z "$status_line" ]; then
    fail "charter has a Status line"
  else
    case "$status_line" in
      *DRAFT*|*"not owner-approved"*) fail "charter is owner-approved (Status line reads: $(printf '%s' "$status_line" | cut -c1-80))" ;;
      *) pass "charter is owner-approved" ;;
    esac
  fi
else
  fail "charter is owner-approved (charter doc missing)"
fi

# ---------------------------------------------------------------------------
# 4. Defect list: no open Stage-blocking S1/S2.
#    - Every row in the 12.00b.1 and 12.00b.2 sections must be Fixed.
#    - Every "New in Phase 12" row with severity S1 or S2 must be Fixed,
#      unless the charter's decision log (§9) records the owner's ruling
#      referenced by that row (e.g. "R43") — an accepted, logged exception,
#      not a silent pass.
# ---------------------------------------------------------------------------

defect_section_clear() {
  section_heading=$1
  label=$2
  if [ ! -r "$CHARTER" ]; then
    fail "defect list: $label rows are Fixed (charter doc missing)"
    return
  fi
  section_body=$(awk -v h="$section_heading" '
    $0 ~ "^### " h { grab = 1; next }
    grab && /^### / { exit }
    grab { print }
  ' "$CHARTER")
  open_rows=$(printf '%s\n' "$section_body" | awk -F'|' '
    NF >= 6 && $2 ~ /^ *[A-Za-z0-9._]+ *$/ {
      id = $2
      gsub(/^[ \t]+|[ \t]+$/, "", id)
      if (id == "ID" || id ~ /^-+$/) next
      # The line ends "... |", so splitting on "|" leaves a trailing empty
      # field: the real last column is $(NF-1), not $NF.
      status = $(NF - 1)
      gsub(/^[ \t]+|[ \t]+$/, "", status)
      if (status !~ /^Fixed/ && status !~ /^Closed/) {
        print id
      }
    }
  ')
  if [ -n "$open_rows" ]; then
    fail "defect list: $label rows are Fixed (open: $(printf '%s' "$open_rows" | tr '\n' ' ' | sed 's/[[:space:]]*$//'))"
  else
    pass "defect list: $label rows are Fixed"
  fi
}

defect_section_clear "12.00b.1" "12.00b.1 (I2)"
defect_section_clear "12.00b.2" "12.00b.2 (S1/S2 code fixes)"

if [ -r "$CHARTER" ]; then
  newp12_body=$(awk '
    /^### New in Phase 12/ { grab = 1; next }
    grab && /^### / { exit }
    grab { print }
  ' "$CHARTER")
  blocking=""
  # Each data row: | ID | Item | Sev | Found | Handling | Status |
  ids=$(printf '%s\n' "$newp12_body" | awk -F'|' 'NF >= 7 && $2 ~ /P12-/ { id=$2; gsub(/^[ \t]+|[ \t]+$/, "", id); print id }')
  for id in $ids; do
    row=$(printf '%s\n' "$newp12_body" | grep -F "| $id " | head -n1)
    sev=$(printf '%s' "$row" | awk -F'|' '{ s=$4; gsub(/[ \t*]/, "", s); print s }')
    status=$(printf '%s' "$row" | awk -F'|' '{ print $(NF - 1) }')
    case "$sev" in
      S1|S2) ;;
      *) continue ;;
    esac
    case "$status" in
      *Fixed*|*Closed*) continue ;;
    esac
    # Open S1/S2: blocks unless the charter's decision log records the
    # specific ruling this row cites (e.g. "R43" in its own Status/Handling
    # text) alongside this row's ID.
    ruling=$(printf '%s' "$row" | grep -o 'R[0-9][0-9]*' | head -n1)
    ruling_recorded=0
    if [ -n "$ruling" ] && grep -q "$id" "$CHARTER" 2>/dev/null; then
      if awk '/^## 9\. Decision log/{grab=1;next} grab && /^## /{exit} grab{print}' "$CHARTER" \
          | grep -q "$ruling"; then
        ruling_recorded=1
      fi
    fi
    if [ "$ruling_recorded" -eq 1 ]; then
      owner "defect list: $id (open $sev, ruling $ruling recorded — owner still authorizes stage entry)"
    else
      blocking="$blocking $id"
    fi
  done
  if [ -n "$blocking" ]; then
    fail "defect list: no open S1/S2 in 'New in Phase 12' without a recorded ruling (open:$blocking)"
  else
    pass "defect list: no open S1/S2 in 'New in Phase 12' without a recorded ruling"
  fi
else
  fail "defect list: no open S1/S2 in 'New in Phase 12' without a recorded ruling (charter doc missing)"
fi

# ---------------------------------------------------------------------------
# 5. Production build configuration decision (R59): Stage A and Stage C
#    uploads need this recorded in the release-readiness doc. Never add or
#    edit a build configuration here.
# ---------------------------------------------------------------------------

case "$STAGE" in
  A|C)
    if [ -r "$READINESS" ] && grep -q '^Production configuration decision:' "$READINESS"; then
      pass "production build configuration decision is recorded (R59)"
    else
      fail "production build configuration decision is recorded (R59) — owner must rule on a Production configuration or re-pointing Release; see docs/native-phase-12-release-readiness.md"
    fi
    ;;
esac

# ---------------------------------------------------------------------------
# 6. Evidence index: the previous stage has a recorded run (B, C, exit).
# ---------------------------------------------------------------------------

previous_stage_heading=
case "$STAGE" in
  B) previous_stage_heading="Stage A (12.04)" ;;
  C) previous_stage_heading="Stage B (12.05)" ;;
  exit) previous_stage_heading="Stage C (12.07)" ;;
esac

if [ -n "$previous_stage_heading" ]; then
  if [ -r "$EVIDENCE" ]; then
    body=$(awk -v h="### $previous_stage_heading" '
      $0 == h { grab = 1; next }
      grab && /^### / { exit }
      grab { print }
    ' "$EVIDENCE" | sed '/^[[:space:]]*$/d')
    if [ "$body" = "No run recorded yet." ]; then
      fail "evidence index: $previous_stage_heading has a recorded run (still \"No run recorded yet.\")"
    elif [ -z "$body" ]; then
      fail "evidence index: $previous_stage_heading has a recorded run (section not found)"
    else
      pass "evidence index: $previous_stage_heading has a recorded run"
    fi
  else
    fail "evidence index: $previous_stage_heading has a recorded run (evidence index missing)"
  fi
fi

# ---------------------------------------------------------------------------
# 7. Owner/account-gated items. Never counted as pass or fail.
# ---------------------------------------------------------------------------

owner "SIGN-1: Xcode account signed in and the signed Release build carries the App Group"
owner "VER-1: the live App Store version is confirmed and the native scheme is set above it"
owner "OI-2: the Sentry project tradeready-ios (org tradeready-3r) exists"

case "$STAGE" in
  A)
    owner "TF-INT: the internal TestFlight build is uploaded and processed"
    ;;
  rehearsal)
    owner "TF-INT: the rehearsal's native TestFlight builds (N, N2) are uploaded and processed"
    owner "EXPO-RB: the Expo rollback candidate R is uploaded and processed, not submitted"
    owner "staffing: the rehearsal's decision-log row is written before it starts"
    ;;
  B)
    owner "TF-INT: the external TestFlight build is uploaded and processed"
    owner "BAR: Beta App Review approved the external TestFlight build"
    owner "EXPO-RB: the Expo rollback candidate R stays processed and at hand throughout Stage B"
    ;;
  C)
    owner "TF-INT: the production release candidate is uploaded and processed"
    owner "OI-1: the App Store privacy labels are entered in App Store Connect"
    owner "EXPO-RB: the Expo rollback candidate R is processed and at hand"
    ;;
  exit)
    owner "OI-1: the App Store privacy labels match the entered declarations"
    owner "staffing: the cutover decision-log row confirms watch days and pauses"
    ;;
esac

printf '\n'
if [ "$failures" -gt 0 ]; then
  printf 'NOT READY for stage %s: %s local check failure(s).\n' "$STAGE" "$failures"
  exit 1
fi

echo "READY (offline checks only) for stage $STAGE: every local check passed; see the OWNER lines above for what only the owner can confirm."
