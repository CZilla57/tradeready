#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUTPUT_PATH="${TMPDIR:-/tmp}/tradeready-tips-tests"
MODULE_CACHE="${TMPDIR:-/tmp}/tradeready-tips-module-cache"

swiftc \
  -module-cache-path "$MODULE_CACHE" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/CanonicalModels.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/FinancialDomain.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/BusinessRules.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Models.swift" \
  "$ROOT_DIR/native/TradeReadyNative/NativeJobList.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/JobInvoiceDomain.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/UIModelAdapters.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeLeadSource.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeLeadSourceReport.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeReferrals.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeReferralReport.swift" \
  "$ROOT_DIR/native/TradeReadyNative/NativeChangeOrders.swift" \
  "$ROOT_DIR/native/TradeReadyNative/NativeJobProfitability.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeCashBasis.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeCSVExport.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeExpenseComposer.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeMoneyReports.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeMoneyReportsJobs.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeMoneyReportsReadModels.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeMileage.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeTaxSettings.swift" \
  "$ROOT_DIR/native/TradeReadyNative/NativeTaxBreakdown.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeMoneyCardModels.swift" \
  "$ROOT_DIR/native/TradeReadyNative/NativeReceiptOCR.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeZipArchive.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeAccountingPackage.swift" \
  "$ROOT_DIR/native/TipsTests/main.swift" \
  -o "$OUTPUT_PATH"

# Money-date edges need a west-of-UTC zone (FA-039); the settings fixture is
# the canonical rich fixture.
CANONICAL_FIXTURES_PATH="$ROOT_DIR/native/CanonicalTests/Fixtures" TZ="${TZ:-America/Phoenix}" "$OUTPUT_PATH"
