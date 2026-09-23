#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUTPUT_PATH="${TMPDIR:-/tmp}/tradeready-job-photo-transfer-tests"
MODULE_CACHE="${TMPDIR:-/tmp}/tradeready-job-photo-transfer-module-cache"

swiftc \
  -parse-as-library \
  -module-cache-path "$MODULE_CACHE" \
  "$ROOT_DIR/native/TradeReadyNative/NativeJobPhotoTransfer.swift" \
  "$ROOT_DIR/native/JobPhotoTransferTests/main.swift" \
  -o "$OUTPUT_PATH"

"$OUTPUT_PATH"
