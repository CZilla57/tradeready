#!/bin/sh
set -eu

# Phase 12 (12.00b.2-F, charter G6-Q1): permanent account deletion and the
# React Native sources the launch migration reads. Fixture devices in temp
# directories; the in-memory Keychain; no real App Group or Documents.
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$ROOT_DIR/native/run-appstore-sources-common.sh"
OUTPUT_PATH="${TMPDIR:-/tmp}/tradeready-legacy-reimport-tests"
MODULE_CACHE="${TMPDIR:-/tmp}/tradeready-legacy-reimport-module-cache"

swiftc \
  -D GLOBAL_SEARCH_PURE_TESTS \
  -parse-as-library \
  -module-cache-path "$MODULE_CACHE" \
  $APPSTORE_TEST_SOURCES \
  "$ROOT_DIR/native/LegacyReimportTests/main.swift" \
  -o "$OUTPUT_PATH"

TZ="${TZ:-America/Phoenix}" "$OUTPUT_PATH"
