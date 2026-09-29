#!/bin/sh
set -u

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
PROJECT_PATH="$ROOT_DIR/native/TradeReadyNative.xcodeproj"
INFO_PLIST_PATH="$ROOT_DIR/native/Info.plist"
WORKER_CONFIG="$ROOT_DIR/backend-workers/wrangler.toml"
RN_SUPABASE_SOURCE="$ROOT_DIR/utils/supabase.ts"

DEVICE_LIST_FILE=
BUILD_SETTINGS_FILE=
UPDATED_AT_EVIDENCE=
PAYMENT_MERGE_EVIDENCE=
build_settings_available=1
worker_config_available=1

usage() {
  echo "Usage: $0 [--device-list FILE] [--build-settings FILE] [--worker-config FILE]"
  echo "          [--updated-at-verification FILE] [--payment-merge-verification FILE]"
  echo ""
  echo "Checks readiness for the Phase 4 background, photo, interruption, and"
  echo "React Native/Swift convergence matrix without printing URLs, credentials,"
  echo "device identifiers, or record values."
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --device-list)
      [ "$#" -ge 2 ] || { usage >&2; exit 64; }
      DEVICE_LIST_FILE=$2
      shift 2
      ;;
    --build-settings)
      [ "$#" -ge 2 ] || { usage >&2; exit 64; }
      BUILD_SETTINGS_FILE=$2
      shift 2
      ;;
    --worker-config)
      [ "$#" -ge 2 ] || { usage >&2; exit 64; }
      WORKER_CONFIG=$2
      shift 2
      ;;
    --updated-at-verification)
      [ "$#" -ge 2 ] || { usage >&2; exit 64; }
      UPDATED_AT_EVIDENCE=$2
      shift 2
      ;;
    --payment-merge-verification)
      [ "$#" -ge 2 ] || { usage >&2; exit 64; }
      PAYMENT_MERGE_EVIDENCE=$2
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

TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/tradeready-phase4-preflight.XXXXXX")
trap 'rm -rf "$TEMP_DIR"' EXIT HUP INT TERM

failures=0
blockers=0

pass() {
  printf 'PASS: %s\n' "$1"
}

fail() {
  failures=$((failures + 1))
  printf 'FAIL: %s\n' "$1"
}

block() {
  blockers=$((blockers + 1))
  printf 'BLOCKED: %s\n' "$1"
}

configured_value() {
  key=$1
  sed -n "s/^[[:space:]]*$key = //p" "$BUILD_SETTINGS_FILE" | tail -n 1
}

toml_value() {
  section=$1
  key=$2
  awk -v section="[$section]" -v key="$key" '
    $0 == section { active = 1; next }
    active && /^\[/ { exit }
    active && $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
      value = $0
      sub("^[[:space:]]*" key "[[:space:]]*=[[:space:]]*", "", value)
      gsub(/^\"|\"$/, "", value)
      print value
      exit
    }
  ' "$WORKER_CONFIG"
}

is_placeholder_https() {
  case "$1" in
    https://staging.invalid|https://*.invalid|https://localhost*|https://127.0.0.1*) return 0 ;;
    *) return 1 ;;
  esac
}

verify_sql_evidence() {
  path=$1
  label=$2
  if [ -z "$path" ]; then
    block "Record the production $label SQL verification output."
  elif [ ! -r "$path" ]; then
    fail "The supplied $label SQL verification output is unreadable."
  elif grep -F -q "ALL CHECKS PASSED" "$path" && ! grep -F -q "FAILED" "$path"; then
    pass "Recorded $label SQL verification against the production database."
  else
    fail "The supplied $label SQL verification did not pass cleanly."
  fi
}

if [ -z "$DEVICE_LIST_FILE" ]; then
  DEVICE_LIST_FILE="$TEMP_DIR/devices.json"
  if ! xcrun xcdevice list --timeout 5 >"$DEVICE_LIST_FILE" 2>/dev/null; then
    fail "Xcode could not enumerate devices."
  fi
elif [ ! -r "$DEVICE_LIST_FILE" ]; then
  fail "The supplied device inventory is unreadable."
fi

