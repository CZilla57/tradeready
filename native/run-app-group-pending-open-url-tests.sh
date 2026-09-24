#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUTPUT_PATH="${TMPDIR:-/tmp}/tradeready-app-group-pending-open-url-tests"
MODULE_CACHE="${TMPDIR:-/tmp}/tradeready-app-group-pending-open-url-module-cache"

swiftc \
  -parse-as-library \
  -module-cache-path "$MODULE_CACHE" \
  "$ROOT_DIR/native/TradeReadyNative/Widgets/Shared/WidgetActionFieldRules.swift" \
  "$ROOT_DIR/native/TradeReadyNative/NativeDeepLinkParser.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Widgets/Shared/WidgetAppGroup.swift" \
  "$ROOT_DIR/native/TradeReadyNative/NativeAppGroupInbox.swift" \
  "$ROOT_DIR/native/AppGroupPendingOpenURLTests/main.swift" \
  -o "$OUTPUT_PATH"

"$OUTPUT_PATH"
