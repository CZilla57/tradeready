#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUTPUT_PATH="${TMPDIR:-/tmp}/tradeready-expense-editor-tests"
MODULE_CACHE="${TMPDIR:-/tmp}/tradeready-expense-editor-module-cache"

swiftc \
  -module-cache-path "$MODULE_CACHE" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/CanonicalModels.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/FinancialDomain.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeCashBasis.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeCSVExport.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeExpenseComposer.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeReceiptMedia.swift" \
  "$ROOT_DIR/native/TradeReadyNative/NativeReceiptOCR.swift" \
  "$ROOT_DIR/native/ExpenseEditorTests/main.swift" \
  -o "$OUTPUT_PATH"

"$OUTPUT_PATH"
