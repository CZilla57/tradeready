#!/bin/sh
set -eu

# Phase 20 (custom job / inspection forms): the pure domain
# (Domain/NativeJobForms.swift) over the canonical models, the forms screens'
# state rules (Domain/NativeJobFormsPresentation.swift) and the PDF report's
# document model (NativeFormPDF.swift; its UIKit renderer is iOS-only). The
# AppStore wiring runs in run-store-integration-tests.sh.
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUTPUT_PATH="${TMPDIR:-/tmp}/tradeready-job-forms-tests"
MODULE_CACHE="${TMPDIR:-/tmp}/tradeready-job-forms-module-cache"

swiftc \
  -module-cache-path "$MODULE_CACHE" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/CanonicalModels.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeJobForms.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeJobFormsPresentation.swift" \
  "$ROOT_DIR/native/TradeReadyNative/NativeFormPDF.swift" \
  "$ROOT_DIR/native/JobFormsTests/main.swift" \
  -o "$OUTPUT_PATH"

CANONICAL_FIXTURE="$ROOT_DIR/native/CanonicalTests/Fixtures/canonical-rich.json" \
  "$OUTPUT_PATH"
