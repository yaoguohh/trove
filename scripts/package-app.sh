#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$ROOT_DIR/.build/Trove.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
ICON_FILE="$RESOURCES_DIR/Trove.icns"
FRAMEWORKS_DIR="$CONTENTS_DIR/Frameworks"
SIGN_IDENTITY="${TROVE_CODESIGN_IDENTITY:-}"
# Sparkle auto-update config — filled per release. Dev packaging can leave the key empty
# (the build still runs; updates just aren't EdDSA-verifiable until a key is set).
SU_FEED_URL="${TROVE_SU_FEED_URL:-https://github.com/yaoguohh/trove/releases/latest/download/appcast.xml}"
SU_PUBLIC_KEY="${TROVE_SU_PUBLIC_KEY:-}"
# Version: marketing string + monotonic build number. Sparkle compares CFBundleVersion to decide
# "update available", so a release MUST bump BUILD_VERSION (CI passes the tag / run number).
# Local builds default to "<latest tag>-dev" / commit count, so an installed dev build reads as newer
# than the release it was cut from instead of as 0.1.0 (which Sparkle would then "update" over).
DEFAULT_VERSION="$(git -C "$ROOT_DIR" describe --tags --abbrev=0 2>/dev/null | sed 's/^v//')"
DEFAULT_BUILD="$(git -C "$ROOT_DIR" rev-list --count HEAD 2>/dev/null)"
MARKETING_VERSION="${TROVE_MARKETING_VERSION:-${DEFAULT_VERSION:+${DEFAULT_VERSION}-dev}}"
MARKETING_VERSION="${MARKETING_VERSION:-0.1.0-dev}"
BUILD_VERSION="${TROVE_BUILD_VERSION:-${DEFAULT_BUILD:-1}}"

cd "$ROOT_DIR"
# Universal binary: Apple Silicon and Intel Macs on the supported macOS versions (14+).
BUILD_ARCHS=(--arch arm64 --arch x86_64)
swift build -c release "${BUILD_ARCHS[@]}"
BIN_DIR="$(swift build -c release "${BUILD_ARCHS[@]}" --show-bin-path)"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$FRAMEWORKS_DIR"
cp "$BIN_DIR/Trove" "$MACOS_DIR/Trove"

# Embed Sparkle.framework. SwiftPM links it but does NOT place the runtime helpers
# (Autoupdate / Updater.app / XPC services) into the .app, so copy the framework in and add the
# standard rpath so the executable resolves it at runtime. Use the universal xcframework slice.
SPARKLE_FRAMEWORK="$(find "$ROOT_DIR/.build/artifacts" -path '*macos-arm64_x86_64*/Sparkle.framework' -type d 2>/dev/null | head -1)"
[ -z "$SPARKLE_FRAMEWORK" ] && SPARKLE_FRAMEWORK="$BIN_DIR/Sparkle.framework"
if [ -d "$SPARKLE_FRAMEWORK" ]; then
  cp -R "$SPARKLE_FRAMEWORK" "$FRAMEWORKS_DIR/"
  install_name_tool -add_rpath "@executable_path/../Frameworks" "$MACOS_DIR/Trove" 2>/dev/null || true
else
  echo "warning: Sparkle.framework not found in .build; auto-update will be unavailable in this build." >&2
fi

swift "$ROOT_DIR/scripts/generate-app-icon.swift" "$ICON_FILE"

cp "$ROOT_DIR/scripts/Info.plist" "$CONTENTS_DIR/Info.plist"
PLB=/usr/libexec/PlistBuddy
BUNDLE_ID="$("$PLB" -c "Print :CFBundleIdentifier" "$CONTENTS_DIR/Info.plist")"

# Localized resources (.lproj), declared in CFBundleLocalizations from the same directory list.
# macOS picks the best match for the user's preferred languages at runtime.
"$PLB" -c "Add :CFBundleLocalizations array" "$CONTENTS_DIR/Info.plist"
for lproj in "$ROOT_DIR"/Localization/*.lproj; do
  [ -d "$lproj" ] || continue
  cp -R "$lproj" "$RESOURCES_DIR/"
  "$PLB" -c "Add :CFBundleLocalizations: string $(basename "$lproj" .lproj)" "$CONTENTS_DIR/Info.plist"
done

# Per-build keys on top of the base plist: version (Sparkle compares CFBundleVersion) and Sparkle's
# auto-update settings (SUPublicEDKey omitted cleanly when unset).
"$PLB" -c "Add :CFBundleShortVersionString string $MARKETING_VERSION" "$CONTENTS_DIR/Info.plist"
"$PLB" -c "Add :CFBundleVersion string $BUILD_VERSION" "$CONTENTS_DIR/Info.plist"
"$PLB" -c "Add :SUFeedURL string $SU_FEED_URL" "$CONTENTS_DIR/Info.plist"
"$PLB" -c "Add :SUEnableAutomaticChecks bool true" "$CONTENTS_DIR/Info.plist"
if [[ -n "$SU_PUBLIC_KEY" ]]; then
  "$PLB" -c "Add :SUPublicEDKey string $SU_PUBLIC_KEY" "$CONTENTS_DIR/Info.plist"
else
  echo "warning: TROVE_SU_PUBLIC_KEY unset — SUPublicEDKey omitted. Run Sparkle's generate_keys and export it for release builds, or updates can't be EdDSA-verified." >&2
fi

# Signing identity: ad-hoc unless TROVE_CODESIGN_IDENTITY names a certificate. Never pick one up from
# the keychain implicitly — a build signed with a different identity than the release gets a different
# designated requirement, so macOS drops its Accessibility grant (see RELEASE.md, Hard constraints).
if [[ -n "$SIGN_IDENTITY" ]]; then
  SIGN_ID="$SIGN_IDENTITY"
  echo "Signing Trove with identity: $SIGN_ID" >&2
else
  SIGN_ID="-"
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
    --requirements "=designated => identifier \"$BUNDLE_ID\"" \
    "$APP_DIR" >/dev/null
else
  codesign --force --sign "$SIGN_ID" "$APP_DIR" >/dev/null
fi
echo "$APP_DIR"
