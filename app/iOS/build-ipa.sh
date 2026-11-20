#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"
python3 generate_project.py

mkdir -p dist
if [[ -n "${EXPORT_OPTIONS_PLIST:-}" ]]; then
  if [[ ! -f "$EXPORT_OPTIONS_PLIST" ]]; then
    echo "Export options file not found: $EXPORT_OPTIONS_PLIST" >&2
    exit 2
  fi
  xcodebuild \
    -project FolioiOS.xcodeproj \
    -scheme Folio \
    -configuration Release \
    -destination 'generic/platform=iOS' \
    -derivedDataPath "$SCRIPT_DIR/.build-device" \
    -archivePath "$SCRIPT_DIR/dist/Folio.xcarchive" \
    CODE_SIGNING_ALLOWED=YES \
    archive
  xcodebuild \
    -exportArchive \
    -archivePath "$SCRIPT_DIR/dist/Folio.xcarchive" \
    -exportOptionsPlist "$EXPORT_OPTIONS_PLIST" \
    -exportPath "$SCRIPT_DIR/dist"
else
  xcodebuild \
    -project FolioiOS.xcodeproj \
    -scheme Folio \
    -configuration Release \
    -destination 'generic/platform=iOS' \
    -derivedDataPath "$SCRIPT_DIR/.build-device" \
    CODE_SIGNING_ALLOWED=NO \
    build

  APP="$SCRIPT_DIR/.build-device/Build/Products/Release-iphoneos/Folio.app"
  if [[ ! -d "$APP" ]]; then
    echo "Device build did not produce Folio.app" >&2
    exit 1
  fi
  STAGING="$(mktemp -d "$SCRIPT_DIR/dist/.ipa-staging.XXXXXX")"
  trap 'rm -rf "$STAGING"' EXIT
  mkdir -p "$STAGING/Payload"
  /usr/bin/ditto "$APP" "$STAGING/Payload/Folio.app"
  rm -f "$SCRIPT_DIR/dist/Folio.ipa"
  (
    cd "$STAGING"
    /usr/bin/zip -q -r -y "$SCRIPT_DIR/dist/Folio.ipa" Payload
  )
fi

if [[ -f "$SCRIPT_DIR/dist/Folio.ipa" ]]; then
  /usr/bin/unzip -tq "$SCRIPT_DIR/dist/Folio.ipa"
  for expected in \
    'Payload/Folio.app/Folio' \
    'Payload/Folio.app/PlugIns/FolioWidgets.appex/Info.plist' \
    'Payload/Folio.app/PlugIns/FolioWidgets.appex/FolioWidgets'; do
    # Do not use grep -q with pipefail: it can exit before unzip finishes,
    # making an existing item appear missing because unzip receives SIGPIPE.
    if ! /usr/bin/unzip -Z1 "$SCRIPT_DIR/dist/Folio.ipa" | /usr/bin/grep -Fx "$expected" >/dev/null; then
      echo "IPA is missing required application or widget artifact: $expected" >&2
      exit 1
    fi
  done
  for source in "$SCRIPT_DIR"/../../extensions/*.js; do
    [[ -f "$source" ]] || continue
    expected="Payload/Folio.app/$(basename "$source")"
    if ! /usr/bin/unzip -Z1 "$SCRIPT_DIR/dist/Folio.ipa" | /usr/bin/grep -Fx "$expected" >/dev/null; then
      echo "IPA is missing bundled source: $expected" >&2
      exit 1
    fi
  done
  echo "IPA ready: $SCRIPT_DIR/dist/Folio.ipa"
else
  echo "The Xcode export did not create dist/Folio.ipa" >&2
  exit 1
fi
