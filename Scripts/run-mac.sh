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

xcodegen generate
xcodebuild -quiet \
  -project Stint.xcodeproj \
  -scheme Stint \
  -configuration Debug \
  -destination "platform=macOS,arch=$(uname -m)" \
  -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO \
  build

open build/Build/Products/Debug/Stint.app
