#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUTPUT_PATH="${TMPDIR:-/tmp}/tradeready-insight-mute-tests"
MODULE_CACHE="${TMPDIR:-/tmp}/tradeready-insight-mute-module-cache"

swiftc \
  -module-cache-path "$MODULE_CACHE" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/CanonicalModels.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/FinancialDomain.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeCashBasis.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeInsightMutes.swift" \
  "$ROOT_DIR/native/TradeReadyNative/NativeInsightMuteStore.swift" \
  "$ROOT_DIR/native/InsightMuteTests/main.swift" \
  -o "$OUTPUT_PATH"

"$OUTPUT_PATH"
