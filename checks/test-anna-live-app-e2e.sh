#!/bin/zsh
# Real public-domain Anna's Archive path exercised in the signed Folio.app.
# Search and record lookup were already independently verified on the live
# official site. Pin the verified, genuine, public-domain Anna URL here so the
# test exercises the REAL countdown -> final partner link -> actual EPUB ->
# native import without spending minutes resolving 12 unrelated editions.
# No paid API, credentials, simulated EPUB or alternate catalogue involved.
set -euo pipefail
cd "${0:A:h}/../app"
scratch=$(mktemp -d)
app=0
cleanup() {
    if [[ "$app" != 0 ]]; then kill "$app" 2>/dev/null || :; fi
    # Leave no persistent downloaded book or private browser data behind.
    rm -rf "$scratch"
}
trap cleanup EXIT
mkdir -p "$scratch/Extensions" checks
cat ../extensions/annas-archive.js > "$scratch/Extensions/annas-archive-free.js"
cat >> "$scratch/Extensions/annas-archive-free.js" <<'JS'

// Test-only book selection. The actual download uses the real Anna URL,
// unmodified free partner countdown logic, and normal Folio downloader.
source.search = function(query, page) {
  var knownMD5 = "dba7a9943ea918a5afd2b170527fca13";
  this.progress("Public-domain test record selected…",
    "Using the previously verified published Anna Slow Partner URL for MD5 " + knownMD5);
  return [{
    id: knownMD5, title: "Pride and Prejudice", authors: ["Jane Austen"],
    year: 1998, origin: "annas-archive.gl",
    downloads: [{format:"epub", url:"https://annas-archive.gl/slow_download/"+knownMD5+"/0/0"}]
  }];
};
JS

python3 - "$scratch" <<'PY'
from pathlib import Path
import sys, json, uuid, time
p=Path(sys.argv[1]); now=time.time()-978307200
config={
 "annas-archive-free":{"file":"annas-archive-free.js","enabled":True,"builtIn":False,"config":{}},
 "demeter":{"file":"demeter.js","enabled":False,"builtIn":True,"config":{}},
 "gutenberg":{"file":"gutenberg.js","enabled":False,"builtIn":True,"config":{}}
}
(p/"Extensions"/"extensions.json").write_text(json.dumps(config))
(p/"download-queue.json").write_text(json.dumps([{
 "id":str(uuid.uuid4()).upper(),"title":"Pride and Prejudice","author":"Jane Austen",
 "cover":None,"hardcoverBookID":None,"hardcoverPages":None,
 "stage":"queued","statusText":"Waiting to download public-domain EPUB…",
 "detailLog":[],"error":None,"importedBookID":None,
 "createdAt":now,"updatedAt":now
}]))
PY

shot="$PWD/checks/anna-live-final.png"
rm -f "$shot"
echo "Starting signed Folio.app with isolated library and official Anna extension…"
FOLIO_DATA_DIR="$scratch" FOLIO_SELECT_DOWNLOADING=1 \
    FOLIO_LAYER_CAPTURE=1 FOLIO_SHOT_FRAMES=26000 \
    ./Folio.app/Contents/MacOS/Folio --screenshot "$shot" \
    >/tmp/folio-anna-live-app.log 2>&1 &
app=$!
finalStage=""
started=$SECONDS
while kill -0 "$app" 2>/dev/null; do
  if [[ -e "$scratch/download-queue.json" ]]; then
    finalStage=$(python3 - "$scratch" <<'PY'
from pathlib import Path
import json,sys
job=json.loads((Path(sys.argv[1])/"download-queue.json").read_text())[0]
print(job["stage"])
PY
    )
    python3 - "$scratch" <<'PY'
from pathlib import Path
import json,sys
job=json.loads((Path(sys.argv[1])/"download-queue.json").read_text())[0]
print("QUEUE:",job["stage"],job["statusText"],flush=True)
PY
    if [[ "$finalStage" == "completed" || "$finalStage" == "failed" ]]; then
        echo "Queue finished with stage=$finalStage; stopping isolated app."
        kill "$app" 2>/dev/null || :
        break
    fi
  fi
  if (( SECONDS - started > 530 )); then
    echo "Reached bounded test runtime without final state." >&2
    kill "$app" 2>/dev/null || :
    break
  fi
  sleep 8
done
wait "$app" || :
app=0

python3 - "$scratch" <<'PY'
from pathlib import Path
import json,sys,hashlib,zipfile
p=Path(sys.argv[1]); job=json.loads((p/"download-queue.json").read_text())[0]
print("FINAL STAGE:",job["stage"])
print("FINAL STATUS:",job["statusText"])
print("FINAL ERROR:",job.get("error"))
print("LAST LOG ENTRIES:",*job["detailLog"][-14:],sep="\n - ")
assert job["stage"] == "completed", "The real official Anna free EPUB didn't complete."
files=list((p/"Files").glob("*.epub"))
assert len(files)==1, f"Expected one imported real EPUB, found {files}"
book=files[0]
print("FINAL EPUB:",book.name,"bytes=",book.stat().st_size,"MD5=",hashlib.md5(book.read_bytes()).hexdigest())
assert zipfile.is_zipfile(book)
assert book.stat().st_size == 278472, "The free partner returned unexpected EPUB bytes."
assert hashlib.md5(book.read_bytes()).hexdigest() == "dba7a9943ea918a5afd2b170527fca13", "The file's MD5 differs from the official record."
with zipfile.ZipFile(book) as z:
  assert "mimetype" in z.namelist()
  assert z.read("mimetype")==b"application/epub+zip"
print("PASS: REAL official free Anna partner EPUB downloaded and imported by signed Folio.app")
PY
if [[ -s "$shot" ]]; then echo "SCREENSHOT: $shot"; fi
