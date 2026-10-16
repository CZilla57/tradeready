#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUTPUT_PATH="${TMPDIR:-/tmp}/tradeready-quote-options-tests"
MODULE_CACHE="${TMPDIR:-/tmp}/tradeready-quote-options-module-cache"

swiftc \
  -module-cache-path "$MODULE_CACHE" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/FinancialDomain.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/BusinessRules.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/CanonicalModels.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Models.swift" \
  "$ROOT_DIR/native/TradeReadyNative/NativeJobList.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/JobInvoiceDomain.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/UIModelAdapters.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeQuoteOptions.swift" \
  "$ROOT_DIR/native/TradeReadyNative/NativeChangeOrders.swift" \
  "$ROOT_DIR/native/TradeReadyNative/NativeJobProfitability.swift" \
  "$ROOT_DIR/native/QuoteOptionsTests/main.swift" \
  -o "$OUTPUT_PATH"

QUOTE_SELECTION_VECTORS="$ROOT_DIR/native/QuoteOptionsTests/Fixtures/quote-selection-vectors.json" \
CANONICAL_FIXTURE="$ROOT_DIR/native/CanonicalTests/Fixtures/canonical-rich.json" \
  "$OUTPUT_PATH"
