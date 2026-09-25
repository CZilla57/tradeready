#!/bin/sh
set -eu

# Task 11.13: Phase 11 cross-client and platform qualification. Compiles the
# AppStore closure plus the RN widget and Siri snapshot decoders, extracted
# from the WORKING TREE of targets/ (never copied into native/, never edited),
# so a drift in RN's decoder shape fails this suite instead of a stale copy.
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$ROOT_DIR/native/run-appstore-sources-common.sh"
OUTPUT_PATH="${TMPDIR:-/tmp}/tradeready-phase11-qualification-tests"
MODULE_CACHE="${TMPDIR:-/tmp}/tradeready-phase11-qualification-module-cache"
RN_DECODERS="${TMPDIR:-/tmp}/tradeready-phase11-rn-decoders.swift"

{
  echo "import Foundation"
  echo "// Extracted by run-phase11-qualification-tests.sh; do not edit."
  awk '/^struct BridgeSnapshot: Decodable \{/{p=1} p{print} p&&/^\}/{exit}' \
    "$ROOT_DIR/targets/widget/Widgets.swift"
  awk '/^private struct SiriSnapshot: Decodable \{/{p=1} p{print} p&&/^\}/{exit}' \
    "$ROOT_DIR/targets/widget/_shared/SiriIntents.swift" | sed 's/^private struct SiriSnapshot/struct SiriSnapshot/'
} > "$RN_DECODERS"

for DECODER in "struct BridgeSnapshot: Decodable {" "struct SiriSnapshot: Decodable {"; do
  if ! grep -Fq "$DECODER" "$RN_DECODERS"; then
    echo "run-phase11-qualification-tests.sh: RN decoder not found in targets/: $DECODER" >&2
    exit 1
  fi
done

swiftc \
  -D GLOBAL_SEARCH_PURE_TESTS \
  -parse-as-library \
  -module-cache-path "$MODULE_CACHE" \
  $APPSTORE_TEST_SOURCES \
  "$ROOT_DIR/native/HostTestSupport/SwiftSourceScan.swift" \
  "$RN_DECODERS" \
  "$ROOT_DIR/native/Phase11QualificationTests/main.swift" \
  -o "$OUTPUT_PATH"

"$OUTPUT_PATH" "$ROOT_DIR"
