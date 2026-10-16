#!/bin/sh
set -eu

# Phase 33 (past-customer campaigns): segments and the shared service history,
# merge fields and compliance text, AI drafting, the on-device send queue,
# results and attribution, and the ?c= code, over the canonical models. The
# maintenance_due parity check compiles the Today insights engine too. The
# AppStore wiring runs in run-store-integration-tests.sh. Spec:
# docs/superpowers/specs/2026-10-03-campaigns-tags-design.md §5–§8, §12.
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUTPUT_PATH="${TMPDIR:-/tmp}/tradeready-campaign-tests"
MODULE_CACHE="${TMPDIR:-/tmp}/tradeready-campaign-module-cache"

swiftc \
  -module-cache-path "$MODULE_CACHE" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/CanonicalModels.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeQuoteExpiry.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/BusinessRules.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/FinancialDomain.swift" \
  "$ROOT_DIR/native/TradeReadyNative/NativeChangeOrders.swift" \
  "$ROOT_DIR/native/TradeReadyNative/NativeJobProfitability.swift" \
  "$ROOT_DIR/native/TradeReadyNative/NativeTimeTracking.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeCashBasis.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeMoneyReports.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeMoneyReportsJobs.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeMoneyReportsReadModels.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeSchedule.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeCalendar.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeServiceHistory.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeTodayInsights.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeLeadSource.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeReferrals.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativePropertiesEquipment.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeCustomerTags.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeAttributionCode.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeCampaignMessage.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeCampaignDrafting.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeCampaignSegments.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeCampaignResults.swift" \
  "$ROOT_DIR/native/CampaignTests/main.swift" \
  -o "$OUTPUT_PATH"

# Local-date and quiet-hours edges need a west-of-UTC zone (FA-039).
TZ="${TZ:-America/Phoenix}" "$OUTPUT_PATH"
