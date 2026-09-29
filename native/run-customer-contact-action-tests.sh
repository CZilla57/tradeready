#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUTPUT_PATH="${TMPDIR:-/tmp}/tradeready-customer-contact-action-tests"
MODULE_CACHE="${TMPDIR:-/tmp}/tradeready-customer-contact-action-module-cache"

swiftc \
  -parse-as-library \
  -module-cache-path "$MODULE_CACHE" \
  "$ROOT_DIR/native/TradeReadyNative/NativeCustomerContactActions.swift" \
  "$ROOT_DIR/native/CustomerContactActionTests/main.swift" \
  -o "$OUTPUT_PATH"

"$OUTPUT_PATH"
