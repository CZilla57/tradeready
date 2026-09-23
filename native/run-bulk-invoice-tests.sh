#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUTPUT_PATH="${TMPDIR:-/tmp}/tradeready-bulk-invoice-tests"
MODULE_CACHE="${TMPDIR:-/tmp}/tradeready-bulk-invoice-swift-module-cache"

swiftc \
  -module-cache-path "$MODULE_CACHE" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeInvoiceBulk.swift" \
  "$ROOT_DIR/native/BulkInvoiceTests/main.swift" \
  -o "$OUTPUT_PATH"

"$OUTPUT_PATH"
