#!/usr/bin/env bash
# Install a locally-built Trove.app over /Applications for testing.
#
# Uses `ditto` — the macOS-native bundle copy that preserves symlinks, resource forks, and the code
# signature — instead of `rm -rf <live app> && cp -R`. For a clean replace (ditto overwrites files but
# does not prune ones the new build dropped) the old bundle is moved aside into a temp dir first, then
# discarded; the only `rm -rf` touches that temp dir, never the live /Applications path.
#
# Usage: scripts/install-local.sh [path-to-Trove.app]   (defaults to .build/Trove.app)
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${1:-$ROOT_DIR/.build/Trove.app}"
DEST="/Applications/Trove.app"

[ -d "$SRC" ] || { echo "error: '$SRC' not found — run scripts/package-app.sh first." >&2; exit 1; }

# Quit any running instance so the bundle isn't swapped underneath a live process.
osascript -e 'quit app "Trove"' >/dev/null 2>&1 || true
for _ in $(seq 1 10); do pgrep -x Trove >/dev/null 2>&1 || break; sleep 0.3; done
pkill -x Trove 2>/dev/null || true

# Stage the old bundle aside, ditto the new one into place, then discard the staged copy. If ditto
# fails, restore the previous bundle so the install is all-or-nothing.
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
[ -d "$DEST" ] && mv "$DEST" "$STAGE/Trove.app.old"
if ! ditto "$SRC" "$DEST"; then
  echo "error: ditto failed; restoring the previous bundle." >&2
  [ -d "$STAGE/Trove.app.old" ] && mv "$STAGE/Trove.app.old" "$DEST"
  exit 1
fi

open "$DEST"
VER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$DEST/Contents/Info.plist" 2>/dev/null || echo '?')"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$DEST/Contents/Info.plist" 2>/dev/null || echo '?')"
echo "Installed and launched Trove $VER (build $BUILD) from $SRC"
