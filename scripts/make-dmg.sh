#!/usr/bin/env bash
# Wrap a built Trove.app into a drag-to-install disk image.
#
# Usage: scripts/make-dmg.sh [path-to-Trove.app] [output.dmg]
#        (defaults: .build/Trove.app → dist/Trove.dmg)
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-$ROOT_DIR/.build/Trove.app}"
OUT="${2:-$ROOT_DIR/dist/Trove.dmg}"

[ -d "$APP" ] || { echo "error: '$APP' not found — run scripts/package-app.sh first." >&2; exit 1; }

mkdir -p "$(dirname "$OUT")"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"   # drag-to-install; Sparkle ignores the symlink
hdiutil create \
  -volname "Trove" \
  -srcfolder "$STAGE" \
  -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov \
  "$OUT"
echo "$OUT"
