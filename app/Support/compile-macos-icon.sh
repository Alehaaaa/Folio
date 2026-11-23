#!/bin/bash
# Compiles Support/AppIcon.icon (Icon Composer) into a macOS bundle's
# Contents/Resources: Assets.car (the Liquid Glass icon) + AppIcon.icns (fallback).
# Usage: Support/compile-macos-icon.sh <path/to/Folio.app/Contents/Resources>
# The bundle's Info.plist names it with CFBundleIconName/CFBundleIconFile = AppIcon.
set -euo pipefail

APP_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RESOURCES="$1"
MIN_MACOS="$(sed -n 's/.*\.macOS("\([0-9.]*\)").*/\1/p' "$APP_DIR/Package.swift" | head -1)"
PARTIAL="$(mktemp -t folio-icon).plist"
mkdir -p "$RESOURCES"

if xcrun actool "$APP_DIR/Support/AppIcon.icon" --compile "$RESOURCES" \
     --app-icon AppIcon --platform macosx --minimum-deployment-target "${MIN_MACOS:-26.0}" \
     --output-partial-info-plist "$PARTIAL" >/dev/null; then
  rm -f "$PARTIAL"
else
  echo "warning: actool could not compile AppIcon.icon; using Support/Folio.icns" >&2
  cp "$APP_DIR/Support/Folio.icns" "$RESOURCES/AppIcon.icns"
fi
