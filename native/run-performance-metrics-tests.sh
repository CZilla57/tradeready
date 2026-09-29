#!/bin/sh
set -eu

# Task 11.12 (H4): the performance signpost facade. Compiles
# N/NativePerformanceMetrics.swift (Foundation plus `os`) with the shared
# recording sink and source model, and drives: the interval catalog, the only
# allowed metadata shape (a clamped count and a fixed outcome word, never
# customer data, ids or keys; contract §10.1), begin/end pairing, launch
# measured once, the disabled and absent sink paths, the real OSSignposter
# sink on this host, and source scans over every N/ file (the facade is
# synchronous and transmits nothing; no other file emits signposts; call sites
# pass interval cases and counts only; the instrumented sites are exactly the
# pinned inventory). Device numbers are Phase 12
# (docs/native-phase-11-performance.md). Run with TZ=America/Phoenix (defaulted).
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUTPUT_PATH="${TMPDIR:-/tmp}/tradeready-performance-metrics-tests"
MODULE_CACHE="${TMPDIR:-/tmp}/tradeready-performance-metrics-module-cache"

swiftc \
  -parse-as-library \
  -module-cache-path "$MODULE_CACHE" \
  "$ROOT_DIR/native/TradeReadyNative/NativePerformanceMetrics.swift" \
  "$ROOT_DIR/native/HostTestSupport/RecordingSignpostSink.swift" \
  "$ROOT_DIR/native/HostTestSupport/SwiftSourceScan.swift" \
  "$ROOT_DIR/native/PerformanceMetricsTests/main.swift" \
  -o "$OUTPUT_PATH"

TZ="${TZ:-America/Phoenix}" "$OUTPUT_PATH" "$ROOT_DIR"
