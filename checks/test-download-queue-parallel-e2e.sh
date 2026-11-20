#!/bin/zsh
# Signed Folio.app concurrent DownloadQueue end-to-end regression.
# Run: /bin/zsh checks/test-download-queue-parallel-e2e.sh
#
# Seven queued jobs and one already-cancelled job; all data is synthetic.
# HTTP request start/end timestamps prove concurrency without relying on
# second-resolution UI logs or on the number of queued tasks.
# Only temp FOLIO_DATA_DIR is written; real app support/widget writes denied.
set -euo pipefail

here="${0:A:h}"
app="$here/../app"
binary="$app/Folio.app/Contents/MacOS/Folio"
scratch=$(mktemp -d "${TMPDIR:-/tmp/}folio-parallel-e2e.XXXXXXXX")
server=0
cleanup() {
    if [[ "$server" != 0 ]]; then kill "$server" 2>/dev/null || :; fi
    rm -rf -- "$scratch"
}
trap cleanup EXIT

if [[ ! -x "$binary" ]] || ! /usr/bin/codesign --verify --deep --strict "$app/Folio.app" >/dev/null 2>&1; then
    print -u2 'FAIL: canonical signed Folio.app required; do not rebuild/package in this test'
    exit 1
fi
mkdir -p "$scratch/home" "$scratch/data/Extensions"

# The app writes widget snapshots into a real App Group regardless of
# FOLIO_DATA_DIR. Explicitly deny production app-support and group writes.
python3 - "$HOME" "$scratch/protect-production.sb" <<'PY'
import json, sys
from pathlib import Path
home, path = Path(sys.argv[1]), Path(sys.argv[2])
profile = ['(version 1)', '(allow default)']
for protected in (
    home/'Library'/'Group Containers'/'L4947CL6Q2.app.folio.reader',
    home/'Library'/'Application Support'/'Folio'
):
    for spelling in (str(protected), '/System/Volumes/Data'+str(protected)):
        profile.append('(deny file-write* (subpath '+json.dumps(spelling)+'))')
path.write_text('\n'.join(profile)+'\n')
PY

cat > "$scratch/fixture-server.py" <<'PY'
"""Threaded localhost-only EPUB server with monotonic request intervals."""
from html import escape
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from io import BytesIO
from pathlib import Path
from zipfile import ZipFile, ZIP_STORED
import json, sys, threading, time

root = Path(sys.argv[1])
events = root/'http-events.jsonl'
event_lock = threading.Lock()

def record(path, phase, status=None):
    with event_lock:
        with events.open('a', encoding='utf-8') as f:
            f.write(json.dumps({
                'path':path, 'phase':phase, 'status':status,
                'monotonic':time.monotonic(), 'wall':time.time()
            })+'\n')
            f.flush()

def epub(title, author, language):
    opf = f'''<?xml version="1.0" encoding="utf-8"?>
    <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="bookid">
      <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
        <dc:identifier id="bookid">synthetic-parallel-{escape(title)}-{language}</dc:identifier>
        <dc:title>{escape(title)}</dc:title><dc:creator>{escape(author)}</dc:creator>
        <dc:language>{language}</dc:language>
      </metadata>
      <manifest><item id="chapter" href="chapter.xhtml" media-type="application/xhtml+xml"/></manifest>
      <spine><itemref idref="chapter"/></spine>
    </package>'''
    container = '''<?xml version="1.0" encoding="utf-8"?>
    <container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0">
      <rootfiles><rootfile full-path="OPS/package.opf" media-type="application/oebps-package+xml"/></rootfiles>
    </container>'''
    chapter = f'''<?xml version="1.0" encoding="utf-8"?>
    <html xmlns="http://www.w3.org/1999/xhtml" xml:lang="{language}">
      <head><title>Original test chapter</title></head>
      <body><p>Original synthetic {escape(title)} {language}. Not a published book.</p></body></html>'''
    output = BytesIO()
    with ZipFile(output,'w') as z:
        z.writestr('mimetype','application/epub+zip', compress_type=ZIP_STORED)
        z.writestr('META-INF/container.xml',container)
        z.writestr('OPS/package.opf',opf)
        z.writestr('OPS/chapter.xhtml',chapter)
    return output.getvalue()

