#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOG="$ROOT/build/preview-macos.log"
mkdir -p "$ROOT/build"
exec > >(tee "$LOG") 2>&1

print "=== macOS Debug preview $(date)"
print "=== Log: $LOG"
"$ROOT/build/app-build.command" macos

APP="$ROOT/build/macos/Debug/Folio.app"
BIN="$APP/Contents/MacOS/Folio"
print "=== Starting $APP"
print "=== Press Control-C to stop; rerun this command after source changes."
killall Folio 2>/dev/null || true
exec "$BIN" "$@"
