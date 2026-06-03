#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$ROOT_DIR/.build/ClipDeck.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
ICON_FILE="$RESOURCES_DIR/ClipDeck.icns"
FRAMEWORKS_DIR="$CONTENTS_DIR/Frameworks"
SIGN_IDENTITY="${CLIPDECK_CODESIGN_IDENTITY:-}"
# Sparkle auto-update config — filled per release. Dev packaging can leave the key empty
# (the build still runs; updates just aren't EdDSA-verifiable until a key is set).
SU_FEED_URL="${CLIPDECK_SU_FEED_URL:-https://github.com/yaoguohh/clipdeck/releases/latest/download/appcast.xml}"
SU_PUBLIC_KEY="${CLIPDECK_SU_PUBLIC_KEY:-}"
# Version: marketing string + monotonic build number. Sparkle compares CFBundleVersion to decide
# "update available", so a release MUST bump BUILD_VERSION (CI passes the tag / run number).
MARKETING_VERSION="${CLIPDECK_MARKETING_VERSION:-0.1.0}"
BUILD_VERSION="${CLIPDECK_BUILD_VERSION:-1}"

cd "$ROOT_DIR"
swift build -c release

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$FRAMEWORKS_DIR"
cp "$ROOT_DIR/.build/release/ClipDeck" "$MACOS_DIR/ClipDeck"

# Embed Sparkle.framework. SwiftPM links it but does NOT place the runtime helpers
# (Autoupdate / Updater.app / XPC services) into the .app, so copy the framework in and add the
# standard rpath so the executable resolves it at runtime. Prefer the universal xcframework slice.
SPARKLE_FRAMEWORK="$(find "$ROOT_DIR/.build/artifacts" -path '*macos-arm64*/Sparkle.framework' -type d 2>/dev/null | head -1)"
[ -z "$SPARKLE_FRAMEWORK" ] && SPARKLE_FRAMEWORK="$ROOT_DIR/.build/release/Sparkle.framework"
if [ -d "$SPARKLE_FRAMEWORK" ]; then
  cp -R "$SPARKLE_FRAMEWORK" "$FRAMEWORKS_DIR/"
  install_name_tool -add_rpath "@executable_path/../Frameworks" "$MACOS_DIR/ClipDeck" 2>/dev/null || true
else
  echo "warning: Sparkle.framework not found in .build; auto-update will be unavailable in this build." >&2
fi

swift "$ROOT_DIR/scripts/generate-app-icon.swift" "$ICON_FILE"

# Localized resources (.lproj). macOS auto-selects the best match for the user's
# preferred languages at runtime — no language detection code needed.
for lproj in "$ROOT_DIR"/Localization/*.lproj; do
  [ -d "$lproj" ] && cp -R "$lproj" "$RESOURCES_DIR/"
done

cat > "$CONTENTS_DIR/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleLocalizations</key>
  <array>
    <string>en</string>
    <string>zh-Hans</string>
  </array>
  <key>CFBundleExecutable</key>
  <string>ClipDeck</string>
  <key>CFBundleIdentifier</key>
  <string>dev.local.clipdeck</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>ClipDeck</string>
  <key>CFBundleIconFile</key>
  <string>ClipDeck</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>NSHumanReadableCopyright</key>
  <string>Copyright © 2026 ClipDeck</string>
</dict>
</plist>
PLIST

# Sparkle auto-update keys (appended to the base plist; SUPublicEDKey omitted cleanly when unset).
PLB=/usr/libexec/PlistBuddy
# Override the placeholder version with the release version (Sparkle compares CFBundleVersion).
"$PLB" -c "Set :CFBundleShortVersionString $MARKETING_VERSION" "$CONTENTS_DIR/Info.plist"
"$PLB" -c "Set :CFBundleVersion $BUILD_VERSION" "$CONTENTS_DIR/Info.plist"
"$PLB" -c "Add :SUFeedURL string $SU_FEED_URL" "$CONTENTS_DIR/Info.plist"
"$PLB" -c "Add :SUEnableAutomaticChecks bool true" "$CONTENTS_DIR/Info.plist"
if [[ -n "$SU_PUBLIC_KEY" ]]; then
  "$PLB" -c "Add :SUPublicEDKey string $SU_PUBLIC_KEY" "$CONTENTS_DIR/Info.plist"
else
  echo "warning: CLIPDECK_SU_PUBLIC_KEY unset — SUPublicEDKey omitted. Run Sparkle's generate_keys and export it for release builds, or updates can't be EdDSA-verified." >&2
fi

# Resolve signing identity: Developer ID if available, else ad-hoc.
if [[ -z "$SIGN_IDENTITY" ]]; then
  SIGN_IDENTITY="$(
    security find-identity -v -p codesigning 2>/dev/null \
      | awk -F\" '/Apple Development|Developer ID Application|Mac Developer/ { print $2; exit }'
  )"
fi
if [[ -n "$SIGN_IDENTITY" ]]; then
  SIGN_ID="$SIGN_IDENTITY"
  echo "Signing ClipDeck with identity: $SIGN_ID" >&2
else
  SIGN_ID="-"
  echo "warning: no code signing identity found; using ad-hoc signing." >&2
  echo "warning: set CLIPDECK_CODESIGN_IDENTITY to a real certificate before notarized distribution." >&2
fi

# Sparkle adds nested code (framework + Updater.app + Autoupdate + XPC services). Sign it
# INNER-OUT — never `--deep` (it corrupts the XPC signatures). Do NOT add `-o runtime`
# (Hardened Runtime / Library Validation) on the ad-hoc path; it blocks Sparkle from loading
# into an ad-hoc-signed app.
SPARKLE_FW="$FRAMEWORKS_DIR/Sparkle.framework"
if [[ -d "$SPARKLE_FW" ]]; then
  while IFS= read -r -d '' nested; do
    codesign --force --sign "$SIGN_ID" "$nested" >/dev/null
  done < <(find "$SPARKLE_FW" \( -name "*.xpc" -o -name "*.app" \) -print0)
  AUTOUPDATE="$(find "$SPARKLE_FW" -name Autoupdate -type f | head -1)"
  [[ -n "$AUTOUPDATE" ]] && codesign --force --sign "$SIGN_ID" "$AUTOUPDATE" >/dev/null
  codesign --force --sign "$SIGN_ID" "$SPARKLE_FW" >/dev/null
fi

# Finally the outer app. The ad-hoc path pins a stable designated requirement (identifier) so
# Sparkle's update signature-match check passes across rebuilds and macOS keeps TCC grants.
# No `--deep`: the nested Sparkle code is already signed above.
if [[ "$SIGN_ID" == "-" ]]; then
  codesign --force --sign - \
    --requirements '=designated => identifier "dev.local.clipdeck"' \
    "$APP_DIR" >/dev/null
else
  codesign --force --sign "$SIGN_ID" "$APP_DIR" >/dev/null
fi
echo "$APP_DIR"
