#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUTPUT_PATH="${TMPDIR:-/tmp}/tradeready-appointment-messaging-tests"
MODULE_CACHE="${TMPDIR:-/tmp}/tradeready-appointment-messaging-module-cache"

swiftc \
  -parse-as-library \
  -module-cache-path "$MODULE_CACHE" \
  "$ROOT_DIR/native/TradeReadyNative/NativeAppointmentMessaging.swift" \
  "$ROOT_DIR/native/AppointmentMessagingTests/main.swift" \
  -o "$OUTPUT_PATH"

"$OUTPUT_PATH"
