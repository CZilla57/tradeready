#!/bin/sh
set -eu

# Phase 34 (referral program, spec
# docs/superpowers/specs/2026-10-03-referral-program-design.md §7): codes,
# resolution, self-referral, links and copy (NativeReferrals), the intake
# decision (NativeBookingIntake), credits and rewards, the referral report and
# its control total against the lead-source report, the customer summary, the
# coach block and the referral_thanks Today insight. The code vectors are the
# fixture the Worker suites share.
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUTPUT_PATH="${TMPDIR:-/tmp}/tradeready-referral-tests"
MODULE_CACHE="${TMPDIR:-/tmp}/tradeready-referral-module-cache"

swiftc \
  -module-cache-path "$MODULE_CACHE" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/CanonicalModels.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/CanonicalSnapshot.swift" \
  "$ROOT_DIR/native/TradeReadyNative/NativeMutationQueue.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeLeadSource.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeReferrals.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeBookingIntake.swift" \
  "$ROOT_DIR/native/TradeReadyNative/BuildEnvironment.swift" \
  "$ROOT_DIR/native/TradeReadyNative/NativeBookingAdministration.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/FinancialDomain.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/BusinessRules.swift" \
  "$ROOT_DIR/native/TradeReadyNative/NativeJobList.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/JobInvoiceDomain.swift" \
  "$ROOT_DIR/native/TradeReadyNative/NativeChangeOrders.swift" \
  "$ROOT_DIR/native/TradeReadyNative/NativeJobProfitability.swift" \
  "$ROOT_DIR/native/TradeReadyNative/NativeCustomerIdentity.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Models.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeCashBasis.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeCSVExport.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeMoneyReports.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeMoneyReportsJobs.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeMoneyReportsReadModels.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeLeadSourceReport.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeReferralReport.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeMileage.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeTaxSettings.swift" \
  "$ROOT_DIR/native/TradeReadyNative/NativeTaxBreakdown.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeBusinessSnapshot.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeCoachPrompt.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeSchedule.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeCalendar.swift" \
  "$ROOT_DIR/native/TradeReadyNative/NativeTimeTracking.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeTodayInsights.swift" \
  "$ROOT_DIR/native/ReferralTests/main.swift" \
  -o "$OUTPUT_PATH"

# Day-boundary cases need a west-of-UTC zone (FA-039).
REFERRAL_CODE_VECTORS="$ROOT_DIR/native/ReferralTests/Fixtures/referral-code-vectors.json" \
TZ="${TZ:-America/Phoenix}" "$OUTPUT_PATH"
