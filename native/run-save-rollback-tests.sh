#!/bin/sh
set -eu

# Phase 12 (12.00b.2-H, P12-008): a canonical snapshot save that fails leaves
# nothing unsaved in memory. The payment, bulk Mark paid, invoice editor,
# settings, onboarding and demo-reset commits run on a workspace whose snapshot
# saves fail on demand, then an unrelated save, a relaunch and a server pull;
# a source pin keeps every live-snapshot write inside the commit helpers.
# No network.
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$ROOT_DIR/native/run-appstore-sources-common.sh"
OUTPUT_PATH="${TMPDIR:-/tmp}/tradeready-save-rollback-tests"
MODULE_CACHE="${TMPDIR:-/tmp}/tradeready-save-rollback-module-cache"

swiftc \
  -D GLOBAL_SEARCH_PURE_TESTS \
  -parse-as-library \
  -module-cache-path "$MODULE_CACHE" \
  $APPSTORE_TEST_SOURCES \
  "$ROOT_DIR/native/SaveRollbackTests/main.swift" \
  -o "$OUTPUT_PATH"

TZ="${TZ:-America/Phoenix}" "$OUTPUT_PATH" "$ROOT_DIR"
