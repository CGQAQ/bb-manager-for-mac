#!/usr/bin/env bash
# Builds a Release copy of BB Manager and packages it as a compressed DMG.
#
# Usage:
#   scripts/build-dmg.sh
#
# Optional environment variables:
#   SIGN_IDENTITY   codesign identity, e.g. "Developer ID Application: Jane Doe (TEAMID)".
#                   Defaults to "-" (ad-hoc): the app runs on this Mac, and other Macs
#                   must open it with right-click > Open the first time.
#   NOTARY_PROFILE  notarytool keychain profile (see `xcrun notarytool store-credentials`).
#                   With a Developer ID identity, the DMG is notarized and stapled.
#   OUTPUT_DIR      where to write the DMG (default: dist/).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_NAME="BB Manager"
SCHEME="BBManager"
DERIVED_DATA="$ROOT/build/release"
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT/dist}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
LOG="$ROOT/build/build-dmg.log"

mkdir -p "$ROOT/build" "$OUTPUT_DIR"

echo "==> Building $APP_NAME (Release, Apple silicon + Intel)"
if ! xcodebuild \
    -project BBManager.xcodeproj \
    -scheme "$SCHEME" \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "$DERIVED_DATA" \
    ONLY_ACTIVE_ARCH=NO \
    clean build >"$LOG" 2>&1; then
  grep -E "error:" "$LOG" | sort -u | head -40 || true
  echo "Build failed. Full log: $LOG" >&2
  exit 1
fi

APP="$DERIVED_DATA/Build/Products/Release/$APP_NAME.app"
[ -d "$APP" ] || { echo "Built app not found at $APP" >&2; exit 1; }
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$APP/Contents/Info.plist")"
echo "    version $VERSION ($BUILD_NUMBER), architectures: $(lipo -archs "$APP/Contents/MacOS/$APP_NAME")"

if [ "$SIGN_IDENTITY" != "-" ]; then
  echo "==> Signing with \"$SIGN_IDENTITY\""
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
else
  echo "==> Using the ad-hoc signature from the build (set SIGN_IDENTITY for Developer ID)"
fi
codesign --verify --strict --verbose=1 "$APP"

echo "==> Creating disk image"
STAGING="$(mktemp -d "${TMPDIR:-/tmp}/bbmanager-dmg.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
ditto "$APP" "$STAGING/$APP_NAME.app"
ln -s /Applications "$STAGING/Applications"

DMG="$OUTPUT_DIR/BB-Manager-$VERSION.dmg"
rm -f "$DMG"
hdiutil create \
  -volname "$APP_NAME $VERSION" \
  -srcfolder "$STAGING" \
  -fs HFS+ \
  -format UDZO \
  -imagekey zlib-level=9 \
  -quiet \
  "$DMG"

if [ "$SIGN_IDENTITY" != "-" ]; then
  codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
fi

if [ -n "$NOTARY_PROFILE" ]; then
  if [ "$SIGN_IDENTITY" = "-" ]; then
    echo "NOTARY_PROFILE needs a Developer ID SIGN_IDENTITY; skipping notarization." >&2
  else
    echo "==> Notarizing (this can take a few minutes)"
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
  fi
fi

hdiutil verify -quiet "$DMG"
echo "==> Done: $DMG ($(du -h "$DMG" | cut -f1 | tr -d ' '))"
echo "    sha256 $(shasum -a 256 "$DMG" | cut -d' ' -f1)"
