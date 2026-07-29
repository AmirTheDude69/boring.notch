#!/usr/bin/env bash
set -euo pipefail

# Minimal wrapper to create a DMG using dmgbuild.
# Usage: ./create_dmg.sh <app_path> <dmg_output> <volume_name>

APP_PATH="${1:?App path required}"
DMG_OUTPUT="${2:?DMG output path required}"
VOLUME_NAME="${3:?Volume name required}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETTINGS="$SCRIPT_DIR/dmgbuild_settings.py"

die() {
  echo "Error: $*" >&2
  exit 1
}

abs_path() {
  python3 -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "$1"
}

ensure_dmgbuild_and_badge_support() {
  if command -v dmgbuild >/dev/null 2>&1; then
    return 0
  fi

  local req_file="$SCRIPT_DIR/requirements.txt"
  if [ ! -f "$req_file" ]; then
    die "Dependency lock file not found: $req_file"
  fi

  die "dmgbuild is not installed. Install hash-pinned dependencies first: python3 -m pip install --require-hashes -r $req_file"
}

if [ ! -f "$SETTINGS" ]; then
  die "dmgbuild settings not found: $SETTINGS"
fi

ensure_dmgbuild_and_badge_support

DMG_APP_PATH="$(abs_path "$APP_PATH")"
export DMG_APP_PATH
export DMG_VOLUME_NAME="$VOLUME_NAME"

echo "Creating DMG via dmgbuild: app=$DMG_APP_PATH output=$DMG_OUTPUT volume=$DMG_VOLUME_NAME"

# Validate inputs early to give clearer errors for common typos
if [ ! -e "$DMG_APP_PATH" ]; then
  echo "Error: App path not found: $DMG_APP_PATH" >&2
  echo "Make sure you passed the correct .app path (e.g. Release/boringNotch.app)" >&2
  exit 2
fi

if [ ! -d "$DMG_APP_PATH" ]; then
  echo "Error: App path exists but is not a directory: $DMG_APP_PATH" >&2
  exit 3
fi

dmgbuild -s "$SETTINGS" "$DMG_VOLUME_NAME" "$DMG_OUTPUT"

exit $?
