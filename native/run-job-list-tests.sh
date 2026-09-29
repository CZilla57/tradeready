#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUTPUT_PATH="${TMPDIR:-/tmp}/tradeready-job-list-tests"
MODULE_CACHE="${TMPDIR:-/tmp}/tradeready-job-list-swift-module-cache"

swiftc \
  -module-cache-path "$MODULE_CACHE" \
  "$ROOT_DIR/native/TradeReadyNative/NativeJobList.swift" \
  "$ROOT_DIR/native/JobListTests/main.swift" \
  -o "$OUTPUT_PATH"

"$OUTPUT_PATH"
