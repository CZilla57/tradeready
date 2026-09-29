#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUTPUT_PATH="${TMPDIR:-/tmp}/tradeready-widget-action-replay-tests"
MODULE_CACHE="${TMPDIR:-/tmp}/tradeready-widget-action-replay-module-cache"

swiftc \
  -parse-as-library \
  -module-cache-path "$MODULE_CACHE" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/CanonicalModels.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/CanonicalSnapshot.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/SnapshotRepository.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Widgets/Shared/WidgetAppGroup.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Widgets/Shared/WidgetActionFieldRules.swift" \
  "$ROOT_DIR/native/TradeReadyNative/NativeWidgetOwnerGate.swift" \
  "$ROOT_DIR/native/TradeReadyNative/NativeWidgetActionReplay.swift" \
  "$ROOT_DIR/native/WidgetActionReplayTests/main.swift" \
  -o "$OUTPUT_PATH"

"$OUTPUT_PATH"
