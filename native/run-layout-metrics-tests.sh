#!/bin/sh
set -eu

# Task 11.11 (H2; contract §12.1 A11): iPad layouts, multitasking, rotation
# and hardware keyboard. Compiles the Foundation-only NativeLayoutMetrics
# policy (RN `layout.contentColumn`, 700pt; the SwiftUI modifiers in the same
# file are UIKit-only and excluded here) with the shared source model, and
# drives: the column width math for phone, iPad, Split View, Slide Over, Stage
# Manager and landscape safe areas; source scans over every N/ view (every
# List/Form/ScrollView screen root applies the column, fixed chrome is capped,
# one TabView and no pushed NavigationStack host, no UIScreen sizing or
# Slide-Over-breaking fixed widths, the keyboard shortcut policy); and the
# multitasking keys in native/Info.plist. Split View, Slide Over, Stage
# Manager, rotation and hardware-keyboard proof on a device stay Phase 12 rows.
# Run with TZ=America/Phoenix (defaulted).
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUTPUT_PATH="${TMPDIR:-/tmp}/tradeready-layout-metrics-tests"
MODULE_CACHE="${TMPDIR:-/tmp}/tradeready-layout-metrics-module-cache"

swiftc \
  -parse-as-library \
  -module-cache-path "$MODULE_CACHE" \
  "$ROOT_DIR/native/TradeReadyNative/NativeLayoutMetrics.swift" \
  "$ROOT_DIR/native/HostTestSupport/SwiftSourceScan.swift" \
  "$ROOT_DIR/native/LayoutMetricsTests/main.swift" \
  -o "$OUTPUT_PATH"

TZ="${TZ:-America/Phoenix}" "$OUTPUT_PATH" "$ROOT_DIR"
