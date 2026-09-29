#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUTPUT_PATH="${TMPDIR:-/tmp}/tradeready-auxiliary-activation-tests"
MODULE_CACHE="${TMPDIR:-/tmp}/tradeready-auxiliary-activation-module-cache"

swiftc \
  -parse-as-library \
  -module-cache-path "$MODULE_CACHE" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/FinancialDomain.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/BusinessRules.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/CanonicalModels.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/CanonicalSnapshot.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/SnapshotRepository.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Models.swift" \
  "$ROOT_DIR/native/TradeReadyNative/NativeJobList.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/JobInvoiceDomain.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/UIModelAdapters.swift" \
  "$ROOT_DIR/native/TradeReadyNative/LegacyDataImporter.swift" \
  "$ROOT_DIR/native/TradeReadyNative/LegacyMigrationCoordinator.swift" \
  "$ROOT_DIR/native/TradeReadyNative/NativeAccountBoundaryStepRecord.swift" \
  "$ROOT_DIR/native/TradeReadyNative/NativeAuxiliaryStateActivation.swift" \
  "$ROOT_DIR/native/AuxiliaryActivationTests/main.swift" \
  -o "$OUTPUT_PATH"

"$OUTPUT_PATH"
