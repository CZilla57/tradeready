#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUTPUT_PATH="${TMPDIR:-/tmp}/tradeready-outreach-tests"
MODULE_CACHE="${TMPDIR:-/tmp}/tradeready-outreach-swift-module-cache"

swiftc \
  -module-cache-path "$MODULE_CACHE" \
  "$ROOT_DIR/native/TradeReadyNative/NativeEstimateDelivery.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeInvoicePaymentLinks.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeInvoiceOutreach.swift" \
  "$ROOT_DIR/native/OutreachTests/main.swift" \
  -o "$OUTPUT_PATH"

"$OUTPUT_PATH"
