#!/bin/sh
set -eu

# Task 11.15 (P4, R2; contract §11, C19): Settings › AI Assistant advanced key
# entry. Compiles the AppStore closure (which includes the key policy and the
# secure-store extension) and drives: the pure policy (RN copy, trim and shape
# validation, save/clear outcome, masked display, transport precedence); the
# existing NativeKeychainSecureSettingsStore over an in-memory backing (save,
# clear, read-back verification, owner wipe); the real AppStore wiring
# (provider summary and coach routing after save/clear, sign-out and deletion
# scrub wipes); and the redaction/storage proof (analytics transport, crash
# reports and redacted crash events, UserDefaults, the App Group suite, the
# widget snapshot and the business-data files never hold an entered key). The
# system Keychain is never touched. Run with TZ=America/Phoenix (defaulted).
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$ROOT_DIR/native/run-appstore-sources-common.sh"
OUTPUT_PATH="${TMPDIR:-/tmp}/tradeready-ai-provider-key-tests"
MODULE_CACHE="${TMPDIR:-/tmp}/tradeready-ai-provider-key-module-cache"

swiftc \
  -D GLOBAL_SEARCH_PURE_TESTS \
  -parse-as-library \
  -module-cache-path "$MODULE_CACHE" \
  $APPSTORE_TEST_SOURCES \
  "$ROOT_DIR/native/AIProviderKeyTests/main.swift" \
  -o "$OUTPUT_PATH"

TZ="${TZ:-America/Phoenix}" "$OUTPUT_PATH" "$ROOT_DIR"
