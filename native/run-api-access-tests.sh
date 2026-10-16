#!/bin/sh
set -eu

# Roadmap Phase 23 (open-API spec §9, §10 "Native"): Settings › API access
# domain rules, the manage transport, the view model and source guards. The
# AppStore-bound `NativeAPIAccessStore.swift` and the SwiftUI view are not
# compiled here (the Release compile covers them); the suite reads them as
# text for the source guards.

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUTPUT_PATH="${TMPDIR:-/tmp}/tradeready-api-access-tests"
MODULE_CACHE="${TMPDIR:-/tmp}/tradeready-api-access-module-cache"

swiftc \
  -parse-as-library \
  -module-cache-path "$MODULE_CACHE" \
  "$ROOT_DIR/native/TradeReadyNative/BuildEnvironment.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeAPIAccess.swift" \
  "$ROOT_DIR/native/TradeReadyNative/NativeAPIKeyAdministration.swift" \
  "$ROOT_DIR/native/TradeReadyNative/NativeAPIAccessModel.swift" \
  "$ROOT_DIR/native/HostTestSupport/SwiftSourceScan.swift" \
  "$ROOT_DIR/native/APIAccessTests/main.swift" \
  -o "$OUTPUT_PATH"

"$OUTPUT_PATH" "$ROOT_DIR"
