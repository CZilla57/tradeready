#!/bin/sh
# Phase 12 — TestFlight upload helper. Dry run by default.
#
# Usage: phase-12-testflight-upload.sh --version VERSION --build BUILD
#            [--execute] [--i-am-the-owner]
#
# By default (no --execute) this prints the exact archive -> export -> upload
# commands for the given native version/build and exits 0 WITHOUT running
# xcodebuild or xcrun. It never uploads anything and never touches App Store
# Connect on its own.
#
# --execute refuses (exit 3, "credentials absent — owner-run") unless every
# one of ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_PATH is set in the environment
# (names only; their values are never read, echoed or logged by this script
# before the credential gate passes) AND --i-am-the-owner is also passed.
# This script is never to be invoked with --execute or with those variables
# set by an agent (global constraints; task 14 brief). It exists so the
# owner can run one command later, and so its dry-run and refusal paths have
# host test coverage today.
set -u

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
PROJECT_PATH="$ROOT_DIR/native/TradeReadyNative.xcodeproj"

VERSION=
BUILD=
EXECUTE=0
I_AM_THE_OWNER=0
ARCHIVE_DIR=
EXPORT_DIR=

usage() {
  echo "Usage: $0 --version VERSION --build BUILD [--execute] [--i-am-the-owner]"
  echo "          [--archive-dir DIR] [--export-dir DIR]"
  echo ""
  echo "Dry run (default): prints the archive/export/upload commands and exits 0."
  echo "Never runs xcodebuild or xcrun in dry-run mode."
  echo ""
  echo "--execute: OWNER-GATED. Refuses (exit 3) unless ASC_KEY_ID, ASC_ISSUER_ID"
  echo "and ASC_KEY_PATH are all set in the environment and --i-am-the-owner is"
  echo "also passed. An agent must never pass --execute or set those variables."
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --version)
      [ "$#" -ge 2 ] || { usage >&2; exit 64; }
      VERSION=$2
      shift 2
      ;;
    --build)
      [ "$#" -ge 2 ] || { usage >&2; exit 64; }
      BUILD=$2
      shift 2
      ;;
    --archive-dir)
      [ "$#" -ge 2 ] || { usage >&2; exit 64; }
      ARCHIVE_DIR=$2
      shift 2
      ;;
    --export-dir)
      [ "$#" -ge 2 ] || { usage >&2; exit 64; }
      EXPORT_DIR=$2
      shift 2
      ;;
    --execute)
      EXECUTE=1
      shift
      ;;
    --i-am-the-owner)
      I_AM_THE_OWNER=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 64
      ;;
  esac
done

if [ -z "$VERSION" ] || [ -z "$BUILD" ]; then
  usage >&2
  exit 64
fi

TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/tradeready-phase12-upload.XXXXXX")
trap 'rm -rf "$TEMP_DIR"' EXIT HUP INT TERM

[ -n "$ARCHIVE_DIR" ] || ARCHIVE_DIR="$TEMP_DIR/archive"
[ -n "$EXPORT_DIR" ] || EXPORT_DIR="$TEMP_DIR/export"

ARCHIVE_PATH="$ARCHIVE_DIR/TradeReadyNative-$VERSION-$BUILD.xcarchive"
EXPORT_OPTIONS_PLIST="$TEMP_DIR/ExportOptions.plist"

# ---------------------------------------------------------------------------
# --execute credential gate. Checked BEFORE anything else so a refusal never
# invokes xcodebuild or xcrun. Names only: this script never reads, prints or
# logs the value of ASC_KEY_ID, ASC_ISSUER_ID or ASC_KEY_PATH.
# ---------------------------------------------------------------------------

if [ "$EXECUTE" -eq 1 ]; then
  missing=""
  [ -n "${ASC_KEY_ID:-}" ] || missing="$missing ASC_KEY_ID"
  [ -n "${ASC_ISSUER_ID:-}" ] || missing="$missing ASC_ISSUER_ID"
  [ -n "${ASC_KEY_PATH:-}" ] || missing="$missing ASC_KEY_PATH"

  if [ -n "$missing" ] || [ "$I_AM_THE_OWNER" -ne 1 ]; then
    {
      echo "credentials absent — owner-run"
      if [ -n "$missing" ]; then
        echo "Missing environment variable(s) (names only):$missing"
      fi
      if [ "$I_AM_THE_OWNER" -ne 1 ]; then
        echo "--i-am-the-owner was not passed."
      fi
      echo "This script never uploads, archives or exports without both conditions met."
    } >&2
    exit 3
  fi

  # OWNER-GATED real path. Only reached with every credential env var set and
  # --i-am-the-owner passed. An agent must never reach this line: it is not
  # exercised by the test suite (task 14 brief: "never test the path that
  # would run for real").
  echo "OWNER-GATED: proceeding with a real archive, export and upload." >&2
  mkdir -p "$ARCHIVE_DIR" "$EXPORT_DIR"

  DEVELOPMENT_TEAM=$(xcodebuild -project "$PROJECT_PATH" -scheme TradeReadyNative \
    -configuration Release -showBuildSettings 2>/dev/null \
    | sed -n 's/^[[:space:]]*DEVELOPMENT_TEAM = //p' | tail -n 1)

  cat >"$EXPORT_OPTIONS_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>app-store-connect</string>
    <key>destination</key>
    <string>upload</string>
    <key>teamID</key>
    <string>$DEVELOPMENT_TEAM</string>