specs = {
    '/slow-atlas.epub': ('Slow Atlas', 'Case Author', 'en'),
    '/fast-brook.epub': ('Fast Brook', 'Case Author', 'en'),
    '/fast-cedar.epub': ('Fast Cedar', 'Case Author', 'en'),
    '/fast-dune.epub': ('Fast Dune', 'Case Author', 'en'),
    '/mixed-elm-wrong-de.epub': ('Mixed Elm', 'Case Author', 'de'),
    '/mixed-elm-right-en.epub': ('Mixed Elm', 'Case Author', 'en'),
    '/german-hazel-de.epub': ('German Hazel', 'Case Author', 'de'),
    '/german-hazel-en.epub': ('German Hazel', 'Case Author', 'en'),
    '/cancelled-grove.epub': ('Cancelled Grove', 'Case Author', 'en')
}
bytes_by_path = {path:epub(*meta) for path,meta in specs.items()}

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        path = self.path.split('?',1)[0]
        if path == '/ready':
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b'OK')
            return
        record(path,'start')
        if path == '/slow-atlas.epub':
            time.sleep(9.0)
        elif path.startswith('/fast-'):
            time.sleep(0.15)
        elif path == '/mixed-elm-wrong-de.epub':
            time.sleep(0.4)
        elif path == '/german-hazel-de.epub':
            time.sleep(0.2)
        if path == '/offline-fir.epub':
            status, mime, body = 503, 'text/plain', b'Original fixture: source unavailable (503)'
        elif path in bytes_by_path:
            status, mime, body = 200, 'application/epub+zip', bytes_by_path[path]
        else:
            status, mime, body = 404, 'text/plain', b'Not found'
        try:
            self.send_response(status)
            self.send_header('Content-Type',mime)
            self.send_header('Content-Length',str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        except (BrokenPipeError,ConnectionResetError):
            pass
        record(path,'end',status)

    def log_message(self, fmt, *args):
        print('HTTP:',fmt % args, flush=True)

server = ThreadingHTTPServer(('127.0.0.1',0),Handler)
(root/'port').write_text(str(server.server_address[1]))
server.serve_forever()
PY

python3 -u "$scratch/fixture-server.py" "$scratch" > "$scratch/server.log" 2>&1 &
server=$!
ready=0
for attempt in {1..100}; do
    if [[ -s "$scratch/port" ]]; then
        port=$(<"$scratch/port")
        if /usr/bin/curl --silent --fail --max-time 1 "http://127.0.0.1:$port/ready" >/dev/null; then
            ready=1
            break
        fi
    fi
    sleep 0.1
done
if [[ "$ready" != 1 ]]; then
    print -u2 'FAIL: localhost fixture server did not start'
    cat "$scratch/server.log" >&2
    exit 1
fi

cat > "$scratch/data/Extensions/parallel-local-fixture.js" <<JS
var source = {
  id:'parallel-local-fixture', name:'Parallel Queue Fixture',
  version:'1.0', description:'Isolated synthetic parallel EPUB fixture',
  allowedHosts:['http://127.0.0.1:$port'], settings:[],
  search:function(query) {
    var queryText=String(query).toLowerCase();
    var root='http://127.0.0.1:$port/';
    function copy(id,title,language,path,count) {
      return {id:id,title:title,authors:['Case Author'],language:language,
        downloadCount:count,origin:'synthetic localhost provider',
        downloads:[{format:'epub',url:root+path}]};
    }
    if (queryText.indexOf('slow atlas')>=0)
      return [copy('slow-atlas','Slow Atlas','en','slow-atlas.epub',100)];
    if (queryText.indexOf('fast brook')>=0)
      return [copy('fast-brook','Fast Brook','en','fast-brook.epub',99)];
    if (queryText.indexOf('fast cedar')>=0)
      return [copy('fast-cedar','Fast Cedar','en','fast-cedar.epub',98)];
    if (queryText.indexOf('fast dune')>=0)
      return [copy('fast-dune','Fast Dune','en','fast-dune.epub',97)];
    if (queryText.indexOf('mixed elm')>=0)
      return [
        copy('a-mixed-wrong','Mixed Elm','en','mixed-elm-wrong-de.epub',100),
        copy('b-mixed-right','Mixed Elm','en','mixed-elm-right-en.epub',10)
      ];
    if (queryText.indexOf('offline fir')>=0)
      return [copy('offline-fir','Offline Fir','en','offline-fir.epub',10)];
    if (queryText.indexOf('german hazel')>=0)
      return [
        copy('a-german-de','German Hazel','de','german-hazel-de.epub',100),
        copy('b-german-en','German Hazel','en','german-hazel-en.epub',10)
      ];
    if (queryText.indexOf('cancelled grove')>=0)
      return [copy('cancelled-grove','Cancelled Grove','en','cancelled-grove.epub',100)];
    return [];
  },
  recent:function(){return [];}
};
JS

python3 - "$scratch/data" <<'PY'
import json,sys,time,uuid
from pathlib import Path
root=Path(sys.argv[1])
settings={
    'parallel-local-fixture':{'file':'parallel-local-fixture.js','enabled':True,'builtIn':False,'config':{}},
    'demeter':{'file':'demeter.js','enabled':False,'builtIn':True,'config':{}},
    'gutenberg':{'file':'gutenberg.js','enabled':False,'builtIn':True,'config':{}}
}
(root/'Extensions'/'extensions.json').write_text(json.dumps(settings))
names=['Slow Atlas','Fast Brook','Fast Cedar','Fast Dune',
       'Mixed Elm','Offline Fir','German Hazel','Cancelled Grove']
now=time.time()-978307200
jobs=[{
    'id':str(uuid.uuid4()).upper(),'title':title,'author':'Case Author',
    'expectedLanguage':'en','cover':None,'hardcoverBookID':None,'hardcoverPages':None,
    'stage':('cancelled' if title=='Cancelled Grove' else 'queued'),
    'statusText':('Cancelled before startup' if title=='Cancelled Grove' else 'Queued for parallel E2E'),
    'detailLog':[],'error':None,'importedBookID':None,
    'createdAt':now+i,'updatedAt':now+i
} for i,title in enumerate(names)]
(root/'download-queue.json').write_text(json.dumps(jobs))
PY

echo 'Running signed Folio.app parallel queue E2E: seven queued jobs + one pre-cancelled…'
(
    cd "$app"
    HOME="$scratch/home" CFFIXED_USER_HOME="$scratch/home" \
      FOLIO_DATA_DIR="$scratch/data" FOLIO_SELECT_DOWNLOADING=1 \
      FOLIO_LAYER_CAPTURE=1 FOLIO_SHOT_FRAMES="${FOLIO_PARALLEL_TEST_FRAMES:-2100}" \
      /usr/bin/sandbox-exec -f "$scratch/protect-production.sb" \
      "$binary" --screenshot "$scratch/data/parallel-queue.png" \
      > "$scratch/folio.log" 2>&1
) || {
    print -u2 'FAIL: isolated signed Folio.app process errored'
    tail -80 "$scratch/folio.log" >&2
    exit 1
}

python3 - "$scratch" <<'PY'
import json,sys
from pathlib import Path
root=Path(sys.argv[1])
data=root/'data'
jobs={j['title']:j for j in json.loads((data/'download-queue.json').read_text())}
names=['Slow Atlas','Fast Brook','Fast Cedar','Fast Dune',
       'Mixed Elm','Offline Fir','German Hazel','Cancelled Grove']
assert set(jobs)==set(names), ('Unexpected queue entries',jobs)
assert all(j['expectedLanguage']=='en' for j in jobs.values()), 'Per-job language corrupted'
assert all(j['stage'] not in ['queued','searching','choosing','downloading','importing'] for j in jobs.values()), (
    'At least one queue job did not settle', {title:j['stage'] for title,j in jobs.items()})

completed={'Slow Atlas','Fast Brook','Fast Cedar','Fast Dune','Mixed Elm','German Hazel'}
for title in completed:
    j=jobs[title]
    assert j['stage']=='completed' and j.get('importedBookID'), ('Expected verified import',title,j)
failed=jobs['Offline Fir']
assert failed['stage']=='failed' and not failed.get('importedBookID'), failed
assert '503' in str(failed['detailLog']) or '503' in str(failed.get('error')), failed
cancelled=jobs['Cancelled Grove']
assert cancelled['stage']=='cancelled' and not cancelled.get('importedBookID'), cancelled

mixed='\n'.join(jobs['Mixed Elm']['detailLog'])
assert 'downloaded EPUB declares de, requested en' in mixed and 'temporary import removed' in mixed, mixed
assert 'Verified EPUB package language en matches requested en' in mixed, mixed
hazel='\n'.join(jobs['German Hazel']['detailLog'])
assert 'source language de differs from requested en' in hazel, hazel
assert 'Verified EPUB package language en matches requested en' in hazel, hazel

books=json.loads((data/'library.json').read_text()).get('books',[])
assert len(books)==len(completed), ('Wrong/failed/cancelled books contaminated library',books)
assert {b['title'] for b in books}==completed, books
for b in books:
    assert b['author']=='Case Author' and b.get('language')=='en', b
    assert b['id'].upper()==jobs[b['title']]['importedBookID'].upper(), b
files=list((data/'Files').glob('*.epub'))
extracted=[p for p in (data/'Extracted').iterdir() if p.is_dir()]
assert len(files)==len(completed) and len(extracted)==len(completed), (
    'Temporary/rejected files were not removed',files,extracted)
for folder in extracted:
    opf=folder/'OPS'/'package.opf'
    assert opf.is_file() and '<dc:language>en</dc:language>' in opf.read_text(), opf

events=[json.loads(line) for line in (root/'http-events.jsonl').read_text().splitlines()]
by_path={}
for ev in events:
    d=by_path.setdefault(ev['path'],{})
    assert ev['phase'] not in d, ('Duplicate request; inspect per-request lifecycle before relaxing',ev,d)
    d[ev['phase']]=ev
for path in (
    '/slow-atlas.epub','/fast-brook.epub','/fast-cedar.epub','/fast-dune.epub',
    '/mixed-elm-wrong-de.epub','/mixed-elm-right-en.epub',
    '/offline-fir.epub','/german-hazel-en.epub'
):
    d=by_path.get(path)
    assert d and {'start','end'}<=set(d), ('Expected HTTP request not completed',path,d)
    assert d['end']['monotonic']>=d['start']['monotonic'], ('Invalid timing',path,d)
assert by_path['/offline-fir.epub']['end']['status']==503
assert '/german-hazel-de.epub' not in by_path, 'German source was fetched despite requested EN'
assert '/cancelled-grove.epub' not in by_path, 'A persisted cancelled job was resumed without user action'

# A slow HTTP response MUST overlap another download. This assertion fails a
# sequential queue even if every job eventually reports completed.
slow_start=by_path['/slow-atlas.epub']['start']['monotonic']
slow_end=by_path['/slow-atlas.epub']['end']['monotonic']
slow_duration=slow_end-slow_start
assert slow_duration>=8.0, ('Slow test request was not actually slow',slow_duration)
fast=['/fast-brook.epub','/fast-cedar.epub','/fast-dune.epub']
overlaps=[path for path in fast if (
    slow_start < by_path[path]['start']['monotonic'] < by_path[path]['end']['monotonic'] < slow_end
)]
assert len(overlaps)>=2, (
    'No genuine parallelism: at least two short downloads must start and finish while Slow Atlas is still streaming',
    {'slow':(slow_start,slow_end),'fast':{path:(by_path[path]['start']['monotonic'],
                                          by_path[path]['end']['monotonic']) for path in fast}})
max_open=0
timeline=[]
for path,d in by_path.items():
    timeline.extend([(d['start']['monotonic'],1,path),(d['end']['monotonic'],-1,path)])
open_requests=0
for t,delta,path in sorted(timeline):
    open_requests+=delta
    max_open=max(max_open,open_requests)
assert max_open>=3, ('Fewer than three simultaneous HTTP requests',max_open)

print(f'PASS: {len(jobs)} durable signed-app jobs; {len(completed)} imported, 1 failed, 1 pre-cancelled')
print(f'PASS parallel overlap: slow request {slow_duration:.2f}s, fast downloads completed during slow: {", ".join(overlaps)}')
print(f'PASS HTTP max concurrent requests: {max_open}; no fast job blocked by slow transfer')
print('PASS: wrong OPF language removed; source DE skipped; no cancelled/failed book imported')
print('PASS: FOLIO_DATA_DIR + sandbox protected real app support/widget data; localhost-only synthetic EPUBs')
PY
