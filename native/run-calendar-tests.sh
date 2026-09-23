#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUTPUT_PATH="${TMPDIR:-/tmp}/tradeready-calendar-tests"
MODULE_CACHE="${TMPDIR:-/tmp}/tradeready-swift-calendar-module-cache"

swiftc \
  -module-cache-path "$MODULE_CACHE" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/CanonicalModels.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeSchedule.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeCalendar.swift" \
  "$ROOT_DIR/native/CalendarTests/main.swift" \
  -o "$OUTPUT_PATH"

"$OUTPUT_PATH"
