#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUTPUT_PATH="${TMPDIR:-/tmp}/tradeready-recurring-invoice-tests"
MODULE_CACHE="${TMPDIR:-/tmp}/tradeready-recurring-invoice-swift-module-cache"

swiftc \
  -module-cache-path "$MODULE_CACHE" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/CanonicalModels.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/FinancialDomain.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/BusinessRules.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeRecurringInvoices.swift" \
  "$ROOT_DIR/native/RecurringInvoiceTests/main.swift" \
  -o "$OUTPUT_PATH"

"$OUTPUT_PATH"
