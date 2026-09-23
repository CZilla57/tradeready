#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUTPUT_PATH="${TMPDIR:-/tmp}/tradeready-interaction-state-tests"
MODULE_CACHE="${TMPDIR:-/tmp}/tradeready-interaction-state-swift-module-cache"

swiftc \
  -D NATIVE_INTERACTION_PURE_TESTS \
  -module-cache-path "$MODULE_CACHE" \
  "$ROOT_DIR/native/TradeReadyNative/NativeInteractionState.swift" \
  "$ROOT_DIR/native/InteractionStateTests/main.swift" \
  -o "$OUTPUT_PATH"

"$OUTPUT_PATH"
