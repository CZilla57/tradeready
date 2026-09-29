#!/bin/sh
set -u

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
PROJECT_PATH="$ROOT_DIR/native/TradeReadyNative.xcodeproj"
ENTITLEMENTS_PATH="$ROOT_DIR/native/TradeReadyNative/TradeReadyNative.entitlements"
INFO_PLIST_PATH="$ROOT_DIR/native/Info.plist"
PROJECT_FILE_PATH="$PROJECT_PATH/project.pbxproj"
WORKER_CONFIG="$ROOT_DIR/backend-workers/wrangler.toml"
RN_SUPABASE_SOURCE="$ROOT_DIR/utils/supabase.ts"
RN_APP_CONFIG="$ROOT_DIR/app.json"

DEVICE_LIST_FILE=
BUILD_SETTINGS_FILE=
build_settings_available=1

usage() {
  echo "Usage: $0 [--device-list FILE] [--build-settings FILE]"
  echo ""
  echo "Checks whether the checked-in Release build is ready for the manual Phase 3"
  echo "authentication, onboarding, subscription, and deletion matrix. Values are"
  echo "classified without printing client configuration or device identifiers."
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

TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/tradeready-phase3-preflight.XXXXXX")
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

is_missing_or_unresolved() {
  value=$1
  case "$value" in
    ""|'$('*) return 0 ;;
    *) return 1 ;;
  esac
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

if [ -r "$DEVICE_LIST_FILE" ] && awk '
  BEGIN { RS = "}," }
  /"platform"[[:space:]]*:[[:space:]]*"com.apple.platform.iphoneos"/ &&
  /"simulator"[[:space:]]*:[[:space:]]*false/ &&
  /"available"[[:space:]]*:[[:space:]]*true/ { found = 1 }
  END { exit(found ? 0 : 1) }
' "$DEVICE_LIST_FILE"; then
  pass "An available physical iPhone is connected."
else
  block "Connect and trust a physical iPhone; simulator and generic-device builds are not Phase 3 evidence."
fi

