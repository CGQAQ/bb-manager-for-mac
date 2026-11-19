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
#   APPLE_ID, APPLE_TEAM_ID, APPLE_APP_PASSWORD
#                   Alternative to NOTARY_PROFILE (used in CI): notarize with an Apple ID
#                   and an app-specific password.
#   VERSION         marketing version, e.g. 1.2.0 (default: MARKETING_VERSION in the project).
#   BUILD_NUMBER    build number (default: CURRENT_PROJECT_VERSION in the project).
#   DMG_NAME        file name of the image (default: BB-Manager-<version>.dmg).
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
APPLE_ID="${APPLE_ID:-}"
APPLE_TEAM_ID="${APPLE_TEAM_ID:-}"
APPLE_APP_PASSWORD="${APPLE_APP_PASSWORD:-}"
LOG="$ROOT/build/build-dmg.log"

mkdir -p "$ROOT/build" "$OUTPUT_DIR"

overrides=(ONLY_ACTIVE_ARCH=NO)
if [ -n "${VERSION:-}" ]; then
  [[ "$VERSION" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || { echo "VERSION must look like 1, 1.2 or 1.2.3 (got '$VERSION')" >&2; exit 1; }
  overrides+=("MARKETING_VERSION=$VERSION")
fi
if [ -n "${BUILD_NUMBER:-}" ]; then
  [[ "$BUILD_NUMBER" =~ ^[0-9]+(\.[0-9]+)*$ ]] || { echo "BUILD_NUMBER must be numeric (got '$BUILD_NUMBER')" >&2; exit 1; }
  overrides+=("CURRENT_PROJECT_VERSION=$BUILD_NUMBER")
fi

echo "==> Building $APP_NAME (Release, Apple silicon + Intel) with $(xcodebuild -version | head -1)"
if ! xcodebuild \
    -project BBManager.xcodeproj \
    -scheme "$SCHEME" \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "$DERIVED_DATA" \
    "${overrides[@]}" \
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

DMG="$OUTPUT_DIR/${DMG_NAME:-BB-Manager-$VERSION.dmg}"
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

notary_auth=()
if [ -n "$NOTARY_PROFILE" ]; then
  notary_auth=(--keychain-profile "$NOTARY_PROFILE")
elif [ -n "$APPLE_ID" ] && [ -n "$APPLE_TEAM_ID" ] && [ -n "$APPLE_APP_PASSWORD" ]; then
  notary_auth=(--apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_PASSWORD")
fi
if [ ${#notary_auth[@]} -gt 0 ]; then
  if [ "$SIGN_IDENTITY" = "-" ]; then
    echo "Notarization needs a Developer ID SIGN_IDENTITY; skipping it." >&2
  else
    echo "==> Notarizing (this can take a few minutes)"
    xcrun notarytool submit "$DMG" "${notary_auth[@]}" --wait
    xcrun stapler staple "$DMG"
  fi
fi

hdiutil verify -quiet "$DMG"
(cd "$(dirname "$DMG")" && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")
echo "==> Done: $DMG ($(du -h "$DMG" | cut -f1 | tr -d ' '))"
echo "    sha256 $(cut -d' ' -f1 "$DMG.sha256")"
# Lets CI pick up the result without guessing the file name.
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  { echo "dmg=$DMG"; echo "checksum=$DMG.sha256"; } >> "$GITHUB_OUTPUT"
fi
