#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUTPUT_PATH="${TMPDIR:-/tmp}/tradeready-canonical-tests"
MODULE_CACHE="${TMPDIR:-/tmp}/tradeready-swift-canonical-module-cache"

set -- "$ROOT_DIR"/native/TradeReadyNative/Domain/Canonical*.swift
if [ ! -f "$1" ]; then
  echo "Canonical model sources were not found." >&2
  exit 1
fi

swiftc \
  -module-cache-path "$MODULE_CACHE" \
  "$@" \
  "$ROOT_DIR/native/CanonicalTests/main.swift" \
  -o "$OUTPUT_PATH"

CANONICAL_FIXTURES_PATH="$ROOT_DIR/native/CanonicalTests/Fixtures" "$OUTPUT_PATH"
