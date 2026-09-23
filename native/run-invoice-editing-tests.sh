#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUTPUT_PATH="${TMPDIR:-/tmp}/tradeready-invoice-editing-tests"
MODULE_CACHE="${TMPDIR:-/tmp}/tradeready-invoice-editing-swift-module-cache"

swiftc \
  -module-cache-path "$MODULE_CACHE" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeInvoiceEditing.swift" \
  "$ROOT_DIR/native/InvoiceEditingTests/main.swift" \
  -o "$OUTPUT_PATH"

"$OUTPUT_PATH"
