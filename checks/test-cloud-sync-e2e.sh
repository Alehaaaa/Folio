#!/bin/bash
# Folio Sync end to end: the Mac app and the iOS app in a throwaway simulator
# share a sync code on a local sync server. The Mac's newer progress reaches
# the iPhone, then the iPhone's newer progress comes back to the Mac.
# Needs a release Mac build (swift build -c release in app/) and a simulator
# build of Folio.app: pass its path as $1.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IOS_APP="${1:?path to the simulator Folio.app}"
MAC_BIN="$ROOT/app/.build/release/Folio"
TMP="$(mktemp -d)"
PORT=${PORT:-8792}
CODE=E2ETESTCODE$(printf '%05d' $RANDOM)
SIM=""
cleanup() {
  kill "${SERVER:-0}" "${MAC:-0}" 2>/dev/null || true
  if [ -n "$SIM" ]; then xcrun simctl shutdown "$SIM" >/dev/null 2>&1 || true; xcrun simctl delete "$SIM" >/dev/null 2>&1 || true; fi
  rm -rf "$TMP"
}
trap cleanup EXIT
fail() {
  echo "FAIL $1"
  echo "-- server: $(curl -s "http://127.0.0.1:$PORT/v1/$CODE" | head -c 1500)"
  echo "-- mac log:"; tail -20 "$TMP/mac.log" 2>/dev/null || true
  ls -la "$MAC_DIR" "$IOS_DIR" 2>/dev/null || true
  exit 1
}

deno run --allow-net "$ROOT/sync-worker/local-server.mjs" "$PORT" >"$TMP/server.log" 2>&1 &
SERVER=$!
for _ in $(seq 50); do curl -s "http://127.0.0.1:$PORT/" >/dev/null && break; sleep 0.1; done

# One book on both devices, under different ids and with different progress.
library() { # dir id progress chapter openedAgoSeconds status collection
  mkdir -p "$1"
  python3 - "$@" <<'PY'
import json, sys, time, uuid
d, bid, progress, chapter, ago, status, coll = sys.argv[1:8]
ref = time.time() - 978307200  # Swift's default Date encoding
cid = str(uuid.uuid4()).upper()
book = {"id": bid, "title": "Sync Test Book", "author": "Ada Example", "format": "pdf", "fileName": "missing.pdf",
        "addedAt": ref - 86400, "lastOpenedAt": ref - float(ago), "progress": float(progress),
        "position": {"chapter": int(chapter), "fraction": 0.25, "pdfPage": int(chapter)},
        "status": status, "collections": [cid] if coll else []}
data = {"books": [book], "collections": [{"id": cid, "name": coll}] if coll else [], "secondsByDay": {},
        "goals": {"dailyMinutes": 5, "booksPerYear": 3}, "tracked": []}
json.dump(data, open(d + "/library.json", "w"))
PY
}
progress_of() { python3 -c 'import json,sys; b=json.load(open(sys.argv[1]))["books"][0]; print(round(float(b["progress"]),4), b["position"]["chapter"], b["status"], len(b["collections"]))' "$1"; }

MAC_DIR="$TMP/mac"; library "$MAC_DIR" "11111111-1111-1111-1111-111111111111" 0.42 7 60 reading "Favourites"
SIM=$(xcrun simctl create "Folio Sync E2E" "iPhone 17 Pro")
xcrun simctl boot "$SIM"
xcrun simctl install "$SIM" "$IOS_APP"
IOS_DIR="$(xcrun simctl get_app_container "$SIM" app.folio.reader.ios data)/Library/Application Support/FolioSyncE2E"
library "$IOS_DIR" "22222222-2222-2222-2222-222222222222" 0.05 1 86400 reading ""

echo "== Mac → iPhone"
FOLIO_DATA_DIR="$MAC_DIR" FOLIO_SYNC_ENDPOINT="http://127.0.0.1:$PORT" FOLIO_SYNC_CODE="$CODE" "$MAC_BIN" >"$TMP/mac.log" 2>&1 &
MAC=$!
sleep 6
SIMCTL_CHILD_FOLIO_DATA_DIR="$IOS_DIR" SIMCTL_CHILD_FOLIO_SYNC_ENDPOINT="http://127.0.0.1:$PORT" SIMCTL_CHILD_FOLIO_SYNC_CODE="$CODE" \
  xcrun simctl launch "$SIM" app.folio.reader.ios >/dev/null
ok=""
for _ in $(seq 75); do  # first launch on a fresh simulator is slow
  sleep 1
  [ "$(progress_of "$IOS_DIR/library.json")" = "0.42 7 reading 1" ] && ok=1 && break
done
[ -n "$ok" ] || fail "iPhone has $(progress_of "$IOS_DIR/library.json"), wanted the Mac's 0.42 at chapter 7 in Favourites"
echo "ok   iPhone took the Mac's progress, position and collection"

echo "== iPhone → Mac"
xcrun simctl terminate "$SIM" app.folio.reader.ios
python3 - "$IOS_DIR/library.json" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p)); b = d["books"][0]
b["progress"] = 1.0; b["status"] = "finished"; b["position"]["chapter"] = 30
json.dump(d, open(p, "w"))
PY
SIMCTL_CHILD_FOLIO_DATA_DIR="$IOS_DIR" SIMCTL_CHILD_FOLIO_SYNC_ENDPOINT="http://127.0.0.1:$PORT" SIMCTL_CHILD_FOLIO_SYNC_CODE="$CODE" \
  xcrun simctl launch "$SIM" app.folio.reader.ios >/dev/null
ok=""
for _ in $(seq 90); do   # the Mac checks every minute
  sleep 1
  [ "$(progress_of "$MAC_DIR/library.json")" = "1.0 30 finished 1" ] && ok=1 && break
done
[ -n "$ok" ] || fail "Mac has $(progress_of "$MAC_DIR/library.json"), wanted the iPhone's finished state"
echo "ok   Mac took the iPhone's finished state"
echo "All Folio Sync end-to-end checks passed"
