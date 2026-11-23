#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT/build"
LOG="$BUILD_DIR/app-build.log"
PLATFORM="${1:-all}"

mkdir -p "$BUILD_DIR"
exec > >(tee "$LOG") 2>&1

step() { print "\n=== STEP: $1"; }
fail() { print -u2 "=== FAILED: $1"; exit 1; }

build_macos() {
  step "Build macOS Debug executable"
  cd "$ROOT"
  swift build -c debug || fail "macOS Swift build"

  step "Build macOS Debug widget"
  xcodebuild \
    -project "$ROOT/WidgetExtension/FolioWidgets.xcodeproj" \
    -scheme FolioWidgets \
    -configuration Debug \
    -sdk macosx \
    -derivedDataPath "$BUILD_DIR/macos-widget" \
    CODE_SIGNING_ALLOWED=NO \
    build || fail "macOS widget build"

  step "Assemble macOS Folio.app"
  local app="$BUILD_DIR/macos/Debug/Folio.app"
  local contents="$app/Contents"
  local widget_source="$BUILD_DIR/macos-widget/Build/Products/Debug/FolioWidgets.appex"
  rm -rf "$app"
  mkdir -p "$contents/MacOS" "$contents/Resources" "$contents/PlugIns"
  ditto "$ROOT/.build/debug/Folio" "$contents/MacOS/Folio"
  ditto "$ROOT/Support/Info.plist" "$contents/Info.plist"
  "$ROOT/Support/compile-macos-icon.sh" "$contents/Resources" || fail "macOS icon"
  ditto "$widget_source" "$contents/PlugIns/FolioWidgets.appex"
  xattr -cr "$app"
  codesign --force --sign - --timestamp=none "$contents/PlugIns/FolioWidgets.appex"
  codesign --force --sign - --timestamp=none "$app"
  codesign --verify --deep --strict "$app"
  print "=== macOS app: $app"
}

build_ios() {
  step "Generate iOS project"
  cd "$ROOT/iOS"
  python3 generate_project.py || fail "iOS project generation"

  step "Build iOS Simulator Debug app"
  xcodebuild \
    -project FolioiOS.xcodeproj \
    -scheme Folio \
    -configuration Debug \
    -sdk iphonesimulator \
    -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath "$BUILD_DIR/ios" \
    CODE_SIGNING_ALLOWED=NO \
    build || fail "iOS simulator build"
  local app="$BUILD_DIR/ios/Build/Products/Debug-iphonesimulator/Folio.app"
  [[ -d "$app" ]] || fail "iOS build did not produce Folio.app"
  print "=== iOS app: $app"
}

case "$PLATFORM" in
  macos) build_macos ;;
  ios) build_ios ;;
  all) build_macos; build_ios ;;
  *) print -u2 "Usage: $0 [macos|ios|all]"; exit 2 ;;
esac

print "\n=== ALL DONE $(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || print unknown)"
print "=== Log: $LOG"
