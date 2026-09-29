#!/bin/sh
set -eu
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUTPUT_PATH="${TMPDIR:-/tmp}/tradeready-appointment-notification-tests"
swiftc -parse-as-library \
  "$ROOT_DIR/native/TradeReadyNative/Domain/CanonicalModels.swift" \
  "$ROOT_DIR/native/TradeReadyNative/NativeEstimateFollowUp.swift" \
  "$ROOT_DIR/native/TradeReadyNative/NativeEstimateFollowUpNotifications.swift" \
  "$ROOT_DIR/native/TradeReadyNative/NativeNotificationCategories.swift" \
  "$ROOT_DIR/native/TradeReadyNative/NativeAppointmentNotifications.swift" \
  "$ROOT_DIR/native/AppointmentNotificationTests/main.swift" \
  -o "$OUTPUT_PATH"
"$OUTPUT_PATH"
