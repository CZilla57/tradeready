#!/bin/sh
set -eu

# Phase 33 (customer tags and the marketing opt-out): the pure tag, opt-out
# and list-filter rules (Domain/NativeCustomerTags.swift) plus the CSV import
# mapping and engine for the tags and opt-out columns and the accountant
# package's two customer columns. Spec:
# docs/superpowers/specs/2026-10-03-campaigns-tags-design.md §3, §4, §12.
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$ROOT_DIR/native/run-import-tests-common.sh"
OUTPUT_PATH="${TMPDIR:-/tmp}/tradeready-customer-tags-tests"
MODULE_CACHE="${TMPDIR:-/tmp}/tradeready-customer-tags-module-cache"

swiftc \
  -module-cache-path "$MODULE_CACHE" \
  $IMPORT_TEST_SOURCES \
  "$ROOT_DIR/native/CustomerTagsTests/main.swift" \
  -o "$OUTPUT_PATH"

TZ="${TZ:-America/Phoenix}" "$OUTPUT_PATH"
