#!/bin/sh
set -eu

# Task 11.07 (P1, P4): analytics transport and privacy controls. Compiles the
# AppStore closure plus the analytics gate so the policy, the gate and the
# unchanged AppStore call sites all run against a fake SDK adapter. The
# PostHog SDK (N/NativeAnalyticsPostHog.swift) is never compiled or linked
# here. Run with TZ=America/Phoenix.
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$ROOT_DIR/native/run-appstore-sources-common.sh"
OUTPUT_PATH="${TMPDIR:-/tmp}/tradeready-analytics-transport-tests"
MODULE_CACHE="${TMPDIR:-/tmp}/tradeready-analytics-transport-module-cache"

swiftc \
  -D GLOBAL_SEARCH_PURE_TESTS \
  -parse-as-library \
  -module-cache-path "$MODULE_CACHE" \
  $APPSTORE_TEST_SOURCES \
  "$ROOT_DIR/native/TradeReadyNative/NativeAnalyticsConfiguration.swift" \
  "$ROOT_DIR/native/AnalyticsTransportTests/main.swift" \
  -o "$OUTPUT_PATH"

TZ="${TZ:-America/Phoenix}" "$OUTPUT_PATH" "$ROOT_DIR"
