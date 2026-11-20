#!/bin/zsh
# Test the *signed* macOS Folio DownloadQueue with Iron Gold's real-world
# catalogue aliases, but only original synthetic localhost EPUBs.
# Does not modify any app/extension sources or the user's library.
# Run: /bin/zsh checks/test-iron-gold-edition-e2e.sh
set -euo pipefail

here="${0:A:h}"
app="$here/../app"
binary="$app/Folio.app/Contents/MacOS/Folio"
scratch=$(mktemp -d "${TMPDIR:-/tmp/}folio-iron-gold-e2e.XXXXXXXX")
server=0
cleanup() {
    if [[ "$server" != 0 ]]; then kill "$server" 2>/dev/null || :; fi
    rm -rf -- "$scratch"
}
trap cleanup EXIT

if [[ ! -x "$binary" ]]; then
    print -u2 "FAIL: Signed Folio binary is missing: $binary"
    exit 1
fi
if ! /usr/bin/codesign --verify --deep --strict "$app/Folio.app" >/dev/null 2>&1; then
    print -u2 "FAIL: Folio.app is not currently signed and verified; refusing to run a different executable."
    exit 1
fi

# Ephemeral HTTP fixture server binds only 127.0.0.1. All EPUBs contain
# original synthetic prose, not any material from the actual novel.
cat > "$scratch/fixture.py" <<'PY'
import io
import sys
from html import escape
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from zipfile import ZipFile, ZIP_STORED

root = Path(sys.argv[1])
specs = {
    '/valid.epub': ('Iron Gold', 'Brown, Pierce', 'en'),
    '/bundle.epub': ('Iron Gold: Books 1-3 Bundle', 'Brown, Pierce', 'en'),
    '/excerpt.epub': ('Iron Gold: Book 4 - Preview Excerpt', 'Brown, Pierce', 'en'),
    # Deliberately misleading source metadata for an EPUB that is only a preview.
    '/mislabelled.epub': ('Iron Gold: Preview Excerpt', 'Brown, Pierce', 'en'),
}

def make_epub(title, author, lang):
    metadata = f'''<?xml version="1.0" encoding="utf-8"?>
    <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="bookid">
      <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
        <dc:identifier id="bookid">folio-original-iron-gold-test-{escape(title)}</dc:identifier>
        <dc:title>{escape(title)}</dc:title>
        <dc:creator>{escape(author)}</dc:creator>
        <dc:language>{lang}</dc:language>
      </metadata>
      <manifest>
        <item id="chapter1" href="chapter.xhtml" media-type="application/xhtml+xml"/>
      </manifest>
      <spine><itemref idref="chapter1"/></spine>
    </package>'''
    container = '''<?xml version="1.0" encoding="utf-8"?>
    <container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0">
      <rootfiles><rootfile full-path="OPS/package.opf" media-type="application/oebps-package+xml"/></rootfiles>
    </container>'''
    chapter = f'''<?xml version="1.0" encoding="utf-8"?>
    <html xmlns="http://www.w3.org/1999/xhtml"><head><title>Original test chapter</title></head>
    <body><p>Original synthetic data for {escape(title)}. Not text from the novel.</p></body></html>'''
    out = io.BytesIO()
    with ZipFile(out, 'w') as epub:
        epub.writestr('mimetype', 'application/epub+zip', compress_type=ZIP_STORED)
        epub.writestr('META-INF/container.xml', container)
        epub.writestr('OPS/package.opf', metadata)
        epub.writestr('OPS/chapter.xhtml', chapter)
    return out.getvalue()

payloads = {p: make_epub(*details) for p, details in specs.items()}
class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == '/ready':
            payload, mime = b'ready', 'text/plain'
        elif self.path in payloads:
            payload, mime = payloads[self.path], 'application/epub+zip'
        else:
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header('Content-Type', mime)
        self.send_header('Content-Length', str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)
    def log_message(self, fmt, *args):
        print('HTTP:', fmt % args, flush=True)

