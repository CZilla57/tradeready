#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUTPUT_PATH="${TMPDIR:-/tmp}/tradeready-tax-settings-tests"
MODULE_CACHE="${TMPDIR:-/tmp}/tradeready-tax-settings-module-cache"

swiftc \
  -module-cache-path "$MODULE_CACHE" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/CanonicalModels.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/FinancialDomain.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeCashBasis.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeTaxSettings.swift" \
  "$ROOT_DIR/native/TradeReadyNative/NativeTaxBreakdown.swift" \
  "$ROOT_DIR/native/TaxSettingsTests/main.swift" \
  -o "$OUTPUT_PATH"

"$OUTPUT_PATH"
