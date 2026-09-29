#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
PREFLIGHT="$ROOT_DIR/native/run-phase-3-device-preflight.sh"
FIXTURES="$ROOT_DIR/native/Phase3DevicePreflightTests/fixtures"
OUTPUT_PATH="${TMPDIR:-/tmp}/tradeready-phase3-preflight-test-output"

expect_status() {
  expected_status=$1
  expected_text=$2
  shift 2

  set +e
  "$PREFLIGHT" "$@" >"$OUTPUT_PATH" 2>&1
  actual_status=$?
  set -e

  if [ "$actual_status" -ne "$expected_status" ]; then
    sed -n '1,200p' "$OUTPUT_PATH" >&2
    echo "Expected status $expected_status, got $actual_status" >&2
    exit 1
  fi

  if ! grep -F -q "$expected_text" "$OUTPUT_PATH"; then
    sed -n '1,200p' "$OUTPUT_PATH" >&2
    echo "Missing expected result: $expected_text" >&2
    exit 1
  fi
}

expect_status 0 "READY: run the signed-device matrix" \
  --device-list "$FIXTURES/ready-device.json" \
  --build-settings "$FIXTURES/ready-build-settings.txt"

expect_status 2 "Connect and trust a physical iPhone" \
  --device-list "$FIXTURES/no-iphone.json" \
  --build-settings "$FIXTURES/ready-build-settings.txt"

expect_status 2 "Configure the production HTTPS backend" \
  --device-list "$FIXTURES/ready-device.json" \
  --build-settings "$FIXTURES/invalid-backend-build-settings.txt"

expect_status 0 "NOTE: R59 (no staging): Release writes to the production backend" \
  --device-list "$FIXTURES/ready-device.json" \
  --build-settings "$FIXTURES/ready-build-settings.txt"

# A build still configured as staging (writes off) is no longer the R59 Release.
expect_status 1 "Release must use the production configuration" \
  --device-list "$FIXTURES/ready-device.json" \
  --build-settings "$FIXTURES/staging-environment-build-settings.txt"

expect_status 1 "Release must enable production writes under R59" \
  --device-list "$FIXTURES/ready-device.json" \
  --build-settings "$FIXTURES/staging-environment-build-settings.txt"

expect_status 1 "Release backend must be the production Worker origin" \
  --device-list "$FIXTURES/ready-device.json" \
  --build-settings "$FIXTURES/wrong-backend-build-settings.txt"

expect_status 1 "Release Supabase project and key must be the production project" \
  --device-list "$FIXTURES/ready-device.json" \
  --build-settings "$FIXTURES/wrong-supabase-build-settings.txt"

echo "Phase 3 device preflight tests passed."

