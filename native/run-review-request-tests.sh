#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUTPUT_PATH="${TMPDIR:-/tmp}/tradeready-review-request-tests"
MODULE_CACHE="${TMPDIR:-/tmp}/tradeready-review-request-module-cache"

swiftc \
  -parse-as-library \
  -module-cache-path "$MODULE_CACHE" \
  -framework Combine \
  -framework UserNotifications \
  "$ROOT_DIR/native/TradeReadyNative/Domain/CanonicalModels.swift" \
  "$ROOT_DIR/native/TradeReadyNative/NativeEstimateFollowUp.swift" \
  "$ROOT_DIR/native/TradeReadyNative/NativeEstimateFollowUpNotifications.swift" \
  "$ROOT_DIR/native/TradeReadyNative/NativeReviewRequests.swift" \
  "$ROOT_DIR/native/TradeReadyNative/NativeReviewRequestStore.swift" \
  "$ROOT_DIR/native/ReviewRequestTests/main.swift" \
  -o "$OUTPUT_PATH"

"$OUTPUT_PATH"
