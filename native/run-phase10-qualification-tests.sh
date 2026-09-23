#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUTPUT_PATH="${TMPDIR:-/tmp}/tradeready-phase10-qualification-tests"
MODULE_CACHE="${TMPDIR:-/tmp}/tradeready-phase10-qualification-module-cache"

swiftc \
  -parse-as-library \
  -module-cache-path "$MODULE_CACHE" \
  -framework Combine \
  -framework UserNotifications \
  "$ROOT_DIR/native/TradeReadyNative/Domain/CanonicalModels.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/BusinessRules.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/FinancialDomain.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/CanonicalSnapshot.swift" \
  "$ROOT_DIR/native/TradeReadyNative/NativeMutationQueue.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeCashBasis.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeMoneyReports.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeMoneyReportsJobs.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeMoneyReportsReadModels.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeMileage.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeTaxSettings.swift" \
  "$ROOT_DIR/native/TradeReadyNative/NativeTaxBreakdown.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeSchedule.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeCalendar.swift" \
  "$ROOT_DIR/native/TradeReadyNative/NativeTimeTracking.swift" \
  "$ROOT_DIR/native/TradeReadyNative/NativeChangeOrders.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeCSVExport.swift" \
  "$ROOT_DIR/native/TradeReadyNative/NativeJobProfitability.swift" \
  "$ROOT_DIR/native/TradeReadyNative/NativeCustomerIdentity.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Models.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeBusinessSnapshot.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeTodayInsights.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeBookingIntake.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeBookingAttention.swift" \
  "$ROOT_DIR/native/TradeReadyNative/NativeEstimateFollowUp.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeTodayBriefing.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeCoachPrompt.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeCoachQuickPrompts.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeChatMarkdown.swift" \
  "$ROOT_DIR/native/TradeReadyNative/NativeCoachTransport.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeCoachTranscript.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeInsightMutes.swift" \
  "$ROOT_DIR/native/TradeReadyNative/NativeInsightMuteStore.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeSetupChecklist.swift" \
  "$ROOT_DIR/native/TradeReadyNative/NativeSetupChecklistStore.swift" \
  "$ROOT_DIR/native/TradeReadyNative/NativeEstimateFollowUpNotifications.swift" \
  "$ROOT_DIR/native/TradeReadyNative/NativeNotificationCategories.swift" \
  "$ROOT_DIR/native/Phase10QualificationTests/main.swift" \
  -o "$OUTPUT_PATH"

"$OUTPUT_PATH"
