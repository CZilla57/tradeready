#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUTPUT_PATH="${TMPDIR:-/tmp}/tradeready-route-planning-tests"
MODULE_CACHE="${TMPDIR:-/tmp}/tradeready-route-planning-swift-module-cache"

swiftc \
  -module-cache-path "$MODULE_CACHE" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeRoutePlanning.swift" \
  "$ROOT_DIR/native/TradeReadyNative/NativeRouteMapService.swift" \
  "$ROOT_DIR/native/RoutePlanningTests/main.swift" \
  -o "$OUTPUT_PATH"

"$OUTPUT_PATH"
