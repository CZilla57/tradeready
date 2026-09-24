#!/bin/sh
set -eu

# Task 11.02 (W2): Next Job widget policy — state resolution (§3.3),
# deep-link URL grammar round trip (§6.1), and the timeline refresh date.
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUTPUT_PATH="${TMPDIR:-/tmp}/tradeready-next-job-widget-tests"
MODULE_CACHE="${TMPDIR:-/tmp}/tradeready-next-job-widget-module-cache"

swiftc \
  -module-cache-path "$MODULE_CACHE" \
  "$ROOT_DIR/native/TradeReadyNative/Widgets/Shared/WidgetAppGroup.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Widgets/Shared/WidgetSnapshot.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Widgets/Shared/NextJobWidgetPolicy.swift" \
  "$ROOT_DIR/native/TradeReadyNative/NativeDeepLinkParser.swift" \
  "$ROOT_DIR/native/NextJobWidgetPolicyTests/main.swift" \
  -o "$OUTPUT_PATH"

"$OUTPUT_PATH"
