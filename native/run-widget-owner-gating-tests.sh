#!/bin/sh
set -eu

# Task 11.05 (W4): widget/Siri owner gating, stale data and sign-in
# correctness. Compiles the AppStore closure (replay gate, scrub paths,
# mirror, `handle(url:)`) plus the extension's Foundation-only intent engine
# and the widget policies, so every fixture runs against the real code on a
# throwaway App Group suite and lock file. Run with TZ=America/Phoenix.
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$ROOT_DIR/native/run-appstore-sources-common.sh"
OUTPUT_PATH="${TMPDIR:-/tmp}/tradeready-widget-owner-gating-tests"
MODULE_CACHE="${TMPDIR:-/tmp}/tradeready-widget-owner-gating-module-cache"

swiftc \
  -D GLOBAL_SEARCH_PURE_TESTS \
  -parse-as-library \
  -module-cache-path "$MODULE_CACHE" \
  $APPSTORE_TEST_SOURCES \
  "$ROOT_DIR/native/TradeReadyNative/Widgets/Shared/WidgetActionQueue.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Widgets/Shared/NextJobWidgetPolicy.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Widgets/Shared/JobTimerWidgetPolicy.swift" \
  "$ROOT_DIR/native/WidgetOwnerGatingTests/main.swift" \
  -o "$OUTPUT_PATH"

TZ="${TZ:-America/Phoenix}" TRADEREADY_ROOT="$ROOT_DIR" "$OUTPUT_PATH"
