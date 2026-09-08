#!/usr/bin/env bash
# Builds, signs, notarizes, and publishes the Mac app as a GitHub Release asset.
#
#   bun release:mac                # version from project.yml (MARKETING_VERSION)
#   bun release:mac -- 0.2.0       # explicit version; project.yml is updated to match
#   bun release:mac -- --dry-run   # build, sign, and zip only; no notarization or upload
#
# Requirements (one-time):
#   - Xcode with the "Developer ID Application" certificate in your login keychain
#   - gh CLI logged in (gh auth login)
#   - Notary credentials stored once:
#       xcrun notarytool store-credentials stint-notary \
#         --apple-id <apple-id-email> --team-id K78G42H4U2 --password <app-specific-password>
#
# The asset is always named Stint-macOS.zip, so the website links to the stable URL
# https://github.com/joeblau/stint/releases/latest/download/Stint-macOS.zip
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

REPO="joeblau/stint"
TEAM_ID="K78G42H4U2"
NOTARY_PROFILE="${STINT_NOTARY_PROFILE:-stint-notary}"
DRY_RUN=0
VERSION=""
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    *) VERSION="$arg" ;;
  esac
done

if [[ -n "$VERSION" ]]; then
  sed -i '' "s/MARKETING_VERSION: '[^']*'/MARKETING_VERSION: '$VERSION'/" project.yml
else
  VERSION=$(sed -n "s/.*MARKETING_VERSION: '\([^']*\)'.*/\1/p" project.yml | head -1)
fi
BUILD_NUMBER=$(git rev-list --count HEAD 2>/dev/null || echo 1)
TAG="v$VERSION"
echo "Releasing Stint $VERSION (build $BUILD_NUMBER) as $TAG"

command -v xcodegen >/dev/null || { echo "Install XcodeGen first: brew install xcodegen" >&2; exit 1; }
command -v gh >/dev/null || { echo "Install the GitHub CLI first: brew install gh" >&2; exit 1; }
security find-identity -v -p codesigning | grep -q "Developer ID Application" \
  || { echo "No 'Developer ID Application' certificate in the keychain." >&2; exit 1; }

OUT="build/release"
rm -rf "$OUT"
mkdir -p "$OUT"
xcodegen generate

echo "Archiving…"
xcodebuild -quiet archive \
  -project Stint.xcodeproj -scheme Stint -configuration Release \
  -destination "generic/platform=macOS" \
  -archivePath "$OUT/Stint.xcarchive" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="Developer ID Application" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  OTHER_CODE_SIGN_FLAGS="--timestamp"

echo "Exporting with Developer ID…"
xcodebuild -quiet -exportArchive \
  -archivePath "$OUT/Stint.xcarchive" \
  -exportOptionsPlist Scripts/ExportOptions.plist \
  -exportPath "$OUT/export"

APP="$OUT/export/Stint.app"
ZIP="$OUT/Stint-macOS.zip"
codesign --verify --deep --strict "$APP"
ditto -c -k --keepParent "$APP" "$ZIP"

if [[ "$DRY_RUN" == 1 ]]; then
  echo "Dry run: signed app zipped at $ZIP (not notarized, not uploaded)."
  exit 0
fi

if xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  echo "Notarizing…"
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"
  spctl --assess --type execute -v "$APP"
else
  echo "warning: notary profile '$NOTARY_PROFILE' not found; publishing a signed but un-notarized build." >&2
  echo "         Store credentials once with: xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <email> --team-id $TEAM_ID --password <app-specific-password>" >&2
fi

echo "Publishing $TAG…"
if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  gh release upload "$TAG" "$ZIP" --repo "$REPO" --clobber
else
  gh release create "$TAG" "$ZIP" --repo "$REPO" --title "Stint $VERSION" --generate-notes
fi
echo "Done: https://github.com/$REPO/releases/tag/$TAG"
