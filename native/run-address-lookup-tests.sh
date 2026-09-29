#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUTPUT_PATH="${TMPDIR:-/tmp}/tradeready-address-lookup-tests"
MODULE_CACHE="${TMPDIR:-/tmp}/tradeready-address-lookup-swift-module-cache"

swiftc \
  -module-cache-path "$MODULE_CACHE" \
  "$ROOT_DIR/native/TradeReadyNative/NativeAddressLookup.swift" \
  "$ROOT_DIR/native/AddressLookupTests/main.swift" \
  -o "$OUTPUT_PATH"

"$OUTPUT_PATH"
