#!/bin/sh
set -eu

# Task 11.03 (W3): Job Timer widget — state resolution incl. owner-tagged
# pending-action precedence (§4.5), the stale/running/idle/no-job rules
# (§3.3), the deep-link fallback round trip (§6.1), and start/stop proven
# against the REAL replay planner (§4.1-4.3), driven through 11.04's
# `WidgetIntentEngine` rather than a reimplementation.
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUTPUT_PATH="${TMPDIR:-/tmp}/tradeready-job-timer-widget-tests"
MODULE_CACHE="${TMPDIR:-/tmp}/tradeready-job-timer-widget-module-cache"

swiftc \
  -parse-as-library \
  -module-cache-path "$MODULE_CACHE" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/CanonicalModels.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/CanonicalSnapshot.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/SnapshotRepository.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Widgets/Shared/WidgetAppGroup.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Widgets/Shared/WidgetSnapshot.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Widgets/Shared/WidgetActionFieldRules.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Widgets/Shared/WidgetActionQueue.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Widgets/Shared/NextJobWidgetPolicy.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Widgets/Shared/JobTimerWidgetPolicy.swift" \
  "$ROOT_DIR/native/TradeReadyNative/NativeWidgetOwnerGate.swift" \
  "$ROOT_DIR/native/TradeReadyNative/NativeWidgetActionReplay.swift" \
  "$ROOT_DIR/native/TradeReadyNative/NativeDeepLinkParser.swift" \
  "$ROOT_DIR/native/JobTimerWidgetPolicyTests/main.swift" \
  -o "$OUTPUT_PATH"

"$OUTPUT_PATH"