</dict>
</plist>
PLIST

  xcodebuild -project "$PROJECT_PATH" -scheme TradeReadyNative \
    -configuration Release -destination 'generic/platform=iOS' \
    -archivePath "$ARCHIVE_PATH" \
    MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" \
    DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" -allowProvisioningUpdates archive

  xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_DIR" -exportOptionsPlist "$EXPORT_OPTIONS_PLIST" \
    -allowProvisioningUpdates \
    -authenticationKeyPath "$ASC_KEY_PATH" -authenticationKeyID "$ASC_KEY_ID" \
    -authenticationKeyIssuerID "$ASC_ISSUER_ID"

  exit 0
fi

# ---------------------------------------------------------------------------
# Dry run (default). Prints the exact commands; invokes neither xcodebuild
# nor xcrun. The plist below is a preview only, written with a placeholder
# team ID: the real run reads DEVELOPMENT_TEAM from build settings at run
# time (never hardcoded in source), so the preview cannot show the real
# value without invoking xcodebuild, which a dry run must not do.
# ---------------------------------------------------------------------------

cat >"$EXPORT_OPTIONS_PLIST" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>app-store-connect</string>
    <key>destination</key>
    <string>upload</string>
    <key>teamID</key>
    <string>&lt;TEAM_ID: read from `xcodebuild -showBuildSettings` DEVELOPMENT_TEAM at run time&gt;</string>
</dict>
</plist>
PLIST

cat <<EOF
DRY RUN — no command below has been executed. Nothing was archived, exported or
uploaded. Re-run with --execute only as the owner, with ASC_KEY_ID, ASC_ISSUER_ID
and ASC_KEY_PATH set and --i-am-the-owner passed.

Preview ExportOptions.plist written to (never committed to the repository):
  $EXPORT_OPTIONS_PLIST
$(sed 's/^/  /' "$EXPORT_OPTIONS_PLIST")

1. Archive (SIGN-1 must be cleared first):

  xcodebuild -project native/TradeReadyNative.xcodeproj -scheme TradeReadyNative \\
    -configuration Release -destination 'generic/platform=iOS' \\
    -archivePath "$ARCHIVE_PATH" \\
    MARKETING_VERSION=$VERSION CURRENT_PROJECT_VERSION=$BUILD \\
    DEVELOPMENT_TEAM="\$(xcodebuild -project native/TradeReadyNative.xcodeproj -scheme TradeReadyNative -configuration Release -showBuildSettings | sed -n 's/^[[:space:]]*DEVELOPMENT_TEAM = //p' | tail -n 1)" \\
    -allowProvisioningUpdates archive

2. Check the numbers the archive carries (app and widget extension):

  /usr/libexec/PlistBuddy -c 'Print :ApplicationProperties:CFBundleShortVersionString' \\
    "$ARCHIVE_PATH/Info.plist"
  /usr/libexec/PlistBuddy -c 'Print :ApplicationProperties:CFBundleVersion' \\
    "$ARCHIVE_PATH/Info.plist"

3. Export (generates a real ExportOptions.plist to a temp dir at run time,
   method app-store-connect, team ID read from build settings, never from
   source):

  xcodebuild -exportArchive \\
    -archivePath "$ARCHIVE_PATH" \\
    -exportPath "$EXPORT_DIR" -exportOptionsPlist "<temp-dir>/ExportOptions.plist" \\
    -allowProvisioningUpdates \\
    -authenticationKeyPath "\$ASC_KEY_PATH" -authenticationKeyID "\$ASC_KEY_ID" \\
    -authenticationKeyIssuerID "\$ASC_ISSUER_ID"

The export step uploads directly to TestFlight when it succeeds (destination
"upload"). Submitting the processed build for review is a separate, later
App Store Connect action this script never takes.
EOF

exit 0
