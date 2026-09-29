#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUTPUT_PATH="${TMPDIR:-/tmp}/tradeready-global-search-tests"
MODULE_CACHE="${TMPDIR:-/tmp}/tradeready-global-search-swift-module-cache"

swiftc \
  -D GLOBAL_SEARCH_PURE_TESTS \
  -module-cache-path "$MODULE_CACHE" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/FinancialDomain.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/BusinessRules.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Models.swift" \
  "$ROOT_DIR/native/TradeReadyNative/NativeGlobalSearch.swift" \
  "$ROOT_DIR/native/GlobalSearchTests/main.swift" \
  -o "$OUTPUT_PATH"

"$OUTPUT_PATH"
