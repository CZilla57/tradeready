#!/bin/sh
# Shared source list for the CSV import test runners. Sourced by the
# run-csv-import/import-mapping/import-engine/import-history runners.
IMPORT_TEST_SOURCES="
$ROOT_DIR/native/TradeReadyNative/Domain/CanonicalModels.swift
$ROOT_DIR/native/TradeReadyNative/Domain/FinancialDomain.swift
$ROOT_DIR/native/TradeReadyNative/Domain/NativeCashBasis.swift
$ROOT_DIR/native/TradeReadyNative/Domain/NativeCSVExport.swift
$ROOT_DIR/native/TradeReadyNative/Domain/NativeZipArchive.swift
$ROOT_DIR/native/TradeReadyNative/Domain/NativeAccountingPackage.swift
$ROOT_DIR/native/TradeReadyNative/Domain/NativeCSVImport.swift
$ROOT_DIR/native/TradeReadyNative/Domain/NativeImportMapping.swift
$ROOT_DIR/native/TradeReadyNative/Domain/NativeImportEngine.swift
$ROOT_DIR/native/TradeReadyNative/NativeImportHistory.swift
"
