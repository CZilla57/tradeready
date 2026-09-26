#!/bin/sh
set -eu

# Phase 12 (12.02): the privacy-safe support report
# (`NativeSupportDiagnostics.swift`, Settings > Prepare support report) and
# the monitoring signals the cutover charter reads (TH-1/TH-2 migration,
# TH-3 pending age, TH-5 discarded changes, TH-6 429 bursts, TH-9 payment
# commits, TH-10 purchases, the initial sync and the blocked account scrub),
# plus the synthetic dry run. The Sentry SDK is never compiled: a recording
# fake adapter sits behind the real reporter. No network.
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$ROOT_DIR/native/run-appstore-sources-common.sh"
OUTPUT_PATH="${TMPDIR:-/tmp}/tradeready-support-diagnostics-tests"
MODULE_CACHE="${TMPDIR:-/tmp}/tradeready-support-diagnostics-module-cache"

swiftc \
  -D GLOBAL_SEARCH_PURE_TESTS \
  -parse-as-library \
  -module-cache-path "$MODULE_CACHE" \
  $APPSTORE_TEST_SOURCES \
  "$ROOT_DIR/native/SupportDiagnosticsTests/main.swift" \
  -o "$OUTPUT_PATH"

TZ="${TZ:-America/Phoenix}" "$OUTPUT_PATH" "$ROOT_DIR"