server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
(root/'port').write_text(str(server.server_address[1]))
server.serve_forever()
PY

python3 -u "$scratch/fixture.py" "$scratch" > "$scratch/server.log" 2>&1 &
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
    print -u2 'FAIL: loopback fixture server did not start.'
    cat "$scratch/server.log" >&2
    exit 1
fi

for mode in positive negative; do
    data="$scratch/$mode"
    mkdir -p "$data/Extensions"

    # Tests the actual source search/selection contract. High provider
    # download counts for bundle/excerpt should not override edition checks.
    cat > "$data/Extensions/iron-gold-fixture.js" <<JS
var source = {
  id: 'iron-gold-fixture',
  name: 'Iron Gold Local Test',
  description: 'Local public-domain-style regression fixture (no real novel)',
  version: '1.0',
  allowedHosts: ['http://127.0.0.1:$port'],
  settings: [],
  search: function (query, page) {
    if (String(query).toLowerCase().indexOf('iron gold') < 0) return [];
    var url = 'http://127.0.0.1:$port/';
    function copy(id, title, filename, popularity) {
      return {
        id: id, title: title, authors: ['Brown, Pierce Pierce Brown'],
        language: 'en', downloadCount: popularity,
        origin: 'localhost EPUB edition fixture',
        downloads: [{format: 'epub', url: url + filename}]
      };
    }
    folio.log('Fixture $mode: search='+query+'; canonical target Iron Gold by Pierce Brown, language en');
    if ('$mode' === 'positive') {
      return [
        copy('a-bundle', 'Iron Gold: Books 1-3 Bundle', 'bundle.epub', 999999),
        copy('b-excerpt', 'Iron Gold: Book 4 of the Red Rising Saga - Preview Excerpt', 'excerpt.epub', 999998),
        copy('z-canonical', 'Iron Gold: Book 4 of the Red Rising Saga', 'valid.epub', 1)
      ];
    }
    return [
      copy('a-bundle', 'Iron Gold: Books 1-3 Bundle', 'bundle.epub', 999999),
      copy('b-excerpt', 'Iron Gold: Book 4 of the Red Rising Saga - Preview Excerpt', 'excerpt.epub', 999998),
      // The catalogue says full Iron Gold; OPF correctly reveals an excerpt.
      copy('z-mislabelled', 'Iron Gold: Book 4 of the Red Rising Saga', 'mislabelled.epub', 1)
    ];
  },
  recent: function () { return []; }
};
JS

    python3 - "$data" <<'PY'
import json, sys, time, uuid
from pathlib import Path
dir = Path(sys.argv[1])
(dir/'Extensions'/'extensions.json').write_text(json.dumps({
    'iron-gold-fixture': {'file':'iron-gold-fixture.js','enabled':True,'builtIn':False,'config':{}},
    'demeter': {'file':'demeter.js','enabled':False,'builtIn':True,'config':{}},
    'gutenberg': {'file':'gutenberg.js','enabled':False,'builtIn':True,'config':{}}
}))
now = time.time() - 978307200
(dir/'download-queue.json').write_text(json.dumps([{
    'id':str(uuid.uuid4()).upper(), 'title':'Iron Gold', 'author':'Pierce Brown',
    'expectedLanguage':'en', 'cover':None, 'hardcoverBookID':None, 'hardcoverPages':None,
    'stage':'queued', 'statusText':'Queued for signed app E2E', 'detailLog':[],
    'error':None, 'importedBookID':None, 'createdAt':now, 'updatedAt':now
}]))
PY

    echo "Running isolated signed Folio edition E2E: $mode"
    (
        cd "$app"
        FOLIO_DATA_DIR="$data" FOLIO_SELECT_DOWNLOADING=1 \
          FOLIO_LAYER_CAPTURE=1 FOLIO_SHOT_FRAMES="${FOLIO_IRON_GOLD_TEST_FRAMES:-850}" \
          "$binary" --screenshot "$data/snapshot.png" > "$data/folio.log" 2>&1
    ) || {
        print -u2 "FAIL: signed Folio process failed in $mode"
        tail -70 "$data/folio.log" >&2
        exit 1
    }

    python3 - "$data" "$mode" <<'PY'
