#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

python3 generate_project.py

xcodebuild \
  -project FolioiOS.xcodeproj \
  -scheme Folio \
  -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath "$SCRIPT_DIR/.build" \
  CODE_SIGNING_ALLOWED=NO \
  build
