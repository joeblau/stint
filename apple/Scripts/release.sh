#!/usr/bin/env bash
# Signed + notarized release: build, sign with Developer ID, notarize, staple, zip, publish.
# Prereq: xcrun notarytool store-credentials "stint-notary" --apple-id <email> --team-id K78G42H4U2
# Usage: bash Scripts/release.sh 0.1.1
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
IDENTITY="Developer ID Application: Joe Blau (K78G42H4U2)"
PROFILE="${NOTARY_PROFILE:-stint-notary}"
VERSION="${1:?Pass a version, e.g. 0.1.1}"
APP="build/Build/Products/Release/Stint.app"
ZIP="Stint-macOS.zip"

xcodebuild -quiet -project Stint.xcodeproj -scheme Stint -configuration Release \
  -destination "platform=macOS,arch=$(uname -m)" -derivedDataPath build CODE_SIGNING_ALLOWED=NO build

codesign --force --deep --options runtime --timestamp --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"

rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
xcrun notarytool staple "$APP"
spctl --assess --type execute -vv "$APP"

rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
gh release create "v$VERSION" "$ZIP" --repo joeblau/stint --title "Stint $VERSION" \
  --notes "Signed and notarized — opens with no warnings. macOS 15+ (runs great on macOS 26)."
echo "Released v$VERSION: https://github.com/joeblau/stint/releases/tag/v$VERSION"
