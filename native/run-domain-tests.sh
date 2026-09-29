#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUTPUT_PATH="${TMPDIR:-/tmp}/tradeready-domain-tests"
MODULE_CACHE="${TMPDIR:-/tmp}/tradeready-swift-module-cache"

swiftc \
  -module-cache-path "$MODULE_CACHE" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/FinancialDomain.swift" \
  "$ROOT_DIR/native/DomainTests/main.swift" \
  -o "$OUTPUT_PATH"

"$OUTPUT_PATH"
