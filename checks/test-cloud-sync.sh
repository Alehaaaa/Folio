#!/bin/bash
# Folio Sync: merge rules, and the sync server (sync-worker/worker.js) run
# locally with an in-memory KV. Needs swiftc and deno.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'kill "${SERVER:-0}" 2>/dev/null || true; rm -rf "$TMP"' EXIT

echo "== Merge rules"
cp "$ROOT/checks/test-cloud-sync.swift" "$TMP/main.swift"
swiftc -O -o "$TMP/merge" "$ROOT/app/Sources/Folio/CloudSyncCore.swift" "$TMP/main.swift"
"$TMP/merge"

echo "== Sync server"
PORT=${PORT:-8791}
deno run --allow-net "$ROOT/sync-worker/local-server.mjs" "$PORT" >"$TMP/server.log" 2>&1 &
SERVER=$!
for _ in $(seq 50); do curl -s "http://127.0.0.1:$PORT/" >/dev/null && break; sleep 0.1; done
URL="http://127.0.0.1:$PORT/v1/ABCDEFGHJKLMNPQR"
NOW=$(($(date +%s) * 1000))
fail() { echo "FAIL $1"; exit 1; }
status() { curl -s -o "$TMP/body" -w '%{http_code}' "$@"; }

[ "$(status "$URL")" = 404 ] || fail "empty code should be 404"; echo "ok   empty code is 404"
[ "$(status -X PUT -H 'content-type: application/json' --data '{"deviceName":"Mac","platform":"mac","savedAt":'"$NOW"',"books":[]}' "$URL/device-mac-1")" = 200 ] || fail "PUT mac"
[ "$(status -X PUT --data '{"deviceName":"iPhone","platform":"iphone","savedAt":'"$NOW"',"books":[{"keys":["t:x"]}]}' "$URL/device-phone-1")" = 200 ] || fail "PUT phone"
[ "$(status "$URL")" = 200 ] || fail "GET after PUT"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1]))["devices"]; assert set(d)=={"device-mac-1","device-phone-1"}, d' "$TMP/body" || fail "both devices kept"
echo "ok   both devices are kept side by side"
[ "$(status -X PUT --data '{"deviceName":"Old","savedAt":1,"books":[]}' "$URL/device-old-1")" = 200 ] || fail "PUT old"
[ "$(status -X PUT --data '{"deviceName":"Mac","savedAt":'"$NOW"',"books":[]}' "$URL/device-mac-1")" = 200 ] || fail "PUT mac again"
status "$URL" >/dev/null
python3 -c 'import json,sys; d=json.load(open(sys.argv[1]))["devices"]; assert set(d)=={"device-mac-1","device-phone-1"}, d' "$TMP/body" || fail "stale device dropped"
echo "ok   devices silent for 180 days are dropped"
[ "$(status -X PUT --data 'nope' "$URL/device-mac-1")" = 400 ] || fail "bad json"; echo "ok   bad JSON is refused"
[ "$(status "http://127.0.0.1:$PORT/v1/short")" = 404 ] || fail "short code"; echo "ok   short codes are refused"
[ "$(status -X DELETE "$URL")" = 405 ] || fail "delete"; echo "ok   other methods are refused"
python3 -c 'print("{\"books\":[],\"pad\":\"" + "x"*1100000 + "\"}")' > "$TMP/big.json"
[ "$(status -X PUT --data-binary @"$TMP/big.json" "$URL/device-mac-1")" = 413 ] || fail "size limit"; echo "ok   oversized entries are refused"
echo "All Folio Sync checks passed"
