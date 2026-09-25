#!/bin/sh
set -eu

# Phase 12 (12.00b.1, known issue I2): the rejected-change store (bounded,
# owner-scoped, file-protected) and its AppStore wiring at every account
# boundary and in the support report. The poison-item, Retry, Discard and
# cursor scenarios run in run-poor-network-tests.sh.
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$ROOT_DIR/native/run-appstore-sources-common.sh"
OUTPUT_PATH="${TMPDIR:-/tmp}/tradeready-rejected-changes-tests"
MODULE_CACHE="${TMPDIR:-/tmp}/tradeready-rejected-changes-module-cache"

swiftc \
  -D GLOBAL_SEARCH_PURE_TESTS \
  -parse-as-library \
  -module-cache-path "$MODULE_CACHE" \
  $APPSTORE_TEST_SOURCES \
  "$ROOT_DIR/native/RejectedChangesTests/main.swift" \
  -o "$OUTPUT_PATH"

TZ="${TZ:-America/Phoenix}" "$OUTPUT_PATH"
