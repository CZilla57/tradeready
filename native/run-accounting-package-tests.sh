#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUTPUT_PATH="${TMPDIR:-/tmp}/tradeready-accounting-package-tests"
MODULE_CACHE="${TMPDIR:-/tmp}/tradeready-accounting-package-module-cache"

swiftc \
  -module-cache-path "$MODULE_CACHE" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/CanonicalModels.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/FinancialDomain.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeCashBasis.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeCSVExport.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeZipArchive.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeAccountingPackage.swift" \
  "$ROOT_DIR/native/AccountingPackageTests/main.swift" \
  -o "$OUTPUT_PATH"

"$OUTPUT_PATH"
