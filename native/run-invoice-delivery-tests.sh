#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUTPUT_PATH="${TMPDIR:-/tmp}/tradeready-invoice-delivery-tests"
MODULE_CACHE="${TMPDIR:-/tmp}/tradeready-invoice-delivery-swift-module-cache"

swiftc -parse-as-library -module-cache-path "$MODULE_CACHE" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/FinancialDomain.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/CanonicalModels.swift" \
  "$ROOT_DIR/native/TradeReadyNative/NativeInvoiceDelivery.swift" \
  "$ROOT_DIR/native/InvoiceDeliveryTests/main.swift" -o "$OUTPUT_PATH"

"$OUTPUT_PATH"
