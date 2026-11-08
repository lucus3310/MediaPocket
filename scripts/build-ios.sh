#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ "$(uname -s)" != Darwin ]]; then
  echo "An Apple macOS runner with Xcode is required to build this iOS app." >&2
  exit 1
fi

xcodebuild -version
xcodebuild -showsdks
swift test --parallel
python3 scripts/prepare-native.py
xcodegen generate --spec project.yml

# Use the same source settings for Simulator and iPhone, with no Apple account
# or provisioning secrets available to the runner.
xcodebuild build \
  -project MediaPocket.xcodeproj -scheme MediaPocket -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build/Simulator \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO

xcodebuild build \
  -project MediaPocket.xcodeproj -scheme MediaPocket -configuration Release \
  -destination 'generic/platform=iOS' \
  -derivedDataPath build/Device \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO

python3 scripts/package-ipa.py \
  build/Device/Build/Products/Release-iphoneos/MediaPocket.app \
  build/artifacts/MediaPocket-unsigned.ipa
