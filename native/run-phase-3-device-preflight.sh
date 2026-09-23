#!/bin/sh
set -u

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
PROJECT_PATH="$ROOT_DIR/native/TradeReadyNative.xcodeproj"
ENTITLEMENTS_PATH="$ROOT_DIR/native/TradeReadyNative/TradeReadyNative.entitlements"
INFO_PLIST_PATH="$ROOT_DIR/native/Info.plist"
PROJECT_FILE_PATH="$PROJECT_PATH/project.pbxproj"

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
  google_ios_client_id=$(configured_value TRADEREADY_GOOGLE_IOS_CLIENT_ID)
  google_server_client_id=$(configured_value TRADEREADY_GOOGLE_SERVER_CLIENT_ID)
  revenuecat_key=$(configured_value TRADEREADY_REVENUECAT_API_KEY)
  revenuecat_entitlement=$(configured_value TRADEREADY_REVENUECAT_ENTITLEMENT_ID)

  if [ "$environment" = staging ]; then
    pass "Release is isolated to the staging environment."
  else
    fail "Release must use the staging environment while Phase 3 is under verification."
  fi

  case "$backend_url" in
    https://staging.invalid|*://*.invalid|*://localhost*|*://127.0.0.1*)
      block "Configure the trusted HTTPS staging backend before exercising account deletion."
      ;;
    https://*)
      pass "Release has a non-placeholder HTTPS backend."
      ;;
    *)
      fail "Release requires a non-placeholder HTTPS backend."
      ;;
  esac

  if [ "$production_writes" = NO ]; then
    pass "Production writes remain disabled in the staging build."
  else
    fail "Production writes must remain disabled during staging verification."
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
