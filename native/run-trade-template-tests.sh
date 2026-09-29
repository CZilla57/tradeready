#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

swiftc \
  -module-cache-path "${TMPDIR:-/tmp}/tradeready-pricebook-module-cache" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/CanonicalModels.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/FinancialDomain.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeCashBasis.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeCSVExport.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeCSVImport.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeImportMapping.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeImportEngine.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativePricebook.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeTradeTemplates.swift" \
  "$ROOT_DIR/native/TradeTemplateTests/main.swift" \
  -o "${TMPDIR:-/tmp}/tradeready-trade-template-tests"

"${TMPDIR:-/tmp}/tradeready-trade-template-tests"
