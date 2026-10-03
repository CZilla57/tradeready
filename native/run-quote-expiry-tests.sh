#!/bin/sh
set -eu

# Phase 32 quote expiration dates: the pure NativeQuoteExpiry policy and the
# shared expiry parity vectors (also loaded by the Worker's estimateExpiry
# tests). Executed west of UTC so a bare-date parse in the process zone would
# shift a day (FA-039).
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUTPUT_PATH="${TMPDIR:-/tmp}/tradeready-quote-expiry-tests"
MODULE_CACHE="${TMPDIR:-/tmp}/tradeready-quote-expiry-module-cache"

swiftc \
  -module-cache-path "$MODULE_CACHE" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/CanonicalModels.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeQuoteExpiry.swift" \
  "$ROOT_DIR/native/QuoteExpiryTests/main.swift" \
  -o "$OUTPUT_PATH"

TZ="${TZ:-America/Phoenix}" \
QUOTE_EXPIRY_VECTORS="$ROOT_DIR/native/QuoteExpiryTests/Fixtures/quote-expiry-vectors.json" \
  "$OUTPUT_PATH"
