#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUTPUT_PATH="${TMPDIR:-/tmp}/tradeready-availability-tests"
MODULE_CACHE="${TMPDIR:-/tmp}/tradeready-swift-availability-module-cache"

swiftc \
  -module-cache-path "$MODULE_CACHE" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/CanonicalModels.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeSchedule.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeAvailability.swift" \
  "$ROOT_DIR/native/AvailabilityTests/main.swift" \
  -o "$OUTPUT_PATH"

SCHEDULE_FIXTURES_PATH="$ROOT_DIR/native/ScheduleTests/Fixtures/scheduleVectors.json" "$OUTPUT_PATH"
