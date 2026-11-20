#!/bin/zsh
# Exercises the signed Folio.app queue end-to-end using only a localhost source.
# Nothing is installed into the user's real library or sent to external sites.
set -euo pipefail
cd "${0:A:h}/../app"
scratch=$(mktemp -d)
port=18773
server=0
cleanup() {
    if [[ "$server" != 0 ]]; then kill "$server" 2>/dev/null || :; fi
    rm -rf "$scratch"
}
trap cleanup EXIT
mkdir -p "$scratch/Extensions" checks
python3 ../checks/test-extension-browser-server.py "$port" > /tmp/folio-queue-e2e-server.log 2>&1 &
server=$!
ready=0
for attempt in {1..30}; do
    if curl --silent --fail --max-time 1 "http://127.0.0.1:$port/page" >/dev/null; then
        ready=1
        break
    fi
    sleep 0.2
done
if [[ "$ready" != 1 ]]; then
    echo "Local fixture server failed to become ready" >&2
    cat /tmp/folio-queue-e2e-server.log >&2
    exit 1
fi

cat > "$scratch/Extensions/queue-test.js" <<'JS'
var source = {
  id: "queue-test",
  name: "Local fixture",
  version: "1.0",
  description: "End-to-end background queue verification",
  allowedHosts: ["http://127.0.0.1:18773"],
  settings: [],
  search: function (query, page) {
    folio.status("Opening the local browser verification page…");
    folio.log("Started background session on approved localhost test server");
    var html = folio.browser.open("http://127.0.0.1:18773/page");
    if (html.indexOf("JS executed") < 0) throw new Error("The browser did not execute page JavaScript");
    folio.status("Choosing the exact title and author…");
    folio.log("Local metadata matched; the download requires the browser's private cookie");
    return [{
      id: "local-public-fixture",
      title: "Test Book",
      authors: ["Test Author"],
      origin: "localhost fixture",
      downloads: [{format: "epub", url: "http://127.0.0.1:18773/slow_download/local-fixture/0/0"}]
    }];
  },
  prepareDownload: function (url) {
    folio.status("Loading the official-style free partner landing page…");
    var page = folio.browser.open(url);
    if (!page.includes('js-partner-countdown')) throw new Error('Expected a real countdown page');
    folio.status("Free partner wait: about 2 seconds…");
    var ready = folio.browser.waitFor('span.bg-gray-200.break-all');
    if (ready !== "true") throw new Error('The free partner did not become ready');
    var final = folio.browser.evaluate("document.querySelector('span.bg-gray-200.break-all').textContent.trim()");
    folio.log("Normal browser countdown completed; final file URL published on the approved host");
    return final;
  },
  recent: function () { return []; }
};
JS

python3 - "$scratch" <<'PY'
import json, sys, time, uuid
from pathlib import Path
root=Path(sys.argv[1])
config={
  "queue-test": {"file":"queue-test.js", "enabled":True, "builtIn":False, "config":{}},
  "demeter": {"file":"demeter.js","enabled":False,"builtIn":True,"config":{}},
  "gutenberg": {"file":"gutenberg.js","enabled":False,"builtIn":True,"config":{}}
}
(root/"Extensions"/"extensions.json").write_text(json.dumps(config))
job={
 "id":str(uuid.uuid4()).upper(), "title":"Test Book","author":"Test Author",
 "cover":None,"hardcoverBookID":None,"hardcoverPages":None,
 "stage":"queued","statusText":"Waiting in the queue…","detailLog":[],
 "error":None,"importedBookID":None,"createdAt":time.time()-978307200,
 "updatedAt":time.time()-978307200
}
missing = {
 **job,
 "id":str(uuid.uuid4()).upper(),
 "title":"Missing Book",
 "author":"No Such Author",
 "detailLog":[],
 "updatedAt":time.time()-978307200+0.1
}
(root/"download-queue.json").write_text(json.dumps([job, missing]))
PY

image="$PWD/checks/downloading-e2e.png"
rm -f "$image"
FOLIO_DATA_DIR="$scratch" FOLIO_SELECT_DOWNLOADING=1 \
    FOLIO_LAYER_CAPTURE=1 FOLIO_SHOT_FRAMES=650 \
    ./Folio.app/Contents/MacOS/Folio --screenshot "$image" \
    > /tmp/folio-queue-e2e-app.log 2>&1
test -s "$image"

python3 - "$scratch" <<'PY'
import json, sys
from pathlib import Path
p=Path(sys.argv[1]); jobs=json.loads((p/"download-queue.json").read_text())
assert len(jobs)==2, jobs
job=next(j for j in jobs if j["title"]=="Test Book")
missing=next(j for j in jobs if j["title"]=="Missing Book")
assert job["stage"]=="completed", "Background job did not complete: "+repr(job)
assert job["importedBookID"], "Completed entry lacks imported book ID"
assert (p/"library.json").exists(), "No imported library was persisted"
lib=json.loads((p/"library.json").read_text())
assert any("Test Book" in str(b) for b in lib.get("books",[])), "Test EPUB not imported into library"
log="\n".join(job["detailLog"])
assert "Previous operation interrupted" not in log, "A merely queued book was incorrectly described as interrupted"
assert "background session" in log.lower(), "Extension log messages were not captured"
assert "countdown completed" in log.lower(), "Free partner countdown and final-link resolution were not exercised"
assert "verified" in log.lower() or "added" in log.lower(), "Download completion was not logged"
assert missing["stage"]=="failed", "Unmatched book was not marked failed: "+repr(missing)
assert ("No matching EPUB listing in en" in (missing.get("error") or "") or
        "No exact" in (missing.get("error") or "")), "Missing title error reason was not persisted"
assert "ERROR:" in "\n".join(missing["detailLog"]), "Detailed failure reason was not logged"
print("PASS: signed Folio.app, persistent background queue, sequential jobs, verified cookie, exact EPUB match/import, status and error logging")
print("Imported book:",job["importedBookID"])
PY
echo "SCREENSHOT: $image"
