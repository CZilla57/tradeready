#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUTPUT_PATH="${TMPDIR:-/tmp}/tradeready-business-snapshot-tests"
MODULE_CACHE="${TMPDIR:-/tmp}/tradeready-business-snapshot-module-cache"

swiftc \
  -module-cache-path "$MODULE_CACHE" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/CanonicalModels.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/FinancialDomain.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/BusinessRules.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/CanonicalSnapshot.swift" \
  "$ROOT_DIR/native/TradeReadyNative/NativeMutationQueue.swift" \
  "$ROOT_DIR/native/TradeReadyNative/NativeChangeOrders.swift" \
  "$ROOT_DIR/native/TradeReadyNative/NativeJobProfitability.swift" \
  "$ROOT_DIR/native/TradeReadyNative/NativeCustomerIdentity.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Models.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeCashBasis.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeCSVExport.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeMoneyReports.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeMoneyReportsJobs.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeMoneyReportsReadModels.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeMileage.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeTaxSettings.swift" \
  "$ROOT_DIR/native/TradeReadyNative/NativeTaxBreakdown.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeBusinessSnapshot.swift" \
  "$ROOT_DIR/native/BusinessSnapshotTests/main.swift" \
  -o "$OUTPUT_PATH"

"$OUTPUT_PATH"
