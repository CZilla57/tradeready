#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUTPUT_PATH="${TMPDIR:-/tmp}/tradeready-legacy-migration-retention-tests"
MODULE_CACHE="${TMPDIR:-/tmp}/tradeready-legacy-migration-retention-module-cache"

# Phase 12, task 13 (12.01), requirement SC4: fails if the legacy migration
# path (LegacyMigrationCoordinator, the AsyncStorage reader, or the AppStore
# launch-path wiring) is removed or unwired. This never runs the migration
# itself (no Keychain or legacy-backup I/O), so it passes with the console
# locked (ruling R53).
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
  "$ROOT_DIR/native/LegacyMigrationRetentionTests/main.swift" \
  -o "$OUTPUT_PATH"

TRADEREADY_ROOT_DIR="$ROOT_DIR" "$OUTPUT_PATH"