if [ -z "$BUILD_SETTINGS_FILE" ]; then
  BUILD_SETTINGS_FILE="$TEMP_DIR/release-build-settings.txt"
  if ! xcodebuild \
    -project "$PROJECT_PATH" \
    -scheme TradeReadyNative \
    -configuration Release \
    -sdk iphoneos \
    -showBuildSettings >"$BUILD_SETTINGS_FILE" 2>"$TEMP_DIR/xcodebuild.stderr"; then
    fail "Xcode could not resolve the Release build settings."
    build_settings_available=0
  fi
elif [ ! -r "$BUILD_SETTINGS_FILE" ]; then
  fail "The supplied Release build settings are unreadable."
  build_settings_available=0
fi

if [ ! -r "$WORKER_CONFIG" ]; then
  fail "The supplied Worker configuration is unreadable."
  worker_config_available=0
fi

physical_iphones=0
if [ -r "$DEVICE_LIST_FILE" ]; then
  physical_iphones=$(awk '
    BEGIN { RS = "},"; count = 0 }
    /"platform"[[:space:]]*:[[:space:]]*"com.apple.platform.iphoneos"/ &&
    /"simulator"[[:space:]]*:[[:space:]]*false/ &&
    /"available"[[:space:]]*:[[:space:]]*true/ { count += 1 }
    END { print count }
  ' "$DEVICE_LIST_FILE")
fi

if [ "$physical_iphones" -ge 1 ]; then
  pass "At least one available physical iPhone is connected."
else
  block "Connect and trust a physical iPhone; simulator and generic builds are not Phase 4 evidence."
fi

if [ "$physical_iphones" -ge 2 ]; then
  pass "Two physical iPhones are available for concurrent mixed-client evidence."
else
  block "A second physical iPhone is required for concurrent React Native/Swift evidence."
fi

release_supabase_url=
release_production_supabase_url=
release_supabase_key=
release_production_supabase_key=
if [ "$build_settings_available" -eq 1 ]; then
  environment=$(configured_value TRADEREADY_ENVIRONMENT)
  backend_url=$(configured_value TRADEREADY_BACKEND_URL)
  production_writes=$(configured_value TRADEREADY_ALLOW_PRODUCTION_WRITES)
  release_supabase_key=$(configured_value TRADEREADY_SUPABASE_PUBLISHABLE_KEY)
  release_production_supabase_key=$(configured_value TRADEREADY_PRODUCTION_SUPABASE_PUBLISHABLE_KEY)
  release_production_supabase_url=$(configured_value TRADEREADY_PRODUCTION_SUPABASE_URL)
  release_supabase_url=$(configured_value TRADEREADY_SUPABASE_URL)

  printf 'NOTE: R59 (no staging): Release writes to the production backend. Use disposable accounts for every device row.\n'
  if [ "$environment" = production ]; then
    pass "Release is the production configuration (R59: no staging environment exists)."
  else
    fail "Release must use the production configuration (R59: no staging environment exists)."
  fi

  case "$backend_url" in
    https://*)
      if is_placeholder_https "$backend_url"; then
        block "Configure the production HTTPS backend before Phase 4 device tests."
      else
        pass "Release has a non-placeholder HTTPS backend."
      fi
      ;;
    *) fail "Release requires a non-placeholder HTTPS backend." ;;
  esac

  if [ "$production_writes" = YES ]; then
    pass "Release enables production writes (R59)."
  else
    fail "Release must enable production writes under R59."
  fi

  case "$release_supabase_url" in
    https://*)
      if is_placeholder_https "$release_supabase_url"; then
        block "Configure the Release Supabase project before Phase 4 device tests."
      else
        pass "Release has a resolved HTTPS Supabase project."
      fi
      ;;
    *) fail "Release requires a resolved HTTPS Supabase project." ;;
  esac

  case "$release_production_supabase_url" in
    https://*) pass "Release has a resolved production Supabase guard origin." ;;
    *) fail "Release requires the production Supabase guard origin." ;;
  esac

  case "$release_supabase_key" in
    sb_publishable_?*) pass "Release has a resolved Supabase publishable key." ;;
    *) fail "Release requires a resolved Supabase publishable key." ;;
  esac

  case "$release_production_supabase_key" in
    sb_publishable_?*) pass "Release has a resolved production publishable-key guard." ;;
    *) fail "Release requires the production publishable-key guard." ;;
  esac

  if [ "$release_supabase_url" = "$release_production_supabase_url" ] &&
     [ "$release_supabase_key" = "$release_production_supabase_key" ]; then
    pass "Release Supabase project and key match the production guard (R59: no staging)."
  else
    fail "Release Supabase project and key must match the production guard under R59."
  fi

  rn_production_key=
  if [ -r "$RN_SUPABASE_SOURCE" ]; then
    rn_production_key=$(sed -n "s/^const SUPABASE_ANON_KEY = '\([^']*\)';$/\1/p" "$RN_SUPABASE_SOURCE" | head -n 1)
  fi
  if [ -n "$rn_production_key" ] &&
     [ "$release_production_supabase_key" = "$rn_production_key" ]; then
    pass "Release publishable-key guard matches the React Native production client."
  else
    fail "Release production publishable-key guard must match the React Native production client."
  fi
