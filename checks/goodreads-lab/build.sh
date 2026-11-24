#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"
swift build -c release --product GoodreadsLab
bin_dir="$(swift build -c release --show-bin-path)"
app_dir="$PWD/.build/GoodreadsLab.app"

mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$bin_dir/GoodreadsLab" "$app_dir/Contents/MacOS/GoodreadsLab"
if [[ -d "$bin_dir/GoodreadsLab_GoodreadsLab.bundle" ]]; then
  cp -R "$bin_dir/GoodreadsLab_GoodreadsLab.bundle" "$app_dir/Contents/Resources/"
else
  echo "Missing bundled browser script at $bin_dir" >&2
  exit 1
fi

cat > "$app_dir/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>GoodreadsLab</string>
  <key>CFBundleIdentifier</key><string>app.folio.goodreads-lab</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>Goodreads Lab</string>
  <key>CFBundleDisplayName</key><string>Goodreads Lab</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$app_dir"
echo "Built: $app_dir"
echo "Run with: open '$app_dir'"
