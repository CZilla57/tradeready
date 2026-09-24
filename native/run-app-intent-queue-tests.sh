#!/bin/sh
set -eu

# Task 11.04 (A1-A3): App Intents, Siri dialogs and the action-queue contract.
# Compiles the AppStore closure (for the on-my-way review route and the replay
# planner/replayer) plus every intent source, so the intents' declarations
# and the writer's output are checked against the real planner.
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$ROOT_DIR/native/run-appstore-sources-common.sh"
OUTPUT_PATH="${TMPDIR:-/tmp}/tradeready-app-intent-queue-tests"
MODULE_CACHE="${TMPDIR:-/tmp}/tradeready-app-intent-queue-module-cache"

swiftc \
  -D GLOBAL_SEARCH_PURE_TESTS \
  -parse-as-library \
  -module-cache-path "$MODULE_CACHE" \
  $APPSTORE_TEST_SOURCES \
  "$ROOT_DIR/native/TradeReadyNative/Widgets/Shared/WidgetActionQueue.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Widgets/Shared/WidgetIntents.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Intents/SiriIntentDialogs.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Intents/JobActionIntents.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Intents/OnMyWayIntent.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Intents/NativeIntentURLRouter.swift" \
  "$ROOT_DIR/native/TradeReadyNative/NativeAppIntents.swift" \
  "$ROOT_DIR/native/AppIntentQueueTests/main.swift" \
  -o "$OUTPUT_PATH"

TRADEREADY_ROOT="$ROOT_DIR" "$OUTPUT_PATH"
