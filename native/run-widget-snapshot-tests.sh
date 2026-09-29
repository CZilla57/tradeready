#!/bin/sh
set -eu

# Task 11.01 (W1): widget snapshot schema, projection, owner tag, App Group
# writer (lock + owner re-check), 10.09 seam observer overload, sign-out wipe.
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$ROOT_DIR/native/run-appstore-sources-common.sh"
OUTPUT_PATH="${TMPDIR:-/tmp}/tradeready-widget-snapshot-tests"
MODULE_CACHE="${TMPDIR:-/tmp}/tradeready-widget-snapshot-module-cache"

swiftc \
  -D GLOBAL_SEARCH_PURE_TESTS \
  -parse-as-library \
  -module-cache-path "$MODULE_CACHE" \
  $APPSTORE_TEST_SOURCES \
  "$ROOT_DIR/native/WidgetSnapshotTests/main.swift" \
  -o "$OUTPUT_PATH"

CANONICAL_FIXTURES_PATH="$ROOT_DIR/native/CanonicalTests/Fixtures" "$OUTPUT_PATH"
