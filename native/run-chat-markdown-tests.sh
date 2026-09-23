#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUTPUT_PATH="${TMPDIR:-/tmp}/tradeready-chat-markdown-tests"
MODULE_CACHE="${TMPDIR:-/tmp}/tradeready-chat-markdown-module-cache"

swiftc \
  -module-cache-path "$MODULE_CACHE" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeChatMarkdown.swift" \
  "$ROOT_DIR/native/ChatMarkdownTests/main.swift" \
  -o "$OUTPUT_PATH"

"$OUTPUT_PATH"
