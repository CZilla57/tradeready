#!/bin/sh
# Fails if docs/native-fixture-manifest.json or the parity matrix's Owner and
# Automated tests columns are out of date. Regenerate with:
#   node scripts/parity-manifest.mjs --write
set -eu
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
node "$ROOT_DIR/scripts/parity-manifest.mjs" --check
