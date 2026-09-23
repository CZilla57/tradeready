#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUTPUT_PATH="${TMPDIR:-/tmp}/tradeready-booking-response-tests"
MODULE_CACHE="${TMPDIR:-/tmp}/tradeready-booking-response-module-cache"

swiftc \
  -parse-as-library \
  -module-cache-path "$MODULE_CACHE" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/CanonicalModels.swift" \
  "$ROOT_DIR/native/TradeReadyNative/BuildEnvironment.swift" \
  "$ROOT_DIR/native/TradeReadyNative/NativeBookingResponse.swift" \
  "$ROOT_DIR/native/BookingResponseTests/main.swift" \
  -o "$OUTPUT_PATH"

"$OUTPUT_PATH"
