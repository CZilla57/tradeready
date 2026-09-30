#!/bin/sh
# Registration guard, split out of run-all-domain-tests.sh so CI can run it on its own.
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

# Registration guard (Phase 10 final review I3): every native/run-*-tests.sh
# runner must be invoked below, or this aggregate fails before running
# anything. A runner only counts when an uncommented line invokes it.
# Helpers that are not runners (run-appstore-sources-common.sh,
# run-import-tests-common.sh, run-doc-reference-check.sh and the
# run-phase-N-device-preflight.sh wrappers) do not match *-tests.sh.
AGGREGATE="$ROOT_DIR/native/run-all-domain-tests.sh"
UNREGISTERED=""
for RUNNER in "$ROOT_DIR"/native/run-*-tests.sh; do
  NAME=$(basename "$RUNNER")
  [ "$NAME" = "run-all-domain-tests.sh" ] && continue
  if ! grep -Eq "^[[:space:]]*(sh[[:space:]]+)?\"\\\$ROOT_DIR/native/$NAME\"" "$AGGREGATE"; then
    UNREGISTERED="$UNREGISTERED $NAME"
  fi
done
if [ -n "$UNREGISTERED" ]; then
  echo "run-all-domain-tests.sh: unregistered runner(s):$UNREGISTERED" >&2
  echo "Register each one below (or rename a non-runner helper so it does not end in -tests.sh)." >&2
  exit 1
fi
