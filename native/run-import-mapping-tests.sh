#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$ROOT_DIR/native/run-import-tests-common.sh"

swiftc \
  -module-cache-path "${TMPDIR:-/tmp}/tradeready-import-module-cache" \
  $IMPORT_TEST_SOURCES \
  "$ROOT_DIR/native/ImportMappingTests/main.swift" \
  -o "${TMPDIR:-/tmp}/tradeready-import-mapping-tests"

"${TMPDIR:-/tmp}/tradeready-import-mapping-tests"
