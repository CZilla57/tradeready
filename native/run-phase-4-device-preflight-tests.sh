#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
PREFLIGHT="$ROOT_DIR/native/run-phase-4-device-preflight.sh"
FIXTURES="$ROOT_DIR/native/Phase4DevicePreflightTests/fixtures"
OUTPUT_PATH="${TMPDIR:-/tmp}/tradeready-phase4-preflight-test-output"

expect_status() {
  expected_status=$1
  expected_text=$2
  shift 2

  set +e
  "$PREFLIGHT" "$@" >"$OUTPUT_PATH" 2>&1
  actual_status=$?
  set -e

  if [ "$actual_status" -ne "$expected_status" ]; then
    sed -n '1,240p' "$OUTPUT_PATH" >&2
    echo "Expected status $expected_status, got $actual_status" >&2
    exit 1
  fi

  if ! grep -F -q "$expected_text" "$OUTPUT_PATH"; then
    sed -n '1,240p' "$OUTPUT_PATH" >&2
    echo "Missing expected result: $expected_text" >&2
    exit 1
  fi
}

ready_args() {
  printf '%s\n' \
    --device-list "$FIXTURES/two-iphones.json" \
    --build-settings "$FIXTURES/ready-build-settings.txt" \
    --worker-config "$FIXTURES/ready-worker.toml" \
    --updated-at-verification "$FIXTURES/updated-at-passed.txt" \
    --payment-merge-verification "$FIXTURES/payment-merge-passed.txt"
}

# shellcheck disable=SC2046
expect_status 0 "READY: run docs/native-phase-4-device-runsheet.md" $(ready_args)

expect_status 2 "A second physical iPhone is required" \
  --device-list "$FIXTURES/one-iphone.json" \
  --build-settings "$FIXTURES/ready-build-settings.txt" \
  --worker-config "$FIXTURES/ready-worker.toml" \
  --updated-at-verification "$FIXTURES/updated-at-passed.txt" \
  --payment-merge-verification "$FIXTURES/payment-merge-passed.txt"

expect_status 2 "Configure the trusted HTTPS staging backend" \
  --device-list "$FIXTURES/two-iphones.json" \
  --build-settings "$FIXTURES/invalid-backend-build-settings.txt" \
  --worker-config "$FIXTURES/ready-worker.toml" \
  --updated-at-verification "$FIXTURES/updated-at-passed.txt" \
  --payment-merge-verification "$FIXTURES/payment-merge-passed.txt"

expect_status 2 "Provision a distinct, non-placeholder Supabase project" \
  --device-list "$FIXTURES/two-iphones.json" \
  --build-settings "$FIXTURES/ready-build-settings.txt" \
  --worker-config "$FIXTURES/placeholder-worker.toml" \
  --updated-at-verification "$FIXTURES/updated-at-passed.txt" \
  --payment-merge-verification "$FIXTURES/payment-merge-passed.txt"

expect_status 2 "Release Supabase URL or publishable key still matches production" \
  --device-list "$FIXTURES/two-iphones.json" \
  --build-settings "$FIXTURES/production-supabase-build-settings.txt" \
  --worker-config "$FIXTURES/placeholder-worker.toml" \
  --updated-at-verification "$FIXTURES/updated-at-passed.txt" \
  --payment-merge-verification "$FIXTURES/payment-merge-passed.txt"

expect_status 2 "Record the trusted-staging database-clock SQL verification output" \
  --device-list "$FIXTURES/two-iphones.json" \
  --build-settings "$FIXTURES/ready-build-settings.txt" \
  --worker-config "$FIXTURES/ready-worker.toml" \
  --payment-merge-verification "$FIXTURES/payment-merge-passed.txt"

expect_status 1 "Release Supabase does not match" \
  --device-list "$FIXTURES/two-iphones.json" \
  --build-settings "$FIXTURES/mismatched-supabase-build-settings.txt" \
  --worker-config "$FIXTURES/ready-worker.toml" \
  --updated-at-verification "$FIXTURES/updated-at-passed.txt" \
  --payment-merge-verification "$FIXTURES/payment-merge-passed.txt"

expect_status 1 "Release production Supabase guard must match" \
  --device-list "$FIXTURES/two-iphones.json" \
  --build-settings "$FIXTURES/mismatched-production-guard-build-settings.txt" \
  --worker-config "$FIXTURES/ready-worker.toml" \
  --updated-at-verification "$FIXTURES/updated-at-passed.txt" \
  --payment-merge-verification "$FIXTURES/payment-merge-passed.txt"

expect_status 1 "Release production publishable-key guard must match" \
  --device-list "$FIXTURES/two-iphones.json" \
  --build-settings "$FIXTURES/mismatched-production-key-build-settings.txt" \
  --worker-config "$FIXTURES/ready-worker.toml" \
  --updated-at-verification "$FIXTURES/updated-at-passed.txt" \
  --payment-merge-verification "$FIXTURES/payment-merge-passed.txt"

expect_status 1 "Release Supabase URL and publishable key must not match production" \
  --device-list "$FIXTURES/two-iphones.json" \
  --build-settings "$FIXTURES/production-supabase-build-settings.txt" \
  --worker-config "$FIXTURES/ready-worker.toml" \
  --updated-at-verification "$FIXTURES/updated-at-passed.txt" \
  --payment-merge-verification "$FIXTURES/payment-merge-passed.txt"

echo "Phase 4 device preflight tests passed."
