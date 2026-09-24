#!/bin/sh
# Task 11.09 (contract §10.2): upload an archive's dSYMs to Sentry so native
# crash stacks symbolicate. Run by hand on a Release archive (Phase 12
# runsheet); it is deliberately NOT an Xcode run-script build phase.
#
# Usage:
#   SENTRY_AUTH_TOKEN=... sh native/scripts/upload-sentry-dsyms.sh <path/to/App.xcarchive | dSYMs dir>
#
# Environment:
#   SENTRY_AUTH_TOKEN  required; never committed. Absent -> clean no-op.
#   SENTRY_ORG         defaults to tradeready-3r.
#   SENTRY_PROJECT     defaults to tradeready-ios (the native project; the RN
#                      app reports to react-native). Set it empty to no-op.
#   SENTRY_CLI         sentry-cli binary (default: sentry-cli on PATH).
#
# Exit codes: 0 uploaded or cleanly skipped; 1 usage/input error; otherwise
# sentry-cli's own status.
set -eu

ORG="${SENTRY_ORG:-tradeready-3r}"
PROJECT="${SENTRY_PROJECT-tradeready-ios}"
CLI="${SENTRY_CLI:-sentry-cli}"

if [ -z "${SENTRY_AUTH_TOKEN:-}" ]; then
  echo "upload-sentry-dsyms: SENTRY_AUTH_TOKEN is not set; skipping dSYM upload (nothing sent)."
  exit 0
fi
if [ -z "$PROJECT" ]; then
  echo "upload-sentry-dsyms: SENTRY_PROJECT is empty; skipping dSYM upload (nothing sent)."
  exit 0
fi
if [ -z "$ORG" ]; then
  echo "upload-sentry-dsyms: SENTRY_ORG is empty; skipping dSYM upload (nothing sent)."
  exit 0
fi

if [ "$#" -ne 1 ]; then
  echo "usage: sh native/scripts/upload-sentry-dsyms.sh <App.xcarchive | dSYMs directory>" >&2
  exit 1
fi

INPUT="$1"
if [ -d "$INPUT/dSYMs" ]; then
  DSYMS="$INPUT/dSYMs"
elif [ -d "$INPUT" ]; then
  DSYMS="$INPUT"
else
  echo "upload-sentry-dsyms: '$INPUT' is not an archive or a directory." >&2
  exit 1
fi

if ! find "$DSYMS" -maxdepth 2 -name '*.dSYM' | grep -q .; then
  echo "upload-sentry-dsyms: no .dSYM bundles under '$DSYMS'." >&2
  exit 1
fi

if ! command -v "$CLI" >/dev/null 2>&1; then
  echo "upload-sentry-dsyms: '$CLI' not found; install sentry-cli (brew install getsentry/tools/sentry-cli)." >&2
  exit 1
fi

echo "upload-sentry-dsyms: uploading dSYMs from '$DSYMS' to $ORG/$PROJECT."
# The token reaches sentry-cli through the environment only, never argv.
exec "$CLI" debug-files upload --org "$ORG" --project "$PROJECT" --include-sources "$DSYMS"
