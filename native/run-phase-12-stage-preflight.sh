#!/bin/sh
# Phase 12 — offline, fail-closed readiness check for an owner-run stage.
#
# Usage: run-phase-12-stage-preflight.sh --stage A|rehearsal|B|C|exit
#            [--docs-dir DIR] [--build-settings FILE] [--rn-app-json FILE]
#
# Checks only what this repository can prove without a network call, an
# App Store Connect/TestFlight session or a signed build. It never fixes a
# placeholder or production-matched value, and it prints no URL, credential,
# device identifier or record value: no production host or team ID is ever
# written into this script's source — the production backend origin is read
# at run time from the RN app config (app.json's extra.backendUrl), and the
# production Supabase origin/key are read at run time from the build
# settings' own TRADEREADY_PRODUCTION_SUPABASE_URL/
# TRADEREADY_PRODUCTION_SUPABASE_PUBLISHABLE_KEY guard constants (the same
# values native/run-phase-4-device-preflight.sh already reads).
#
# Every line is exactly one of:
#   PASS: <check>
#   FAIL: <check>
#   OWNER <check> — not checkable offline
# Exit status is non-zero if any local check fails (OWNER lines never count
# as a failure, and never count as a pass either).
#
# Fail-closed rules this script follows throughout:
#   - a required doc, section or config value that cannot be found or read
#     is a FAIL, never a silent pass;
#   - a defect-list row's Status must start with "Fixed" or "Closed" to
#     count as closed (a substring match like "*Fixed*" would also match
#     "Open — not yet Fixed", so every status compare is anchored);
#   - a defect-list row's severity is the MOST severe S1/S2/S3 token in its
#     Sev cell, so an annotated cell ("S2 (was S3)", "S3 (was S2)") never
#     reads as less severe than it might be;
#   - an open S1/S2 defect only stops blocking when the charter's decision
#     log (CH §9) has a row whose Decider cell is exactly "owner" and whose
#     Decision cell is exactly "<id> ruled: R<n>" for the ruling that
#     defect row cites (strict: any other wording is not a ruling). A later
#     §9 row that names the defect and says "revoked", in any wording and
#     from any Decider, re-blocks it (lenient: a near-miss revocation still
#     revokes);
#   - a previous stage's run record counts as unfilled while it still holds
#     any placeholder token of that stage's evidence template in the stage
#     runbook (read from the template itself, so a real "<"/">" comparison
#     in a record is not mistaken for one);
#   - a production-match comparison is by origin (scheme, host, port,
#     case-insensitive, trailing slash ignored), not exact string equality.
set -u

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
DOCS_DIR="$ROOT_DIR/docs"
BUILD_SETTINGS_FILE=
RN_APP_JSON="$ROOT_DIR/app.json"
STAGE=

usage() {
  echo "Usage: $0 --stage A|rehearsal|B|C|exit [--docs-dir DIR] [--build-settings FILE] [--rn-app-json FILE]"
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
    --rn-app-json)
      [ "$#" -ge 2 ] || { usage >&2; exit 64; }
      RN_APP_JSON=$2
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
RUNBOOK="$DOCS_DIR/native-phase-12-stage-runbook.md"

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

trim() {
  printf '%s' "$1" | sed 's/^[ \t]*//;s/[ \t]*$//'
}

# An awk function, prepended to the awk programs that need it: names(s, t) is
# 1 if s contains t, case-insensitively, with no letter or digit touching
# either end -- so "P12-012" is not named by "P12-0120", nor "R59" by "R590".
AWK_NAMES='
  function names(s, t,    ls, lt, off, pos, before, after) {
    ls = tolower(s)
    lt = tolower(t)
    off = 0
    while ((pos = index(substr(ls, off + 1), lt)) > 0) {
      pos += off
      before = (pos > 1) ? substr(ls, pos - 1, 1) : ""
      after = substr(ls, pos + length(lt), 1)
      if (before !~ /[a-z0-9]/ && after !~ /[a-z0-9]/) return 1
      off = pos
    }
    return 0
  }
'

# ---------------------------------------------------------------------------
# 1. Staging / production-match config. Reuses the phase-3/4 preflight's
#    placeholder pattern, then adds an origin-based production-match check
#    (scheme+host+port, case-insensitive, trailing slash ignored) that
#    neither phase-3 nor phase-4 makes, for both the backend and the
#    Supabase project, plus the Supabase publishable key.
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

