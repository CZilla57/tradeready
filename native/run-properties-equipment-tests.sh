#!/bin/sh
set -eu

# Phase 21 (multi-property and equipment history): the pure property and
# equipment rules (N/Domain/NativePropertiesEquipment.swift) and their seams:
# the canonical round-trip, the customer merge, the duplicate / recurring /
# occurrence whitelists, the nested delete + undo, the "Service address" rule
# and the warranty insight. Spec:
# docs/superpowers/specs/2026-10-02-properties-equipment-design.md §5.
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUTPUT_PATH="${TMPDIR:-/tmp}/tradeready-properties-equipment-tests"
MODULE_CACHE="${TMPDIR:-/tmp}/tradeready-properties-equipment-module-cache"

swiftc \
  -module-cache-path "$MODULE_CACHE" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/FinancialDomain.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/BusinessRules.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/CanonicalModels.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeQuoteExpiry.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/CanonicalSnapshot.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeLeadSource.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativePropertiesEquipment.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Models.swift" \
  "$ROOT_DIR/native/TradeReadyNative/NativeJobList.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/JobInvoiceDomain.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/UIModelAdapters.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeRecurringJobs.swift" \
  "$ROOT_DIR/native/TradeReadyNative/NativeMutationQueue.swift" \
  "$ROOT_DIR/native/TradeReadyNative/NativeCustomerIdentity.swift" \
  "$ROOT_DIR/native/TradeReadyNative/NativeRecordDeletion.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeCashBasis.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeMoneyReports.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeSchedule.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeCalendar.swift" \
  "$ROOT_DIR/native/TradeReadyNative/NativeTimeTracking.swift" \
  "$ROOT_DIR/native/TradeReadyNative/NativeChangeOrders.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeTodayInsights.swift" \
  "$ROOT_DIR/native/PropertiesEquipmentTests/main.swift" \
  -o "$OUTPUT_PATH"

# Warranty day-boundary checks need a west-of-UTC zone (FA-039).
TZ="${TZ:-America/Phoenix}" "$OUTPUT_PATH"
