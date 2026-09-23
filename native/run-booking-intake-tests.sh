#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUTPUT_PATH="${TMPDIR:-/tmp}/tradeready-booking-intake-tests"
MODULE_CACHE="${TMPDIR:-/tmp}/tradeready-booking-intake-swift-module-cache"

swiftc \
  -module-cache-path "$MODULE_CACHE" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/CanonicalModels.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/CanonicalSnapshot.swift" \
  "$ROOT_DIR/native/TradeReadyNative/NativeMutationQueue.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeBookingIntake.swift" \
  "$ROOT_DIR/native/BookingIntakeTests/main.swift" \
  -o "$OUTPUT_PATH"

"$OUTPUT_PATH"
