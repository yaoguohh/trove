#!/usr/bin/env bash
# Download Sparkle's command-line tools (generate_keys, generate_appcast, sign_update) at the exact
# version Package.resolved pins, so the tools always match the framework embedded in the app.
#
# Usage: scripts/fetch-sparkle-tools.sh [dest-dir]   (default: /tmp/sparkle; tools land in <dest>/bin)
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DEST="${1:-/tmp/sparkle}"
VERSION="$(/usr/bin/python3 -c 'import json,sys; print(next(p["state"]["version"] for p in json.load(open(sys.argv[1]))["pins"] if p["identity"] == "sparkle"))' "$ROOT_DIR/Package.resolved")"

ARCHIVE="$(mktemp -t sparkle).tar.xz"
trap 'rm -f "$ARCHIVE"' EXIT
curl -fsSL -o "$ARCHIVE" \
  "https://github.com/sparkle-project/Sparkle/releases/download/${VERSION}/Sparkle-${VERSION}.tar.xz"
mkdir -p "$DEST"
tar -xf "$ARCHIVE" -C "$DEST"
echo "Sparkle ${VERSION} tools in $DEST/bin"
