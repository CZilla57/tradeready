#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$ROOT_DIR/native/run-appstore-sources-common.sh"
OUTPUT_PATH="${TMPDIR:-/tmp}/tradeready-export-import-ui-tests"
MODULE_CACHE="${TMPDIR:-/tmp}/tradeready-export-import-ui-module-cache"

swiftc \
  -D GLOBAL_SEARCH_PURE_TESTS \
  -module-cache-path "$MODULE_CACHE" \
  $APPSTORE_TEST_SOURCES \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeExportImportPresentation.swift" \
  "$ROOT_DIR/native/ExportImportUITests/main.swift" \
  -o "$OUTPUT_PATH"


"$OUTPUT_PATH"
