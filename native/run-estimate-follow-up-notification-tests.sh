#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUTPUT_PATH="${TMPDIR:-/tmp}/tradeready-estimate-follow-up-notification-tests"
MODULE_CACHE="${TMPDIR:-/tmp}/tradeready-estimate-follow-up-notification-module-cache"

swiftc \
  -parse-as-library \
  -module-cache-path "$MODULE_CACHE" \
  -framework Combine \
  -framework UserNotifications \
  "$ROOT_DIR/native/TradeReadyNative/Domain/CanonicalModels.swift" \
  "$ROOT_DIR/native/TradeReadyNative/NativeEstimateFollowUp.swift" \
  "$ROOT_DIR/native/TradeReadyNative/NativeEstimateFollowUpNotifications.swift" \
  "$ROOT_DIR/native/TradeReadyNative/NativeNotificationCategories.swift" \
  "$ROOT_DIR/native/EstimateFollowUpNotificationTests/main.swift" \
  -o "$OUTPUT_PATH"

"$OUTPUT_PATH"