fi

worker_production_supabase=
if [ "$worker_config_available" -eq 1 ]; then
  worker_production_supabase=$(toml_value vars SUPABASE_URL)

  if [ "$build_settings_available" -eq 1 ]; then
    if [ -n "$worker_production_supabase" ] &&
       [ "$release_production_supabase_url" = "$worker_production_supabase" ]; then
      pass "Release runtime guard matches the Worker production Supabase project."
    else
      fail "Release production Supabase guard must match the Worker production project."
    fi
  fi
fi

if /usr/libexec/PlistBuddy -c 'Print :BGTaskSchedulerPermittedIdentifiers' "$INFO_PLIST_PATH" 2>/dev/null |
     grep -F -q 'com.gettradereadyapp.tradeready.sync-refresh' &&
   /usr/libexec/PlistBuddy -c 'Print :UIBackgroundModes' "$INFO_PLIST_PATH" 2>/dev/null |
     grep -F -q 'fetch'; then
  pass "Background refresh plist contracts are present."
else
  fail "Background refresh plist contracts are missing."
fi

if /usr/libexec/PlistBuddy -c 'Print :TradeReadyProductionSupabaseURL' "$INFO_PLIST_PATH" 2>/dev/null |
     grep -F -q '$(TRADEREADY_PRODUCTION_SUPABASE_URL)' &&
   /usr/libexec/PlistBuddy -c 'Print :TradeReadyProductionSupabasePublishableKey' "$INFO_PLIST_PATH" 2>/dev/null |
     grep -F -q '$(TRADEREADY_PRODUCTION_SUPABASE_PUBLISHABLE_KEY)'; then
  pass "The runtime Supabase production-origin and publishable-key guards are wired through Info.plist."
else
  fail "A runtime Supabase production guard is missing from Info.plist."
fi

if [ -f "$ROOT_DIR/native/TradeReadyNative/NativeBackgroundRefresh.swift" ] &&
   [ -f "$ROOT_DIR/native/TradeReadyNative/NativeJobPhotoTransfer.swift" ] &&
   grep -F -q "app.all('/api/photos/:photoId', photosHandler);" "$ROOT_DIR/backend-workers/src/index.js"; then
  pass "Native background/photo sources and the authenticated photo route are present."
else
  fail "A Phase 4 background/photo source or route is missing."
fi

if grep -F -q 'create trigger set_updated_at_trg' "$ROOT_DIR/supabase/migrations/20260831_updated_at_server_authority.sql" &&
   grep -F -q 'create trigger merge_invoice_payments_trg' "$ROOT_DIR/supabase/migrations/20260718_invoice_payment_merge.sql"; then
  pass "Required database-clock and invoice-ledger migrations are checked in."
else
  fail "A required Phase 4 database migration is missing."
fi

verify_sql_evidence "$UPDATED_AT_EVIDENCE" "database-clock"
verify_sql_evidence "$PAYMENT_MERGE_EVIDENCE" "invoice-ledger"

printf '\n'
if [ "$failures" -gt 0 ]; then
  printf 'NOT READY: %s configuration failure(s), %s external blocker(s).\n' "$failures" "$blockers"
  exit 1
fi

if [ "$blockers" -gt 0 ]; then
  printf 'BLOCKED: configuration contracts pass, but %s external prerequisite(s) remain.\n' "$blockers"
  exit 2
fi

echo "READY: run docs/native-phase-4-device-runsheet.md with disposable production accounts (R59: no staging)."
