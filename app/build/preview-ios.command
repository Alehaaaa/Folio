#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOG="$ROOT/build/preview-ios.log"
DEVICE="${FOLIO_SIMULATOR:-iPhone 17 Pro}"
BUNDLE_ID="app.folio.reader.ios"
mkdir -p "$ROOT/build"
exec > >(tee "$LOG") 2>&1

print "=== iOS Debug preview $(date)"
print "=== Simulator: $DEVICE"
print "=== Log: $LOG"
"$ROOT/build/app-build.command" ios

UDID="$(xcrun simctl list devices available --json | python3 -c '
import json, os, sys
name = os.environ.get("FOLIO_SIMULATOR", "iPhone 17 Pro")
devices = [d for values in json.load(sys.stdin)["devices"].values() for d in values]
matches = [d for d in devices if d.get("isAvailable") and name in (d["name"], d["udid"])]
if not matches:
    raise SystemExit(f"No available simulator named {name!r}")
matches.sort(key=lambda d: d["state"] != "Booted")
print(matches[0]["udid"])
')"

STATE="$(xcrun simctl list devices --json | python3 -c '
import json, sys
udid = sys.argv[1]
for values in json.load(sys.stdin)["devices"].values():
    for device in values:
        if device["udid"] == udid:
            print(device["state"])
            raise SystemExit
' "$UDID")"
if [[ "$STATE" != "Booted" ]]; then
  xcrun simctl boot "$UDID"
fi
DEVELOPER_DIR="$(xcode-select -p)"
if [[ -d "${DEVELOPER_DIR:h}/Applications/DeviceHub.app" ]]; then
  open -a "${DEVELOPER_DIR:h}/Applications/DeviceHub.app" --args -CurrentDeviceUDID "$UDID"
elif [[ -d "$DEVELOPER_DIR/Applications/Simulator.app" ]]; then
  open -a "$DEVELOPER_DIR/Applications/Simulator.app" --args -CurrentDeviceUDID "$UDID"
else
  print -u2 "No Device Hub or Simulator app found in the selected Xcode installation."
  exit 1
fi
xcrun simctl bootstatus "$UDID" -b

APP="$ROOT/build/ios/Build/Products/Debug-iphonesimulator/Folio.app"
xcrun simctl terminate "$UDID" "$BUNDLE_ID" 2>/dev/null || true
xcrun simctl uninstall "$UDID" "$BUNDLE_ID" 2>/dev/null || true
xcrun simctl install "$UDID" "$APP"

print "=== Starting Folio and streaming its stdout/stderr."
print "=== Press Control-C to stop the debug session."
exec xcrun simctl launch --console-pty "$UDID" "$BUNDLE_ID" "$@"
