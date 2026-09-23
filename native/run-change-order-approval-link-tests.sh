#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUTPUT_PATH="${TMPDIR:-/tmp}/tradeready-change-order-approval-link-tests"
MODULE_CACHE="${TMPDIR:-/tmp}/tradeready-change-order-approval-link-module-cache"

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
  "$ROOT_DIR/native/TradeReadyNative/NativeChangeOrders.swift" \
  "$ROOT_DIR/native/TradeReadyNative/NativeChangeOrderApprovalLink.swift" \
  "$ROOT_DIR/native/ChangeOrderApprovalLinkTests/main.swift" \
  -o "$OUTPUT_PATH"

"$OUTPUT_PATH"
