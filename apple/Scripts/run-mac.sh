#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Stint requires macOS and Xcode." >&2
  exit 1
fi

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "Install XcodeGen first: brew install xcodegen" >&2
  exit 1
fi

STINT_BUILD_CONFIGURATION="${STINT_CONFIGURATION:-Release}"

xcodegen generate
xcodebuild -quiet \
  -project Stint.xcodeproj \
  -scheme Stint \
  -configuration "$STINT_BUILD_CONFIGURATION" \
  -destination "platform=macOS,arch=$(uname -m)" \
  -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO \
  build

open "build/Build/Products/$STINT_BUILD_CONFIGURATION/Stint.app"