if [ "$build_settings_available" -eq 1 ]; then
  environment=$(configured_value TRADEREADY_ENVIRONMENT)
  backend_url=$(configured_value TRADEREADY_BACKEND_URL)
  production_writes=$(configured_value TRADEREADY_ALLOW_PRODUCTION_WRITES)
  bundle_id=$(configured_value PRODUCT_BUNDLE_IDENTIFIER)
  development_team=$(configured_value DEVELOPMENT_TEAM)
  reset_url=$(configured_value TRADEREADY_PASSWORD_RESET_URL)
  confirmation_url=$(configured_value TRADEREADY_EMAIL_CONFIRMATION_URL)
  supabase_url=$(configured_value TRADEREADY_SUPABASE_URL)
  supabase_key=$(configured_value TRADEREADY_SUPABASE_PUBLISHABLE_KEY)
  production_supabase_url=$(configured_value TRADEREADY_PRODUCTION_SUPABASE_URL)
  production_supabase_key=$(configured_value TRADEREADY_PRODUCTION_SUPABASE_PUBLISHABLE_KEY)
  rn_backend_url=$(sed -n 's/.*"backendUrl"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$RN_APP_CONFIG" 2>/dev/null | head -n 1)
  google_ios_client_id=$(configured_value TRADEREADY_GOOGLE_IOS_CLIENT_ID)
  google_server_client_id=$(configured_value TRADEREADY_GOOGLE_SERVER_CLIENT_ID)
  revenuecat_key=$(configured_value TRADEREADY_REVENUECAT_API_KEY)
  revenuecat_entitlement=$(configured_value TRADEREADY_REVENUECAT_ENTITLEMENT_ID)

  printf 'NOTE: R59 (no staging): Release writes to the production backend. Use disposable accounts for every device row.\n'
  if [ "$environment" = production ]; then
    pass "Release is the production configuration (R59: no staging environment exists)."
  else
    fail "Release must use the production configuration (R59: no staging environment exists)."
  fi

  case "$backend_url" in
    https://staging.invalid|*://*.invalid|*://localhost*|*://127.0.0.1*)
      block "Configure the production HTTPS backend before exercising account deletion."
      ;;
    https://*)
      if [ -n "$rn_backend_url" ] && [ "$backend_url" = "$rn_backend_url" ]; then
        pass "Release targets the production Worker (the origin the React Native app ships against)."
      else
        fail "Release backend must be the production Worker origin from app.json under R59."
      fi
      ;;
    *)
      fail "Release requires a non-placeholder HTTPS backend."
      ;;
  esac

  if [ "$production_writes" = YES ]; then
    pass "Release enables production writes (R59)."
  else
    fail "Release must enable production writes under R59."
  fi

  if [ "$bundle_id" = com.gettradereadyapp.tradeready ]; then
    pass "The native app retains the production bundle identifier."
  else
    fail "The bundle identifier no longer matches the upgrade target."
  fi

  if is_missing_or_unresolved "$development_team"; then
    fail "Release has no resolved signing team."
  else
    pass "Release has a resolved signing team."
  fi

  if [ "$reset_url" = tradeready://reset-password ]; then
    pass "The password-recovery callback matches the native route."
  else
    fail "The password-recovery callback must be tradeready://reset-password."
  fi

  case "$confirmation_url" in
    https://*) pass "Email confirmation uses an HTTPS redirect." ;;
    *) fail "Email confirmation requires an HTTPS redirect." ;;
  esac

  case "$supabase_url" in
    https://*.invalid|https://localhost*|https://127.0.0.1*) fail "Supabase requires a resolved HTTPS project URL." ;;
    https://*) pass "Supabase uses a resolved HTTPS project URL." ;;
    *) fail "Supabase requires a resolved HTTPS project URL." ;;
  esac

  if is_missing_or_unresolved "$supabase_key"; then
    fail "The Supabase publishable key is unresolved."
  else
    pass "The Supabase publishable key is resolved."
  fi

  # R59: Release is production, so the project and key must be THE production
  # ones: equal to the runtime guard, the Worker's production project, and the
  # React Native production client's key.
  rn_production_key=
  if [ -r "$RN_SUPABASE_SOURCE" ]; then
    rn_production_key=$(sed -n "s/^const SUPABASE_ANON_KEY = '\([^']*\)';$/\1/p" "$RN_SUPABASE_SOURCE" | head -n 1)
  fi
  worker_production_supabase=
  [ -r "$WORKER_CONFIG" ] && worker_production_supabase=$(toml_value vars SUPABASE_URL)
  if [ -n "$production_supabase_url" ] && [ -n "$production_supabase_key" ] &&
     [ "$supabase_url" = "$production_supabase_url" ] &&
     [ "$supabase_key" = "$production_supabase_key" ] &&
     [ "$production_supabase_url" = "$worker_production_supabase" ] &&
     [ -n "$rn_production_key" ] && [ "$production_supabase_key" = "$rn_production_key" ]; then
    pass "Release Supabase project and key are the production project (R59)."
  else
    fail "Release Supabase project and key must be the production project under R59."
  fi

  if is_missing_or_unresolved "$google_ios_client_id" || is_missing_or_unresolved "$google_server_client_id"; then
    fail "Both Google OAuth client identifiers must resolve."
  else
    pass "Both Google OAuth client identifiers resolve."
  fi

  google_client_prefix=${google_ios_client_id%.apps.googleusercontent.com}
  expected_google_scheme="com.googleusercontent.apps.$google_client_prefix"
  if [ "$google_client_prefix" != "$google_ios_client_id" ] &&
     grep -q "<string>$expected_google_scheme</string>" "$INFO_PLIST_PATH"; then
    pass "The Google callback scheme matches the resolved iOS client identifier."
  else
    fail "The Google callback scheme does not match the resolved iOS client identifier."
  fi

  if is_missing_or_unresolved "$revenuecat_key" || is_missing_or_unresolved "$revenuecat_entitlement"; then
    fail "RevenueCat client configuration is unresolved."
  else
    pass "RevenueCat client configuration resolves."
  fi
fi

if [ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.developer.applesignin:0' "$ENTITLEMENTS_PATH" 2>/dev/null || true)" = Default ]; then
  pass "Sign in with Apple entitlement is present."
else
  fail "Sign in with Apple entitlement is missing."
fi

if grep -A2 -q 'com.apple.InAppPurchase = {' "$PROJECT_FILE_PATH" &&
   grep -A2 'com.apple.InAppPurchase = {' "$PROJECT_FILE_PATH" | grep -q 'enabled = 1;'; then
  pass "In-App Purchase capability is enabled."
else
  fail "In-App Purchase capability is missing."
fi

if grep -q 'GoogleSignIn-iOS' "$PROJECT_FILE_PATH" && grep -q 'purchases-ios-spm' "$PROJECT_FILE_PATH"; then
  pass "Google Sign-In and RevenueCat packages are linked."
else
  fail "Required Google Sign-In or RevenueCat package linkage is missing."
fi

printf '\n'
if [ "$failures" -gt 0 ]; then
  printf 'NOT READY: %s configuration failure(s), %s external blocker(s).\n' "$failures" "$blockers"
  exit 1
fi

if [ "$blockers" -gt 0 ]; then
  printf 'BLOCKED: configuration contracts pass, but %s external prerequisite(s) remain.\n' "$blockers"
  exit 2
fi

echo "READY: run the signed-device matrix in docs/native-phase-3-device-matrix.md."
