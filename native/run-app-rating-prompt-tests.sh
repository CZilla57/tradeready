#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUTPUT_PATH="${TMPDIR:-/tmp}/tradeready-app-rating-prompt-tests"
MODULE_CACHE="${TMPDIR:-/tmp}/tradeready-app-rating-prompt-module-cache"

swiftc \
  -module-cache-path "$MODULE_CACHE" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeAppRatingPrompt.swift" \
  "$ROOT_DIR/native/TradeReadyNative/NativeAppRatingPromptCoordinator.swift" \
  "$ROOT_DIR/native/AppRatingPromptTests/main.swift" \
  -o "$OUTPUT_PATH"

"$OUTPUT_PATH"
