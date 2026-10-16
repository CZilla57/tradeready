#!/bin/sh
set -eu

# Phase 25 (good/better/best quote options): the AppStore wiring over the
# shared in-memory Supabase server — option edits, the owner-recorded choice,
# the post-pull decision reconciler and the rebase graft. The pure domain
# runs in run-quote-options-tests.sh.
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$ROOT_DIR/native/run-appstore-sources-common.sh"
OUTPUT_PATH="${TMPDIR:-/tmp}/tradeready-quote-options-store-tests"
MODULE_CACHE="${TMPDIR:-/tmp}/tradeready-quote-options-store-module-cache"

swiftc \
  -D GLOBAL_SEARCH_PURE_TESTS \
  -parse-as-library \
  -module-cache-path "$MODULE_CACHE" \
  $APPSTORE_TEST_SOURCES \
  "$ROOT_DIR/native/HostTestSupport/InMemorySupabase.swift" \
  "$ROOT_DIR/native/QuoteOptionsStoreTests/main.swift" \
  -o "$OUTPUT_PATH"

TZ="${TZ:-America/Phoenix}" "$OUTPUT_PATH"
