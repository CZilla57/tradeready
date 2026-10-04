#!/bin/sh
set -eu

# Phase 18 (Tap to Pay on iPhone): the pure rules, the Worker transport, the
# capability gate, the sheet's state machine over NativeFakeCardReader and the
# AppStore's recordCardPresentPayment. No network and no Stripe Terminal SDK:
# the SDK reader is stage B and is never compiled here. `-D DEBUG` compiles
# the DEBUG-only NativeFakeCardReader. Run with TZ=America/Phoenix.
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$ROOT_DIR/native/run-appstore-sources-common.sh"
OUTPUT_PATH="${TMPDIR:-/tmp}/tradeready-tap-to-pay-tests"
MODULE_CACHE="${TMPDIR:-/tmp}/tradeready-tap-to-pay-module-cache"

swiftc \
  -D GLOBAL_SEARCH_PURE_TESTS \
  -D DEBUG \
  -parse-as-library \
  -module-cache-path "$MODULE_CACHE" \
  $APPSTORE_TEST_SOURCES \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeAccountingPackage.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeCardPresentPayment.swift" \
  "$ROOT_DIR/native/TradeReadyNative/NativeTerminalService.swift" \
  "$ROOT_DIR/native/TradeReadyNative/NativeCardReader.swift" \
  "$ROOT_DIR/native/TradeReadyNative/NativeFakeCardReader.swift" \
  "$ROOT_DIR/native/TradeReadyNative/NativeTapToPayFlow.swift" \
  "$ROOT_DIR/native/TapToPayTests/main.swift" \
  -o "$OUTPUT_PATH"

TZ="${TZ:-America/Phoenix}" "$OUTPUT_PATH"
