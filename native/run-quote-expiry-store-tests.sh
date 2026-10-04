#!/bin/sh
set -eu

# Phase 32 (quote expiration dates): the AppStore wiring over the shared
# in-memory Supabase server and a fake approval-link service — the review
# draft's proposed date, the three send stamps, the link's fail-closed date
# check, the declined-revision guard and extending a sent estimate. The pure
# rules run in run-quote-expiry-tests.sh.
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$ROOT_DIR/native/run-appstore-sources-common.sh"
OUTPUT_PATH="${TMPDIR:-/tmp}/tradeready-quote-expiry-store-tests"
MODULE_CACHE="${TMPDIR:-/tmp}/tradeready-quote-expiry-store-module-cache"

swiftc \
  -D GLOBAL_SEARCH_PURE_TESTS \
  -parse-as-library \
  -module-cache-path "$MODULE_CACHE" \
  $APPSTORE_TEST_SOURCES \
  "$ROOT_DIR/native/HostTestSupport/InMemorySupabase.swift" \
  "$ROOT_DIR/native/QuoteExpiryStoreTests/main.swift" \
  -o "$OUTPUT_PATH"

TZ="${TZ:-America/Phoenix}" "$OUTPUT_PATH"

# Review fix 2026-10-03 (finding 1): the device-calendar test again with the
# iPhone's Calendar setting Buddhist and Japanese (`Calendar.current` follows
# -AppleLocale).
for device_calendar in buddhist japanese; do
  TZ="${TZ:-America/Phoenix}" \
  QUOTE_EXPIRY_STORE_ONLY=device-calendar \
  QUOTE_EXPIRY_DEVICE_CALENDAR="$device_calendar" \
    "$OUTPUT_PATH" -AppleLocale "en_US@calendar=$device_calendar"
done
