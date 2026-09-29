#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUTPUT_PATH="${TMPDIR:-/tmp}/tradeready-notification-coordinator-tests"
MODULE_CACHE="${TMPDIR:-/tmp}/tradeready-notification-coordinator-module-cache"

swiftc \
  -parse-as-library \
  -module-cache-path "$MODULE_CACHE" \
  -framework Combine \
  -framework UserNotifications \
  "$ROOT_DIR/native/TradeReadyNative/Domain/CanonicalModels.swift" \
  "$ROOT_DIR/native/TradeReadyNative/NativeEstimateFollowUp.swift" \
  "$ROOT_DIR/native/TradeReadyNative/NativeEstimateFollowUpNotifications.swift" \
  "$ROOT_DIR/native/TradeReadyNative/NativeNotificationCategories.swift" \
  "$ROOT_DIR/native/NotificationCoordinatorTests/main.swift" \
  -o "$OUTPUT_PATH"

"$OUTPUT_PATH"
