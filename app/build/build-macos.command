#!/bin/bash
# Builds Folio for macOS into app/build/Folio.app and opens it.
# Double-click in Finder, or run from Terminal. Needs Xcode (26 or later).
# Signs with your single Developer ID / Apple Development identity if you have
# exactly one, otherwise ad hoc. Set FOLIO_SIGN_IDENTITY to choose one ("" = ad hoc).
set -euo pipefail

BUILD_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$(cd "$BUILD_DIR/.." && pwd)"
APP="$BUILD_DIR/Folio.app"
cd "$APP_DIR"

step() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
fail() { printf '\n\033[31mBuild failed: %s\033[0m\n' "$1"; read -r -p "Press Return to close." _ || true; exit 1; }
trap 'fail "see the messages above"' ERR

VERSION="$(sed -n 's/^APP_VERSION = "\(.*\)"/\1/p' iOS/generate_project.py)"
BUILD="$(sed -n 's/^BUILD_VERSION = "\(.*\)"/\1/p' iOS/generate_project.py)"

step "Building Folio ${VERSION} (${BUILD})"
swift build -c release --package-path "$APP_DIR"

step "Building the widget"
xcodebuild -project WidgetExtension/FolioWidgets.xcodeproj -scheme FolioWidgets \
  -configuration Release -sdk macosx -derivedDataPath .build/widget-derived \
  CODE_SIGNING_ALLOWED=NO build -quiet

step "Assembling Folio.app"
osascript -e 'tell application "Folio" to quit' >/dev/null 2>&1 || true
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/PlugIns"
cp .build/release/Folio "$APP/Contents/MacOS/Folio"
cp Support/Info.plist "$APP/Contents/Info.plist"
cp Support/Folio.icns "$APP/Contents/Resources/Folio.icns"
for bundle in .build/release/*.bundle; do
  [ -e "$bundle" ] && ditto "$bundle" "$APP/Contents/Resources/$(basename "$bundle")"
done
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$BUILD" "$APP/Contents/Info.plist"
ditto .build/widget-derived/Build/Products/Release/FolioWidgets.appex "$APP/Contents/PlugIns/FolioWidgets.appex"

step "Signing"
if [ "${FOLIO_SIGN_IDENTITY+set}" = set ]; then
  IDENTITY="${FOLIO_SIGN_IDENTITY:--}"
else
  IDS="$(security find-identity -v -p codesigning 2>/dev/null | awk '/"/ {print $2}' | grep -E '^[0-9A-F]{40}$' || true)"
  if [ "$(printf '%s\n' "$IDS" | grep -c .)" = 1 ]; then IDENTITY="$IDS"; else IDENTITY="-"; fi
fi
if [ "$IDENTITY" = "-" ]; then
  # Ad hoc signatures have no Team ID and can't claim the shared App Group.
  WIDGET_ENT="$BUILD_DIR/.widget-adhoc.entitlements"
  printf '%s' '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>com.apple.security.app-sandbox</key><true/></dict></plist>' > "$WIDGET_ENT"
  codesign --force --sign - --timestamp=none --entitlements "$WIDGET_ENT" "$APP/Contents/PlugIns/FolioWidgets.appex"
  codesign --force --sign - --timestamp=none "$APP"
else
  codesign --force --sign "$IDENTITY" --timestamp=none --entitlements WidgetExtension/FolioWidgets.entitlements "$APP/Contents/PlugIns/FolioWidgets.appex"
  codesign --force --sign "$IDENTITY" --timestamp=none --entitlements Support/Folio.entitlements "$APP"
fi
codesign --verify --deep --strict "$APP"

step "Done: $APP"
open "$APP"
