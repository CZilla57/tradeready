#!/bin/sh
set -eu

# Phase 24 (card on file + autopay for recurring invoices, spec §6.3/§8): the
# pure NativeAutopay policy (status decoding, plan status and row text, the
# invoice banner, the plan editor's availability and notes, the refresh rule)
# and the NativeAutopayService owner-route transport against an injected
# loader. Executed west of UTC so a due date read in the process zone would
# shift a day (FA-039).
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUTPUT_PATH="${TMPDIR:-/tmp}/tradeready-autopay-tests"
MODULE_CACHE="${TMPDIR:-/tmp}/tradeready-autopay-module-cache"

swiftc \
  -parse-as-library \
  -module-cache-path "$MODULE_CACHE" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeAutopay.swift" \
  "$ROOT_DIR/native/TradeReadyNative/NativeAutopayService.swift" \
  "$ROOT_DIR/native/AutopayTests/main.swift" \
  -o "$OUTPUT_PATH"

TZ="${TZ:-America/Phoenix}" "$OUTPUT_PATH"
