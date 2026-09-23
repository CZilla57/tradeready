#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUTPUT_PATH="${TMPDIR:-/tmp}/tradeready-invoice-pdf-tests"
MODULE_CACHE="${TMPDIR:-/tmp}/tradeready-invoice-pdf-swift-module-cache"

swiftc \
  -module-cache-path "$MODULE_CACHE" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/FinancialDomain.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/CanonicalModels.swift" \
  "$ROOT_DIR/native/TradeReadyNative/NativeInvoicePDF.swift" \
  "$ROOT_DIR/native/InvoicePDFTests/main.swift" \
  -o "$OUTPUT_PATH"

"$OUTPUT_PATH"
