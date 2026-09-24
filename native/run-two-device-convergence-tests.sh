#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUTPUT_PATH="${TMPDIR:-/tmp}/tradeready-two-device-convergence-tests"
MODULE_CACHE="${TMPDIR:-/tmp}/tradeready-two-device-convergence-module-cache"

swiftc \
  -parse-as-library \
  -module-cache-path "$MODULE_CACHE" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/CanonicalModels.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/CanonicalSnapshot.swift" \
  "$ROOT_DIR/native/TradeReadyNative/NativeSyncCursor.swift" \
  "$ROOT_DIR/native/TradeReadyNative/NativeMutationQueue.swift" \
  "$ROOT_DIR/native/TradeReadyNative/NativeInitialSync.swift" \
  "$ROOT_DIR/native/TradeReadyNative/NativeSupabasePush.swift" \
  "$ROOT_DIR/native/HostTestSupport/InMemorySupabase.swift" \
  "$ROOT_DIR/native/TwoDeviceConvergenceTests/main.swift" \
  -o "$OUTPUT_PATH"

CANONICAL_FIXTURES_PATH="$ROOT_DIR/native/CanonicalTests/Fixtures" "$OUTPUT_PATH"
