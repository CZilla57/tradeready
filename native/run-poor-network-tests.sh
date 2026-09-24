#!/bin/sh
set -eu

# Task 11.12 (H3): the real sync coordinator, durable queue, push transport,
# delta pull and AppStore pull commit over a degraded link (offline, throttled,
# timed out, dropped mid-pass) in front of the shared in-memory server.
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$ROOT_DIR/native/run-appstore-sources-common.sh"
OUTPUT_PATH="${TMPDIR:-/tmp}/tradeready-poor-network-tests"
MODULE_CACHE="${TMPDIR:-/tmp}/tradeready-poor-network-module-cache"

swiftc \
  -D GLOBAL_SEARCH_PURE_TESTS \
  -parse-as-library \
  -module-cache-path "$MODULE_CACHE" \
  $APPSTORE_TEST_SOURCES \
  "$ROOT_DIR/native/HostTestSupport/InMemorySupabase.swift" \
  "$ROOT_DIR/native/HostTestSupport/RecordingSignpostSink.swift" \
  "$ROOT_DIR/native/PoorNetworkTests/main.swift" \
  -o "$OUTPUT_PATH"

TZ="${TZ:-America/Phoenix}" "$OUTPUT_PATH"
