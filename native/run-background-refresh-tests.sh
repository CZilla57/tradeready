#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUTPUT_PATH="${TMPDIR:-/tmp}/tradeready-background-refresh-tests"
MODULE_CACHE="${TMPDIR:-/tmp}/tradeready-background-refresh-module-cache"

swiftc \
  -parse-as-library \
  -module-cache-path "$MODULE_CACHE" \
  "$ROOT_DIR/native/TradeReadyNative/NativeBackgroundRefresh.swift" \
  "$ROOT_DIR/native/TradeReadyNative/NativeDerivedStatePublisher.swift" \
  "$ROOT_DIR/native/BackgroundRefreshTests/main.swift" \
  -o "$OUTPUT_PATH"

"$OUTPUT_PATH"
