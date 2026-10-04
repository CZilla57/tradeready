#!/bin/sh
set -eu

# Phase 19 (e-signatures with audit trail, spec 2026-10-03 §3.4, §3.7, §6
# "Native"): the snapshot additions and their caps, the settings round trip,
# approval decode with and without the server-owned keys, stroke scaling,
# audit-trail ordering, the legacy and on-site labels, the signed-record
# transport, the copy rules (no "legally binding"), and the AppStore wiring
# over the shared in-memory Supabase server: the review draft, the
# create-link payload, change orders and the owner's signed copy.
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$ROOT_DIR/native/run-appstore-sources-common.sh"
OUTPUT_PATH="${TMPDIR:-/tmp}/tradeready-esign-tests"
MODULE_CACHE="${TMPDIR:-/tmp}/tradeready-esign-module-cache"

swiftc \
  -D GLOBAL_SEARCH_PURE_TESTS \
  -parse-as-library \
  -module-cache-path "$MODULE_CACHE" \
  $APPSTORE_TEST_SOURCES \
  "$ROOT_DIR/native/HostTestSupport/InMemorySupabase.swift" \
  "$ROOT_DIR/native/ESignatureTests/main.swift" \
  -o "$OUTPUT_PATH"

TZ="${TZ:-America/Phoenix}" "$OUTPUT_PATH" "$ROOT_DIR"
