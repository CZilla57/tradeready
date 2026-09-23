#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUTPUT_PATH="${TMPDIR:-/tmp}/tradeready-schedule-tests"
MODULE_CACHE="${TMPDIR:-/tmp}/tradeready-swift-schedule-module-cache"

swiftc \
  -module-cache-path "$MODULE_CACHE" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/CanonicalModels.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeSchedule.swift" \
  "$ROOT_DIR/native/ScheduleTests/main.swift" \
  -o "$OUTPUT_PATH"

"$OUTPUT_PATH"
