#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUTPUT_PATH="${TMPDIR:-/tmp}/tradeready-build-environment-tests"
MODULE_CACHE="${TMPDIR:-/tmp}/tradeready-build-environment-module-cache"

swiftc \
  -parse-as-library \
  -module-cache-path "$MODULE_CACHE" \
  "$ROOT_DIR/native/TradeReadyNative/BuildEnvironment.swift" \
  "$ROOT_DIR/native/BuildEnvironmentTests/main.swift" \
  -o "$OUTPUT_PATH"

"$OUTPUT_PATH"
