#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$ROOT_DIR/native/run-appstore-sources-common.sh"
OUTPUT_PATH="${TMPDIR:-/tmp}/tradeready-calendar-editor-tests"
MODULE_CACHE="${TMPDIR:-/tmp}/tradeready-store-integration-module-cache"

swiftc \
  -D GLOBAL_SEARCH_PURE_TESTS \
  -parse-as-library \
  -module-cache-path "$MODULE_CACHE" \
  $APPSTORE_TEST_SOURCES \
  "$ROOT_DIR/native/TradeReadyNative/NativeCalendarView.swift" \
  "$ROOT_DIR/native/TradeReadyNative/NativeScheduleEditorView.swift" \
  "$ROOT_DIR/native/CalendarEditorTests/main.swift" \
  -o "$OUTPUT_PATH"

CANONICAL_FIXTURES_PATH="$ROOT_DIR/native/CanonicalTests/Fixtures" "$OUTPUT_PATH"