# scheme://host:port, lowercased, trailing slash and a default port ignored.
# Not a full URL parser: inputs here are already validated as "https://..."
# or "http://..." by the placeholder check that runs first.
normalize_origin() {
  url=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  case "$url" in
    */) url=${url%/} ;;
  esac
  scheme=${url%%://*}
  rest=${url#*://}
  hostport=${rest%%/*}
  host=${hostport%%:*}
  case "$hostport" in
    *:*) port=${hostport#*:} ;;
    *) port= ;;
  esac
  if [ -z "$port" ]; then
    case "$scheme" in
      https) port=443 ;;
      http) port=80 ;;
    esac
  fi
  printf '%s://%s:%s' "$scheme" "$host" "$port"
}

origins_match() {
  [ -n "$1" ] && [ -n "$2" ] && [ "$(normalize_origin "$1")" = "$(normalize_origin "$2")" ]
}

rn_production_backend_url() {
  [ -r "$RN_APP_JSON" ] || return 1
  sed -n 's/.*"backendUrl"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$RN_APP_JSON" | head -n1
}

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
  supabase_key=$(configured_value TRADEREADY_SUPABASE_PUBLISHABLE_KEY)
  production_supabase_url=$(configured_value TRADEREADY_PRODUCTION_SUPABASE_URL)
  production_supabase_key=$(configured_value TRADEREADY_PRODUCTION_SUPABASE_PUBLISHABLE_KEY)
  production_writes=$(configured_value TRADEREADY_ALLOW_PRODUCTION_WRITES)
  production_backend_url=$(rn_production_backend_url)

  if is_placeholder_https "$backend_url"; then
    fail "backend URL is not the placeholder (staging.invalid/local host)"
  else
    case "$backend_url" in
      https://*) pass "backend URL is not the placeholder (staging.invalid/local host)" ;;
      *) fail "backend URL is not the placeholder (staging.invalid/local host)" ;;
    esac
  fi

  if [ -z "$production_backend_url" ]; then
    fail "backend URL does not match the production project (could not read app.json's backendUrl)"
  elif [ "$environment" != production ] && origins_match "$backend_url" "$production_backend_url"; then
    fail "backend URL matches the production project (app.json) outside a production build"
  else
    pass "backend URL does not match the production project outside a production build"
  fi

  if is_placeholder_https "$supabase_url"; then
    fail "Supabase URL is not the placeholder (staging.invalid/local host)"
  else
    case "$supabase_url" in
      https://*) pass "Supabase URL is not the placeholder (staging.invalid/local host)" ;;
      *) fail "Supabase URL is not the placeholder (staging.invalid/local host)" ;;
    esac
  fi

  if [ -z "$production_supabase_url" ]; then
    fail "Supabase URL does not match the production project (the build's own TRADEREADY_PRODUCTION_SUPABASE_URL guard is unresolved)"
  elif [ "$environment" != production ] && origins_match "$supabase_url" "$production_supabase_url"; then
    fail "Supabase URL matches the production project outside a production build"
  else
    pass "Supabase URL does not match the production project outside a production build"
  fi

  if [ -z "$production_supabase_key" ]; then
    fail "Supabase publishable key does not match the production key (the build's own TRADEREADY_PRODUCTION_SUPABASE_PUBLISHABLE_KEY guard is unresolved)"
  elif [ "$environment" != production ] && [ -n "$supabase_key" ] && [ "$supabase_key" = "$production_supabase_key" ]; then
    fail "Supabase publishable key matches the production key outside a production build"
  else
    pass "Supabase publishable key does not match the production key outside a production build"
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
# 3. Charter is owner-approved. The Status line must affirmatively say so:
#    absence of "DRAFT" is not enough (a line like "Status: proposed" must
#    still fail), and "not owner-approved" must fail even without "DRAFT".
# ---------------------------------------------------------------------------

if [ -r "$CHARTER" ]; then
  status_line=$(grep -m1 '^\*\*Status:' "$CHARTER" || true)
  if [ -z "$status_line" ]; then
    fail "charter is owner-approved (no Status line found)"
  else
    # Case-insensitive: the owner's eventual wording capitalization is not
    # fixed, but DRAFT / not-owner-approved / owner-approved must be matched
    # regardless of case.
    status_lower=$(printf '%s' "$status_line" | tr '[:upper:]' '[:lower:]')
    case "$status_lower" in
      *draft*) fail "charter is owner-approved (Status line reads: $(printf '%s' "$status_line" | cut -c1-80))" ;;
      *"not owner-approved"*) fail "charter is owner-approved (Status line reads: $(printf '%s' "$status_line" | cut -c1-80))" ;;
      *"owner-approved"*) pass "charter is owner-approved" ;;
      *) fail "charter is owner-approved (Status line does not say owner-approved: $(printf '%s' "$status_line" | cut -c1-80))" ;;
    esac
  fi
else
  fail "charter is owner-approved (charter doc missing)"
fi

# ---------------------------------------------------------------------------
# 4. Defect list: no open S1/S2 row anywhere in CH §10 (charter §2 rule 2
#    covers the whole defect list, not just named sections), excluding the
#    Pointers subsection (routed to 12.03, a different 5-column schema with
#    no Status column). An open S1/S2 blocks unless the charter's decision
#    log (§9) holds an exact owner ruling for the ruling that row cites, and
#    no later §9 row revokes it (see ruling_is_recorded below).
# ---------------------------------------------------------------------------

ruling_is_recorded() {
  # Rulings are strict (ruling R65: stop chasing phrasings). A §9 row counts
  # as an owner ruling for defect $1 only when ALL of: it is a real table row
  # (9 fields after the "|" split, starting with "|"); its Decider cell,
  # trimmed and lower-cased, is exactly "owner"; and its Decision cell,
  # trimmed, is EXACTLY "<id> ruled: R<n>" -- nothing before or after (the
  # rationale goes in another cell). No word-list of negations, qualifiers or
  # synonyms is matched or maintained: anything that is not this exact string
  # is not a ruling.
  #
  # Revocation is lenient and fails closed (ruling R67). Any other §9 table
  # line (any line holding a "|", whatever its column count or Decider) that
  # names the defect ID (case-insensitive, not as part of a longer ID) and
  # contains "revoked" in any letter case re-blocks the defect, whatever else
  # it says and whichever ruling it mentions -- so "revoked: R43 (draft)", a
  # revoke with its reason inline, "Revoked:" and a non-owner's revoke all
  # count. Rows are read in file order (the log is append-only, newest last),
  # so the LAST ruling-or-revoking row wins: a later exact owner ruling after
  # a revoke clears the defect again, even if its Evidence cell mentions the
  # revocation.
  id=$1
  ruling=$2
  [ -n "$ruling" ] || return 1
  [ -r "$CHARTER" ] || return 1
  awk '/^## 9\. Decision log/{grab=1;next} grab && /^## /{exit} grab{print}' "$CHARTER" \
    | awk -F'|' -v id="$id" -v ruling="$ruling" "$AWK_NAMES"'
        $0 !~ /\|/ { next }
        {
          exact = 0
          if (NF == 9 && $0 ~ /^\|/) {
            decider = $(NF - 2)
            gsub(/^[ \t]+|[ \t]+$/, "", decider)
            decision = $5
            gsub(/^[ \t]+|[ \t]+$/, "", decision)
            if (tolower(decider) == "owner" && decision == id " ruled: " ruling) exact = 1
          }
          if (exact) verdict = "ruled"
          else if (index(tolower($0), "revoked") && names($0, id)) verdict = "revoked"
        }
        END { if (verdict == "ruled") print "MATCH" }
      ' \
    | grep -q MATCH
}

if [ ! -r "$CHARTER" ]; then
  fail "defect list: no open S1/S2 blocks stage entry (charter doc missing)"
else
  defect_list_body=$(awk '/^## 10\. Defect list/{grab=1;next} grab{print}' "$CHARTER")
  if [ -z "$defect_list_body" ]; then
    fail "defect list: no open S1/S2 blocks stage entry (§10 Defect list heading not found)"
  else
    # Exclude the Pointers subsection: it routes S3 rows to 12.03 device rows
    # and has no Status column (ID|Item|Sev|State|12.03 row -- 5 columns, so
    # NF==7 after the "|" split below, vs NF==8 for a 6-column defect row;
    # this heading skip also protects against ever mis-scanning it if that
    # NF difference alone were relied on).
    scan_body=$(printf '%s\n' "$defect_list_body" | awk '
      /^### Pointers/ { skip = 1; next }
      skip && /^### / { skip = 0 }
      !skip { print }
    ')
    rows_file="$TEMP_DIR/defect-rows.txt"
    malformed_file="$TEMP_DIR/defect-malformed.txt"
    ruled_file="$TEMP_DIR/defect-ruled.txt"
    : >"$ruled_file"
    printf '%s\n' "$scan_body" | awk -F'|' 'NF==8{print}' >"$rows_file"
    # A line that contains a "|" (so it looks like it belongs to a table) but
    # does not split into the expected 8 fields -- an extra "|" inside a
    # cell, a missing leading "|", or any other malformed column count -- is
    # otherwise silently dropped by the NF==8 filter above. A fail-closed
    # scanner cannot assume that is safe: if the line names S1 or S2 anywhere
    # (case-insensitive, whole word), it is flagged instead of skipped
    # (Minor 6, fix rounds 2-3). Unlike round 2, this no longer requires the
    # line to start with "|", so a row missing its leading pipe is caught too.
    printf '%s\n' "$scan_body" | awk -F'|' '$0 ~ /\|/ && NF != 8 {print}' \
      | grep -iE '\bS[12]\b' >"$malformed_file" || :

    # Effective severity of a raw cell: the MOST severe whole-word S1/S2/S3
    # token in it, case-insensitive (fix round 4, ruling R67). An annotation
    # can run either way -- "S2 (was S3)" and "(was S3) S2" both mean S2 now,
    # "S3 (was S2)" may mean a downgrade -- and a scanner cannot tell which
    # token is current, so it takes the most severe one and fails closed:
    # "S2 (was S3)" is S2, "S3 (was S2)" is S2 (over-blocks safely),
    # "~~S1~~ S2" is S1, "S3 -> S2" is S2, lower-case "s1" is S1. Round 3's
    # last-token rule read "S2 (was S3)" as S3 and silently passed it. A cell
    # with no such token at all is not S1/S2 (skip, as for a plain "S3" or an
    # empty cell) unless the row's raw text otherwise mentions S1 or S2, in
    # which case it cannot be safely dismissed either and is flagged as
    # ambiguous.
    effective_severity() {
      printf '%s' "$1" | grep -oiE '\bS[123]\b' | tr '[:lower:]' '[:upper:]' | sort | head -n1
    }

    row_count=0
    blocking=""
    while IFS= read -r row; do
      [ -n "$row" ] || continue
      id=$(trim "$(printf '%s' "$row" | awk -F'|' '{print $2}')")
      case "$id" in
        ""|ID) continue ;;
      esac
      case "$id" in
        -*) continue ;;
      esac
      # A row whose ID cannot be parsed cleanly (e.g. "P12-009 (= `12.02-F4`)")
      # is skipped -- unless its raw text names S1 or S2, in which case it is
      # flagged rather than silently dropped (Minor 6, fix rounds 2-3): this
      # scanner never assumes an unparseable row is safe.
      case "$id" in
        *[!A-Za-z0-9._-]*)
          if printf '%s' "$row" | grep -qiE '\bS[12]\b'; then
            blocking="$blocking [unparseable id: $id]"
          fi
          continue
          ;;
      esac
      row_count=$((row_count + 1))
      raw_sev=$(printf '%s' "$row" | awk -F'|' '{print $4}')
      sev=$(effective_severity "$raw_sev")
      status=$(trim "$(printf '%s' "$row" | awk -F'|' '{print $(NF-1)}')")
      if [ -z "$sev" ]; then
        # No clean S1/S2/S3 token anywhere in the cell. Not S1/S2-flavored
        # (skip) unless the row's raw text otherwise mentions S1 or S2, in
        # which case this cannot be safely dismissed either.
        if printf '%s' "$row" | grep -qiE '\bS[12]\b'; then
          blocking="$blocking [$id: ambiguous severity cell '$(trim "$raw_sev")']"
        fi
        continue
      fi
      case "$sev" in
        S1|S2) ;;
        *) continue ;;
      esac
      case "$status" in
        Fixed*|Closed*) continue ;;
      esac
      ruling=$(printf '%s' "$row" | grep -oE '\bR[0-9]+\b' | head -n1)
      if [ -n "$ruling" ] && ruling_is_recorded "$id" "$ruling"; then
        printf '%s %s %s\n' "$id" "$sev" "$ruling" >>"$ruled_file"
      else
        blocking="$blocking $id"
      fi
    done <"$rows_file"

    if [ -s "$malformed_file" ]; then
      while IFS= read -r bad_row; do
        snippet=$(printf '%s' "$bad_row" | cut -c1-72)
        blocking="$blocking [unparseable row (wrong column count): $snippet]"
      done <"$malformed_file"
    fi

    if [ "$row_count" -eq 0 ] && [ -z "$blocking" ]; then
      fail "defect list: no open S1/S2 blocks stage entry (no data rows parsed under §10 — check the charter's table format)"
    elif [ -n "$blocking" ]; then
      fail "defect list: no open S1/S2 blocks stage entry (open, no recorded ruling:$blocking)"
    else
      pass "defect list: no open S1/S2 blocks stage entry"
    fi
    if [ -s "$ruled_file" ]; then
      while read -r note_id note_sev note_ruling; do
        owner "defect list: $note_id (open $note_sev, ruling $note_ruling recorded — owner still authorizes stage entry)"
      done <"$ruled_file"
    fi
  fi
fi

# ---------------------------------------------------------------------------
# 5. Production build configuration decision (R59): Stage A and Stage C
#    uploads need this recorded in the release-readiness doc, as an actual
#    filled-in ruling line, not merely a line that mentions the topic (a
#    line ending "...: pending" must still fail) and not the runbook's own
#    unfilled template line (fix round 3: strict grammar, ruling R65). The
#    line must read exactly "Production configuration decision: <non-empty
#    text> ruled: R<n>", with "ruled: R<n>" the literal end of the line --
#    nothing after it.
#    - Placeholders: any such line that still holds a "<...>" placeholder
#      fails (the runbook's template is "<what was decided>"; a partial
#      "upload <build>" fails too). A placeholder has no space just inside
#      its brackets, so a spaced comparison ("p95 < 800 ms > baseline") in a
#      real decision is not mistaken for one (fix round 4).
#    - Revocation, as for a §9 ruling (fix round 4, ruling R67): lines are
#      read in file order and the last decision-or-revoking line wins. A
#      line that contains "revoked" (any case) and names the decision
#      ("Production configuration decision", any case), R59, or the ruling
#      the decision line cites, re-blocks the decision in any wording; a
#      later exact decision line clears it again.
#    Never add or edit a build configuration here.
# ---------------------------------------------------------------------------

case "$STAGE" in
  A|C)
    r59_state=none
    if [ -r "$READINESS" ]; then
      r59_state=$(awk "$AWK_NAMES"'
        /^Production configuration decision: .+ ruled: R[0-9]+$/ {
          if ($0 ~ /<[^<>[:space:]]([^<>]*[^<>[:space:]])?>/) placeholder = 1
          cited = $0
          sub(/.* ruled: /, "", cited)
          state = "ruled"
          next
        }
        # A revoking line only matters once a decision line has been seen:
        # with no decision at all, the plain "owner must rule" FAIL applies.
        state != "" {
          line = tolower($0)
          if (index(line, "revoked") && (index(line, "production configuration decision") || names($0, "R59") || names($0, cited)))
            state = "revoked"
        }
        END {
          if (placeholder) print "placeholder"
          else if (state == "") print "none"
          else print state
        }
      ' "$READINESS")
    fi
    case "$r59_state" in
      ruled)
        pass "production build configuration decision is recorded (R59)"
        ;;
      placeholder)
        fail "production build configuration decision is recorded (R59) — the decision line still holds a <...> placeholder from the stage runbook's R59 template (runbook §2.2 step 11); write the real decision"
        ;;
      revoked)
        fail "production build configuration decision is recorded (R59) — a later line in the release-readiness doc revokes it; record a new decision line after it"
        ;;
      *)
        fail "production build configuration decision is recorded (R59) — owner must rule on a Production configuration or re-pointing Release; see docs/native-phase-12-release-readiness.md"
        ;;
    esac
    ;;
esac

# ---------------------------------------------------------------------------
# 6. Evidence index: the previous stage has a recorded run (rehearsal, B, C,
#    exit) -- not "No run recorded yet." and not still holding a placeholder
#    of that stage's evidence template in the stage runbook -- and Stage B
#    additionally needs the 12.06 rehearsal itself recorded (CH §4.4
#    bullet 3), not only Stage A's run.
# ---------------------------------------------------------------------------

previous_stage_heading=
case "$STAGE" in
  rehearsal) previous_stage_heading="Stage A (12.04)" ;;
  B) previous_stage_heading="Stage A (12.04)" ;;
  C) previous_stage_heading="Stage B (12.05)" ;;
  exit) previous_stage_heading="Stage C (12.07)" ;;
esac

# The placeholder tokens of the stage runbook's evidence template for the
# EI §24 section named $1 (the template under the runbook's "### ... Evidence
# template ... "### <section>"" heading): every "<...>" token in the
# template's fenced block, plus the opening part of a token the template
# wraps onto a second line. Read from the template itself (fix round 4), so
# only the template's own placeholders mark an unfilled record, never a real
# "<"/">" comparison. Prints nothing if the template cannot be found.
template_placeholders() {
  [ -r "$RUNBOOK" ] || return 0
  awk -v h="\"### $1\"" '
    !found && /^### / && index($0, "Evidence template") && index($0, h) { found = 1; next }
    found && !fenced && /^#/ { exit }
    found && !fenced && /^```/ { fenced = 1; next }
    fenced && /^```/ { exit }
    fenced { print }
  ' "$RUNBOOK" | grep -oE '<[^<>]+>|<[^<>]+$' | sort -u
}

if [ -n "$previous_stage_heading" ]; then
  if [ -r "$EVIDENCE" ]; then
    body=$(awk -v h="### $previous_stage_heading" '
      $0 == h { grab = 1; next }
      grab && /^### / { exit }
      grab { print }
    ' "$EVIDENCE" | sed '/^[[:space:]]*$/d')
    placeholders=$(template_placeholders "$previous_stage_heading")
    leftover=
    if [ -n "$placeholders" ]; then
      leftover=$(printf '%s\n' "$placeholders" | while IFS= read -r token; do
        if printf '%s\n' "$body" | grep -qF -- "$token"; then
          printf '%s' "$token"
          break
        fi
      done)
    fi
    if [ -z "$body" ]; then
      fail "evidence index: $previous_stage_heading has a recorded run (section not found)"
    elif printf '%s\n' "$body" | grep -qF "No run recorded yet."; then
      fail "evidence index: $previous_stage_heading has a recorded run (still says \"No run recorded yet.\")"
    elif [ -z "$placeholders" ]; then
      # Fail closed: without the template, its placeholders cannot be ruled
      # out, so an unfilled template could pass as a record.
      fail "evidence index: $previous_stage_heading has a recorded run (cannot read the stage runbook's \"### $previous_stage_heading\" evidence template, so its placeholders cannot be ruled out)"
    elif [ -n "$leftover" ]; then
      # The template's own placeholders (Run <N>, Build: <NATIVE_VERSION>, ...)
      # are still present verbatim: an unfilled or half-filled template, not a
      # real run record (fix rounds 2 and 4).
      fail "evidence index: $previous_stage_heading has a recorded run (still holds a placeholder from the stage runbook's \"### $previous_stage_heading\" evidence template: $leftover)"
    else
      pass "evidence index: $previous_stage_heading has a recorded run"
    fi
  else
    fail "evidence index: $previous_stage_heading has a recorded run (evidence index missing)"
  fi
fi

evidence_row_recorded() {
  id=$1
  [ -r "$EVIDENCE" ] || return 1
  row=$(grep -F -- "| $id |" "$EVIDENCE" | head -n1)
  [ -n "$row" ] || return 1
  last=$(trim "$(printf '%s' "$row" | awk -F'|' '{print $(NF-1)}')")
  [ "$last" != "[ ]" ]
}

if [ "$STAGE" = B ]; then
  if [ ! -r "$EVIDENCE" ]; then
    fail "evidence index: the 12.06 rehearsal is recorded (evidence index missing)"
  elif evidence_row_recorded "P12-RB-2" && evidence_row_recorded "P12-RB-3"; then
    pass "evidence index: the 12.06 rehearsal is recorded (P12-RB-2, P12-RB-3)"
  else
    fail "evidence index: the 12.06 rehearsal is recorded (P12-RB-2 and/or P12-RB-3 evidence still \"[ ]\")"
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
    owner "OI-1: the App Store privacy-label edit is approved (decision recorded; labels entered at Stage C)"
    owner "RESEND: the production Worker's RESEND_API_KEY secret is confirmed present (wrangler secret list; G1 waiver condition)"
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
