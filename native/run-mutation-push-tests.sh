#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUTPUT_PATH="${TMPDIR:-/tmp}/tradeready-mutation-push-tests"
MODULE_CACHE="${TMPDIR:-/tmp}/tradeready-mutation-push-module-cache"

swiftc \
  -parse-as-library \
  -module-cache-path "$MODULE_CACHE" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/CanonicalModels.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/CanonicalSnapshot.swift" \
  "$ROOT_DIR/native/TradeReadyNative/NativeMutationQueue.swift" \
  "$ROOT_DIR/native/TradeReadyNative/NativeMutationPushClassification.swift" \
  "$ROOT_DIR/native/TradeReadyNative/NativeSupabasePush.swift" \
  "$ROOT_DIR/native/MutationPushTests/main.swift" \
  -o "$OUTPUT_PATH"

"$OUTPUT_PATH"
