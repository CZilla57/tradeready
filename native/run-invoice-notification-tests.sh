#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUTPUT_PATH="${TMPDIR:-/tmp}/tradeready-invoice-notification-tests"
MODULE_CACHE="${TMPDIR:-/tmp}/tradeready-invoice-notification-swift-module-cache"

swiftc \
  -module-cache-path "$MODULE_CACHE" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeInvoiceNotifications.swift" \
  "$ROOT_DIR/native/InvoiceNotificationTests/main.swift" \
  -o "$OUTPUT_PATH"

"$OUTPUT_PATH"
