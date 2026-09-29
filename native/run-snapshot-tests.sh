#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUTPUT_PATH="${TMPDIR:-/tmp}/tradeready-snapshot-tests"
MODULE_CACHE="${TMPDIR:-/tmp}/tradeready-swift-snapshot-module-cache"

swiftc \
  -module-cache-path "$MODULE_CACHE" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/CanonicalModels.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/CanonicalSnapshot.swift" \
  "$ROOT_DIR/native/SnapshotTests/main.swift" \
  -o "$OUTPUT_PATH"

SNAPSHOT_FIXTURES_PATH="$ROOT_DIR/native/SnapshotTests/Fixtures" \
CANONICAL_FIXTURES_PATH="$ROOT_DIR/native/CanonicalTests/Fixtures" \
"$OUTPUT_PATH"
