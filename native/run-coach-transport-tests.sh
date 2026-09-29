#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUTPUT_PATH="${TMPDIR:-/tmp}/tradeready-coach-transport-tests"
MODULE_CACHE="${TMPDIR:-/tmp}/tradeready-coach-transport-module-cache"

swiftc \
  -module-cache-path "$MODULE_CACHE" \
  "$ROOT_DIR/native/TradeReadyNative/NativeCoachTransport.swift" \
  "$ROOT_DIR/native/CoachTransportTests/main.swift" \
  -o "$OUTPUT_PATH"

"$OUTPUT_PATH"
