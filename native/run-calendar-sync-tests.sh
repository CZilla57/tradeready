#!/bin/sh
set -eu

# Roadmap Phase 26 (calendar sync, spec
# docs/superpowers/specs/2026-10-03-calendar-sync-design.md §7): the pure
# busy rules, the wire snapshot (clipping, minute rounding, merging,
# truncation, all-day dates under injected Phoenix and Auckland calendars, the
# exact JSON and digest), the gate twin's state edges and status copy, and the
# Stage B mirror planner. No EventKit and no network: the adapter is not
# compiled here. Run with TZ=America/Phoenix (defaulted).
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUTPUT_PATH="${TMPDIR:-/tmp}/tradeready-calendar-sync-tests"
MODULE_CACHE="${TMPDIR:-/tmp}/tradeready-swift-calendar-sync-module-cache"

swiftc \
  -module-cache-path "$MODULE_CACHE" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/CanonicalModels.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeSchedule.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeAvailability.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeCalendar.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeCalendarBusy.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeCalendarMirror.swift" \
  "$ROOT_DIR/native/CalendarSyncTests/main.swift" \
  -o "$OUTPUT_PATH"

TZ="${TZ:-America/Phoenix}" "$OUTPUT_PATH"
