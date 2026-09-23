#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUTPUT_PATH="${TMPDIR:-/tmp}/tradeready-receipt-ocr-tests"
MODULE_CACHE="${TMPDIR:-/tmp}/tradeready-receipt-ocr-module-cache"

swiftc \
  -module-cache-path "$MODULE_CACHE" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/CanonicalModels.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/FinancialDomain.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeCashBasis.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeCSVExport.swift" \
  "$ROOT_DIR/native/TradeReadyNative/NativeReceiptOCR.swift" \
  "$ROOT_DIR/native/ReceiptOCRTests/main.swift" \
  -o "$OUTPUT_PATH"

"$OUTPUT_PATH"
