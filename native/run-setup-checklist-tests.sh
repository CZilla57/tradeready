#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUTPUT_PATH="${TMPDIR:-/tmp}/tradeready-setup-checklist-tests"
MODULE_CACHE="${TMPDIR:-/tmp}/tradeready-setup-checklist-module-cache"

swiftc \
  -module-cache-path "$MODULE_CACHE" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/CanonicalModels.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeSetupChecklist.swift" \
  "$ROOT_DIR/native/TradeReadyNative/NativeSetupChecklistStore.swift" \
  "$ROOT_DIR/native/SetupChecklistTests/main.swift" \
  -o "$OUTPUT_PATH"

"$OUTPUT_PATH"
