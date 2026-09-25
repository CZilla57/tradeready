#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUTPUT_PATH="${TMPDIR:-/tmp}/tradeready-migration-coordinator-tests"
MODULE_CACHE="${TMPDIR:-/tmp}/tradeready-migration-coordinator-module-cache"

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
  "$ROOT_DIR/native/MigrationCoordinatorTests/main.swift" \
  -o "$OUTPUT_PATH"

CANONICAL_FIXTURES_PATH="$ROOT_DIR/native/CanonicalTests/Fixtures" "$OUTPUT_PATH"
