#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUTPUT_PATH="${TMPDIR:-/tmp}/tradeready-time-tracking-tests"
MODULE_CACHE="${TMPDIR:-/tmp}/tradeready-time-tracking-module-cache"

swiftc \
  -parse-as-library \
  -module-cache-path "$MODULE_CACHE" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/FinancialDomain.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/BusinessRules.swift" \
  "$ROOT_DIR/native/TradeReadyNative/NativeTimeTracking.swift" \
  "$ROOT_DIR/native/TimeTrackingTests/main.swift" \
  -o "$OUTPUT_PATH"

"$OUTPUT_PATH"
