#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUTPUT_PATH="${TMPDIR:-/tmp}/tradeready-confirmation-tests"
MODULE_CACHE="${TMPDIR:-/tmp}/tradeready-confirmation-module-cache"

swiftc \
  -parse-as-library \
  -D NATIVE_CONFIRMATION_PURE_TESTS \
  -module-cache-path "$MODULE_CACHE" \
  "$ROOT_DIR/native/TradeReadyNative/NativeConfirmation.swift" \
  "$ROOT_DIR/native/ConfirmationTests/main.swift" \
  -o "$OUTPUT_PATH"

"$OUTPUT_PATH"