import json, sys
from pathlib import Path
root, mode = Path(sys.argv[1]), sys.argv[2]
jobs = json.loads((root/'download-queue.json').read_text())
assert len(jobs) == 1, f'Unexpected job count: {jobs}'
job = jobs[0]
log = '\n'.join(job['detailLog'])
assert job['expectedLanguage'] == 'en', job
assert job['title'] == 'Iron Gold' and job['author'] == 'Pierce Brown', job
assert 'Iron Gold Local Test' in log, 'The synthetic provider did not run: ' + log
assert 'Book 4 of the Red Rising Saga' in log, 'The rich source edition title was not passed to Folio: ' + log
assert 'Brown, Pierce Pierce Brown' in log, 'Duplicated Brown author metadata was not passed through: ' + log
assert 'a-bundle' not in log or 'Trying Iron Gold Local Test record a-bundle:' not in log, 'Bundle was auto-selected'
assert 'b-excerpt' not in log or 'Trying Iron Gold Local Test record b-excerpt:' not in log, 'Excerpt was auto-selected'

books = json.loads((root/'library.json').read_text()).get('books', []) if (root/'library.json').exists() else []
files = list((root/'Files').glob('*.epub'))
folders = list((root/'Extracted').iterdir()) if (root/'Extracted').exists() else []
if mode == 'positive':
    assert job['stage'] == 'completed' and job.get('importedBookID'), 'Canonical Iron Gold did not import: ' + repr(job)
    assert 'Trying Iron Gold Local Test record z-canonical:' in log, 'Correct rich-title edition was not chosen: ' + log
    assert 'Verified EPUB package language en matches requested en' in log, log
    assert len(books) == 1 and len(files) == 1 and len(folders) == 1, 'Incorrect library content: ' + repr(books)
    book = books[0]
    assert book['id'].upper() == job['importedBookID'].upper(), (book, job)
    assert book['title'] == 'Iron Gold', book
    assert book['author'] == 'Brown, Pierce', book
    assert book.get('language') == 'en', book
    assert '<dc:title>Iron Gold</dc:title>' in (folders[0]/'OPS/package.opf').read_text()
    assert '<dc:creator>Brown, Pierce</dc:creator>' in (folders[0]/'OPS/package.opf').read_text()
    print('PASS positive: rich source title + duplicate author -> canonical English Iron Gold OPF, exactly one imported book')
else:
    assert job['stage'] == 'failed' and not job.get('importedBookID'), 'Bad excerpt incorrectly accepted: ' + repr(job)
    assert 'Trying Iron Gold Local Test record z-mislabelled:' in log, 'Mislabelled excerpt was not actually inspected: ' + log
    assert 'Imported EPUB metadata did not match Iron Gold' in log, 'OPF excerpt was not rejected: ' + log
    assert len(books) == 0 and len(files) == 0 and len(folders) == 0, 'Rejected excerpt contaminated library: ' + repr(books)
    print('PASS negative: bundle/excerpt metadata excluded; mislabelled excerpt OPF rejected, no library entry')
PY
done

# Double-check real HTTP GETs, rather than trusting only queue text.
python3 - "$scratch/server.log" <<'PY'
import sys
from pathlib import Path
s = Path(sys.argv[1]).read_text()
for path in ('/valid.epub', '/mislabelled.epub'):
    assert 'GET '+path+' HTTP/1.1" 200' in s, f'Missing signed app GET: {path} — {s}'
for path in ('/bundle.epub', '/excerpt.epub'):
    assert 'GET '+path+' HTTP/1.1"' not in s, f'Unsafe candidate was downloaded: {path} — {s}'
print('PASS HTTP: only canonical and deliberately mislabelled test EPUB fetched; bundle/excerpt catalogues blocked before GET')
print('PASS: both isolated signed Folio.app E2E scenarios; the user library was never accessed')
PY
