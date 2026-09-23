#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUTPUT_PATH="${TMPDIR:-/tmp}/tradeready-estimate-approval-link-tests"
MODULE_CACHE="${TMPDIR:-/tmp}/tradeready-estimate-approval-link-module-cache"

swiftc \
  -parse-as-library \
  -module-cache-path "$MODULE_CACHE" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/FinancialDomain.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/BusinessRules.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/CanonicalModels.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Models.swift" \
  "$ROOT_DIR/native/TradeReadyNative/NativeJobList.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/JobInvoiceDomain.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/UIModelAdapters.swift" \
  "$ROOT_DIR/native/TradeReadyNative/NativeEstimateApprovalLink.swift" \
  "$ROOT_DIR/native/EstimateApprovalLinkTests/main.swift" \
  -o "$OUTPUT_PATH"

CANONICAL_FIXTURE="$ROOT_DIR/native/CanonicalTests/Fixtures/canonical-rich.json" "$OUTPUT_PATH"
