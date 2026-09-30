#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUTPUT_PATH="${TMPDIR:-/tmp}/tradeready-logo-media-tests"
MODULE_CACHE="${TMPDIR:-/tmp}/tradeready-logo-media-module-cache"

swiftc \
  -module-cache-path "$MODULE_CACHE" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeLogoMedia.swift" \
  "$ROOT_DIR/native/LogoMediaTests/main.swift" \
  -o "$OUTPUT_PATH"

"$OUTPUT_PATH"
