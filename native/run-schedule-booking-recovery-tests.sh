#!/bin/sh
set -eu

# Phase 12 (12.00b.2-I, P12-013): unfinished booking and portal work after a
# relaunch. A booking-link or portal-link change the server made while the
# local save failed, and a reschedule proof, are staged in the plan 8.08
# pending-work store. Each case stages its item through the real flow,
# relaunches a fresh AppStore on the same files and activates it. The real
# AppStore, sync coordinator, push transport and delta pull run in front of
# the shared in-memory server; the real booking-admin, portal-manage and
# booking-respond clients run in front of a stateful stand-in. No network.
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$ROOT_DIR/native/run-appstore-sources-common.sh"
OUTPUT_PATH="${TMPDIR:-/tmp}/tradeready-schedule-booking-recovery-tests"
MODULE_CACHE="${TMPDIR:-/tmp}/tradeready-schedule-booking-recovery-module-cache"

swiftc \
  -D GLOBAL_SEARCH_PURE_TESTS \
  -parse-as-library \
  -module-cache-path "$MODULE_CACHE" \
  $APPSTORE_TEST_SOURCES \
  "$ROOT_DIR/native/HostTestSupport/InMemorySupabase.swift" \
  "$ROOT_DIR/native/ScheduleBookingRecoveryTests/main.swift" \
  -o "$OUTPUT_PATH"

TZ="${TZ:-America/Phoenix}" "$OUTPUT_PATH" "$ROOT_DIR"
