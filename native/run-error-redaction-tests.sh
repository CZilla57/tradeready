#!/bin/sh
set -eu

# Task 11.09 (§10.1-§10.3, C12, C18): crash reporting and redaction. Compiles
# the AppStore closure (which includes N/NativeErrorRedaction.swift and
# N/NativeCrashReporting.swift) and drives NativeCrashReporter over recording
# fake SDK adapters: every §10.1 deny class across event, breadcrumb, extra,
# exception and span payloads, the reportError wrapper, the §10.2 gate and
# options, setUser at every identity boundary, a throwing and a slow adapter,
# the sync call sites, and the linkage / manifest source checks. The Sentry
# SDK is never compiled or linked here. Run with TZ=America/Phoenix
# (defaulted below).
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$ROOT_DIR/native/run-appstore-sources-common.sh"
OUTPUT_PATH="${TMPDIR:-/tmp}/tradeready-error-redaction-tests"
MODULE_CACHE="${TMPDIR:-/tmp}/tradeready-error-redaction-module-cache"

swiftc \
  -D GLOBAL_SEARCH_PURE_TESTS \
  -parse-as-library \
  -module-cache-path "$MODULE_CACHE" \
  $APPSTORE_TEST_SOURCES \
  "$ROOT_DIR/native/ErrorRedactionTests/main.swift" \
  -o "$OUTPUT_PATH"

TZ="${TZ:-America/Phoenix}" "$OUTPUT_PATH" "$ROOT_DIR"
