#!/bin/bash
# Packs a built PrettyFolder.app into a zip for GitHub Releases.
#
#   Scripts/package-release.sh <path/to/PrettyFolder.app> <output dir>
#
# Optional environment:
#   DEVELOPER_ID    "Developer ID Application: Your Name (TEAMID)" to sign for distribution
#   NOTARY_PROFILE  a notarytool keychain profile (xcrun notarytool store-credentials) to notarize
set -euo pipefail

APP="${1:?path to PrettyFolder.app}"
OUT="${2:?output directory}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APPEX="$APP/Contents/PlugIns/PrettyFolderFinder.appex"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
ZIP="$OUT/PrettyFolder-$VERSION.zip"

mkdir -p "$OUT"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/PrettyFolder.app"
APP="$STAGE/PrettyFolder.app"
APPEX="$APP/Contents/PlugIns/PrettyFolderFinder.appex"

if [[ -n "${DEVELOPER_ID:-}" ]]; then
    echo "Signing with $DEVELOPER_ID"
    # Inside out: the extension first, then the app around it.
    codesign --force --options runtime --timestamp \
        --entitlements "$ROOT/Config/FinderExtension.entitlements" \
        --sign "$DEVELOPER_ID" "$APPEX"
    codesign --force --options runtime --timestamp \
        --entitlements "$ROOT/Config/App.entitlements" \
        --sign "$DEVELOPER_ID" "$APP"
fi
codesign --verify --deep --strict "$APP"

rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    echo "Notarizing…"
    xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"
fi

echo "Created $ZIP"
shasum -a 256 "$ZIP"
