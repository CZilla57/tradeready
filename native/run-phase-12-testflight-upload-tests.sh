#!/bin/sh
# Host tests for native/phase-12-testflight-upload.sh. A PATH shim replaces
# xcodebuild and xcrun with recorders so every test can prove whether the
# script invoked either one, without ever taking the real archive/export/
# upload path (never exercised here — task 14 brief).
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
UPLOAD="$ROOT_DIR/native/phase-12-testflight-upload.sh"
OUTPUT_PATH="${TMPDIR:-/tmp}/tradeready-phase12-upload-test-output"

TEMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/tradeready-phase12-upload-tests.XXXXXX")
trap 'rm -rf "$TEMP_ROOT"' EXIT HUP INT TERM

SHIM_DIR="$TEMP_ROOT/shim"
SHIM_LOG="$TEMP_ROOT/shim-invocations.log"
mkdir -p "$SHIM_DIR"
: >"$SHIM_LOG"

for tool in xcodebuild xcrun; do
  cat >"$SHIM_DIR/$tool" <<EOF
#!/bin/sh
echo "$tool \$*" >>"$SHIM_LOG"
exit 0
EOF
  chmod +x "$SHIM_DIR/$tool"
done

run_with_shim() {
  PATH="$SHIM_DIR:$PATH" "$@"
}

assert_no_invocation() {
  label=$1
  if [ -s "$SHIM_LOG" ]; then
    echo "FAIL ($label): expected no xcodebuild/xcrun invocation, but the shim log has:" >&2
    cat "$SHIM_LOG" >&2
    exit 1
  fi
}

reset_log() {
  : >"$SHIM_LOG"
}

# 1. Dry run (default) invokes neither xcodebuild nor xcrun, exits 0, and
#    prints the three commands plus a preview plist, without running them.
reset_log
set +e
run_with_shim "$UPLOAD" --version 2.0.0 --build 42 >"$OUTPUT_PATH" 2>&1
status=$?
set -e
if [ "$status" -ne 0 ]; then
  sed -n '1,200p' "$OUTPUT_PATH" >&2
  echo "Expected dry run to exit 0, got $status" >&2
  exit 1
fi
if ! grep -F -q "DRY RUN" "$OUTPUT_PATH"; then
  sed -n '1,200p' "$OUTPUT_PATH" >&2
  echo "Expected a DRY RUN banner" >&2
  exit 1
fi
if ! grep -F -q "app-store-connect" "$OUTPUT_PATH"; then
  echo "Expected the preview ExportOptions.plist content (method app-store-connect)" >&2
  exit 1
fi
if ! grep -F -q "xcodebuild -project" "$OUTPUT_PATH"; then
  echo "Expected the archive command to be printed" >&2
  exit 1
fi
if ! grep -F -q "xcodebuild -exportArchive" "$OUTPUT_PATH"; then
  echo "Expected the export command to be printed" >&2
  exit 1
fi
assert_no_invocation "dry run"

# 2. --execute with no credential env vars set: refuses, exit 3, invokes neither.
reset_log
set +e
env -u ASC_KEY_ID -u ASC_ISSUER_ID -u ASC_KEY_PATH \
  sh -c 'PATH="'"$SHIM_DIR"':$PATH" "'"$UPLOAD"'" --version 2.0.0 --build 42 --execute' \
  >"$OUTPUT_PATH" 2>&1
status=$?
set -e
if [ "$status" -ne 3 ]; then
  sed -n '1,200p' "$OUTPUT_PATH" >&2
  echo "Expected --execute with no credentials to exit 3, got $status" >&2
  exit 1
fi
if ! grep -F -q "credentials absent — owner-run" "$OUTPUT_PATH"; then
  sed -n '1,200p' "$OUTPUT_PATH" >&2
  echo "Expected the exact refusal message" >&2
  exit 1
fi
assert_no_invocation "--execute, no credentials"

