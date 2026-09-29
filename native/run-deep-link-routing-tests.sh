#!/bin/sh
set -eu

# Task 11.06 (L1, L2): cold and warm deep-link routing with authentication
# gates. Compiles the AppStore closure (`handle(url:)`, the stash consumer,
# the gate didSet, `useAnotherAccount`) plus the pure routing policy and the
# intent router, so every fixture runs against the real code on a throwaway
# App Group suite and lock file. Run with TZ=America/Phoenix.
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$ROOT_DIR/native/run-appstore-sources-common.sh"
OUTPUT_PATH="${TMPDIR:-/tmp}/tradeready-deep-link-routing-tests"
MODULE_CACHE="${TMPDIR:-/tmp}/tradeready-deep-link-routing-module-cache"

swiftc \
  -D GLOBAL_SEARCH_PURE_TESTS \
  -parse-as-library \
  -module-cache-path "$MODULE_CACHE" \
  $APPSTORE_TEST_SOURCES \
  "$ROOT_DIR/native/TradeReadyNative/Widgets/Shared/WidgetActionQueue.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Intents/NativeIntentURLRouter.swift" \
  "$ROOT_DIR/native/DeepLinkRoutingTests/main.swift" \
  -o "$OUTPUT_PATH"

TZ="${TZ:-America/Phoenix}" "$OUTPUT_PATH"
