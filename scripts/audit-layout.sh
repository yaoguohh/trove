#!/usr/bin/env bash
# Render Trove's surfaces and measure their alignment and the contrast on the glass (docs/DESIGN.md,
# "对齐" and "玻璃").
#
# Runs the opt-in LayoutAuditTests: the panel, status menu, welcome window, empty panel, peek bubble and
# app icon are rendered at 2x and measured by their visible pixels, and the text on the panel's glass is
# checked for contrast over a white, a gray and a black desktop. Writes report.md plus the renders
# (plain, `-marked` with the measured boxes, and enlarged close-ups) to the output directory, prints the
# rows that are off, and exits non-zero if there are any. The windows appear on screen for a moment, so
# the screen must be unlocked. Everything is measured on 2x displays only, since a 1x display rounds text
# and shapes to whole points: the panel on each of them (each may get its own card size), the rest on the
# built-in one. The glass check photographs the real screen with `screencapture`, which needs Screen
# Recording permission for the terminal running this.
#
# Usage: scripts/audit-layout.sh [output-directory]   (defaults to .build/layout-audit)
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT_DIR/.build/layout-audit}"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"

# The icon as scripts/package-app.sh makes it: measured on its own, and shown in the welcome window.
swift "$ROOT_DIR/scripts/generate-app-icon.swift" "$OUT/Trove.icns"

cd "$ROOT_DIR"
TROVE_LAYOUT_AUDIT="$OUT" TROVE_AUDIT_ICON="$OUT/Trove.icns" swift test --filter LayoutAuditTests

echo "Report: $OUT/report.md"
if grep -E '\| (✗|⚠️) \|$' "$OUT/report.md"; then
  echo "error: the rows above are off their line." >&2
  exit 1
fi
echo "Everything is on its line."
