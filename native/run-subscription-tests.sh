#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUTPUT_PATH="${TMPDIR:-/tmp}/tradeready-subscription-tests"
MODULE_CACHE="${TMPDIR:-/tmp}/tradeready-subscription-module-cache"

swiftc \
  -parse-as-library \
  -module-cache-path "$MODULE_CACHE" \
  "$ROOT_DIR/native/TradeReadyNative/NativeSubscription.swift" \
  "$ROOT_DIR/native/SubscriptionTests/main.swift" \
  -o "$OUTPUT_PATH"

"$OUTPUT_PATH"
