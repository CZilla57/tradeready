#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUTPUT_PATH="${TMPDIR:-/tmp}/tradeready-stripe-connect-tests"
MODULE_CACHE="${TMPDIR:-/tmp}/tradeready-stripe-connect-swift-module-cache"

swiftc \
  -parse-as-library \
  -module-cache-path "$MODULE_CACHE" \
  "$ROOT_DIR/native/TradeReadyNative/NativeStripeConnect.swift" \
  "$ROOT_DIR/native/StripeConnectTests/main.swift" \
  -o "$OUTPUT_PATH"

"$OUTPUT_PATH"
