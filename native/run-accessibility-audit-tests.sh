#!/bin/sh
set -eu

# Task 11.10a (H1; contract §12 "Accessibility baseline (H1)" and its 11.10a
# follow-up): accessibility audit and remediation. Compiles the pure
# NativeAccessibilityAudit policy (WCAG contrast math, the app palette, the
# Reduce Motion policy and the RN-parity label catalog) and drives: every
# contrast pairing the dark-mode tint and fill rely on; the palette literals
# shipped in N/Models.swift and the AccentColor asset; RN label parity against
# the working-tree screens; and source scans over every N/ view (no unlabeled
# icon-only control, every custom animation honors Reduce Motion, no
# fixed-point fonts outside the widget views, no white text on the dark tint,
# the fixed-frame, touch-target and focus-order fixes). VoiceOver order, AX5
# layout and Switch Control remain Phase 12 device rows.
# Run with TZ=America/Phoenix (defaulted).
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUTPUT_PATH="${TMPDIR:-/tmp}/tradeready-accessibility-audit-tests"
MODULE_CACHE="${TMPDIR:-/tmp}/tradeready-accessibility-audit-module-cache"

swiftc \
  -parse-as-library \
  -module-cache-path "$MODULE_CACHE" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeAccessibilityAudit.swift" \
  "$ROOT_DIR/native/HostTestSupport/SwiftSourceScan.swift" \
  "$ROOT_DIR/native/AccessibilityAuditTests/main.swift" \
  -o "$OUTPUT_PATH"

TZ="${TZ:-America/Phoenix}" "$OUTPUT_PATH" "$ROOT_DIR"
