#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$ROOT_DIR/native/run-appstore-sources-common.sh"
OUTPUT_PATH="${TMPDIR:-/tmp}/tradeready-phase9-qualification-tests"
MODULE_CACHE="${TMPDIR:-/tmp}/tradeready-phase9-qualification-module-cache"

swiftc \
  -D GLOBAL_SEARCH_PURE_TESTS \
  -module-cache-path "$MODULE_CACHE" \
  $APPSTORE_TEST_SOURCES \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeAccountingPackage.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeMileageLog.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeTradeTemplates.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativePricebookPresentation.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeExportImportPresentation.swift" \
  "$ROOT_DIR/native/Phase9QualificationTests/main.swift" \
  -o "$OUTPUT_PATH"


"$OUTPUT_PATH"
