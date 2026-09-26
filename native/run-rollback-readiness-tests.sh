#!/bin/sh
set -eu

# Phase 12 (12.06, charter §6 item 2): the rollback-readiness check. Before
# support advises installing the Expo rollback build, "Check everything is
# saved" (Settings > Cloud Sync) forces a push pass and reports whether the
# account is safe to roll back: queue, I2 rejected store, widget/Siri replay
# queue, photo uploads, booking/portal link work and the migration journal. It fails closed with
# nothing sent, and an account change during its await voids the result.
# The real AppStore, sync coordinator, push transport and widget claim
# transport run in front of the shared in-memory server. No network.
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$ROOT_DIR/native/run-appstore-sources-common.sh"
OUTPUT_PATH="${TMPDIR:-/tmp}/tradeready-rollback-readiness-tests"
MODULE_CACHE="${TMPDIR:-/tmp}/tradeready-rollback-readiness-module-cache"

swiftc \
  -D GLOBAL_SEARCH_PURE_TESTS \
  -parse-as-library \
  -module-cache-path "$MODULE_CACHE" \
  $APPSTORE_TEST_SOURCES \
  "$ROOT_DIR/native/HostTestSupport/InMemorySupabase.swift" \
  "$ROOT_DIR/native/RollbackReadinessTests/main.swift" \
  -o "$OUTPUT_PATH"

TZ="${TZ:-America/Phoenix}" "$OUTPUT_PATH" "$ROOT_DIR"
