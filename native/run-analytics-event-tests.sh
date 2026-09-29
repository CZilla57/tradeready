#!/bin/sh
set -eu

# Task 11.08 (P2, P3): event parity and the identity lifecycle. Compiles the
# AppStore closure (which includes N/NativeAnalyticsEvents.swift) and drives
# the real AppStore through the real NativeAnalyticsTransport over a
# recording fake SDK adapter: every §9.5 event and variant, m1-m3, identify /
# reset at sign-in, sign-out, account switch and deletion, and a throwing
# transport. The PostHog SDK is never compiled or linked here. Run with
# TZ=America/Phoenix (defaulted below).
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$ROOT_DIR/native/run-appstore-sources-common.sh"
OUTPUT_PATH="${TMPDIR:-/tmp}/tradeready-analytics-event-tests"
MODULE_CACHE="${TMPDIR:-/tmp}/tradeready-analytics-event-module-cache"

swiftc \
  -D GLOBAL_SEARCH_PURE_TESTS \
  -parse-as-library \
  -module-cache-path "$MODULE_CACHE" \
  $APPSTORE_TEST_SOURCES \
  "$ROOT_DIR/native/AnalyticsEventTests/main.swift" \
  -o "$OUTPUT_PATH"

TZ="${TZ:-America/Phoenix}" "$OUTPUT_PATH" "$ROOT_DIR"