# 3. --execute with dummy credential env vars but no --i-am-the-owner:
#    still refuses, exit 3, invokes neither. Dummy values only — never a
#    real key, issuer or path.
reset_log
set +e
env ASC_KEY_ID=fixture-key-id ASC_ISSUER_ID=fixture-issuer-id ASC_KEY_PATH=/dev/null \
  sh -c 'PATH="'"$SHIM_DIR"':$PATH" "'"$UPLOAD"'" --version 2.0.0 --build 42 --execute' \
  >"$OUTPUT_PATH" 2>&1
status=$?
set -e
if [ "$status" -ne 3 ]; then
  sed -n '1,200p' "$OUTPUT_PATH" >&2
  echo "Expected --execute without --i-am-the-owner to exit 3, got $status" >&2
  exit 1
fi
if ! grep -F -q "credentials absent — owner-run" "$OUTPUT_PATH"; then
  sed -n '1,200p' "$OUTPUT_PATH" >&2
  echo "Expected the exact refusal message" >&2
  exit 1
fi
if ! grep -F -q -- "--i-am-the-owner was not passed." "$OUTPUT_PATH"; then
  sed -n '1,200p' "$OUTPUT_PATH" >&2
  echo "Expected the missing --i-am-the-owner note" >&2
  exit 1
fi
if grep -F -q "fixture-key-id" "$OUTPUT_PATH" || grep -F -q "fixture-issuer-id" "$OUTPUT_PATH"; then
  echo "The refusal message must never echo a credential value, even a fixture one" >&2
  exit 1
fi
assert_no_invocation "--execute, credentials but no --i-am-the-owner"

# 4. Missing required arguments is a usage error (exit 64), not a silent
#    dry run, and does not invoke either tool.
reset_log
set +e
run_with_shim "$UPLOAD" --version 2.0.0 >"$OUTPUT_PATH" 2>&1
status=$?
set -e
if [ "$status" -ne 64 ]; then
  sed -n '1,200p' "$OUTPUT_PATH" >&2
  echo "Expected a missing --build to exit 64, got $status" >&2
  exit 1
fi
assert_no_invocation "missing --build"

# 5. Sentry DSN pass-through. The real path is never run here, so this checks
#    the dry-run note (variable name only, never the value) and, by source
#    check, that the archive command forwards the setting.
reset_log
set +e
env TRADEREADY_SENTRY_DSN=https://fixture-key@example.invalid/1 \
  sh -c 'PATH="'"$SHIM_DIR"':$PATH" "'"$UPLOAD"'" --version 2.0.0 --build 42' \
  >"$OUTPUT_PATH" 2>&1
status=$?
set -e
if [ "$status" -ne 0 ] || ! grep -F -q "variable is set; value not shown" "$OUTPUT_PATH"; then
  sed -n '1,200p' "$OUTPUT_PATH" >&2
  echo "Expected the dry run to note that TRADEREADY_SENTRY_DSN is set" >&2
  exit 1
fi
if grep -F -q "fixture-key@example.invalid" "$OUTPUT_PATH"; then
  echo "The dry run must never echo the DSN value" >&2
  exit 1
fi
assert_no_invocation "dry run with DSN"

reset_log
env -u TRADEREADY_SENTRY_DSN \
  sh -c 'PATH="'"$SHIM_DIR"':$PATH" "'"$UPLOAD"'" --version 2.0.0 --build 42' \
  >"$OUTPUT_PATH" 2>&1
if ! grep -F -q "TRADEREADY_SENTRY_DSN is NOT set" "$OUTPUT_PATH"; then
  sed -n '1,200p' "$OUTPUT_PATH" >&2
  echo "Expected the dry run to warn that TRADEREADY_SENTRY_DSN is not set" >&2
  exit 1
fi
assert_no_invocation "dry run without DSN"

if ! grep -F -q 'set -- "$@" TRADEREADY_SENTRY_DSN="$TRADEREADY_SENTRY_DSN"' "$UPLOAD"; then
  echo "Expected the --execute archive command to forward TRADEREADY_SENTRY_DSN" >&2
  exit 1
fi

echo "Phase 12 TestFlight upload helper tests passed."
