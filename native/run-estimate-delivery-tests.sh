#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUTPUT_PATH="${TMPDIR:-/tmp}/tradeready-estimate-delivery-tests"
MODULE_CACHE="${TMPDIR:-/tmp}/tradeready-estimate-delivery-module-cache"

swiftc \
  -parse-as-library \
  -module-cache-path "$MODULE_CACHE" \
  "$ROOT_DIR/native/TradeReadyNative/NativeEstimateDelivery.swift" \
  "$ROOT_DIR/native/EstimateDeliveryTests/main.swift" \
  -o "$OUTPUT_PATH"

"$OUTPUT_PATH"
