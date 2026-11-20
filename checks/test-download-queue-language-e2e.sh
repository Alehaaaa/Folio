#!/bin/zsh
# Integration regression: exercise the already-signed macOS Folio DownloadQueue.
# A provider's unknown language may conceal a German EPUB: reject its OPF and
# try a later English candidate. A German-only candidate must leave no book.
# Run from any directory: zsh checks/test-download-queue-language-e2e.sh
# Never uses the user's Folio library, downloads, network providers or account.
set -euo pipefail

here="${0:A:h}"
app="$here/../app"
binary="$app/Folio.app/Contents/MacOS/Folio"
scratch=$(mktemp -d "${TMPDIR:-/tmp/}folio-language-e2e.XXXXXXXX")
server=0
cleanup() {
    if [[ "$server" != 0 ]]; then kill "$server" 2>/dev/null || :; fi
    rm -rf -- "$scratch"
}
trap cleanup EXIT

if [[ ! -x "$binary" ]]; then
    echo "FAIL: signed Folio binary not found: $binary" >&2
    exit 1
fi

mkdir -p "$scratch/Extensions"
cat > "$scratch/fixture-server.py" <<'PY'
"""Ephemeral loopback-only, original synthetic public-domain EPUB fixtures."""
import io
import sys
from html import escape
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from zipfile import ZipFile, ZIP_STORED

root = Path(sys.argv[1])
book_specs = {
    '/epub/fallback-german.epub': ('Language Fallback', 'Case Author', 'de'),
    '/epub/fallback-english.epub': ('Language Fallback', 'Case Author', 'en'),
    '/epub/only-german.epub': ('Wrong Only', 'Case Author', 'de'),
    '/epub/declared-german.epub': ('Declared Wrong', 'Case Author', 'de'),
}

def make_epub(title, author, language):
    opf = f'''<?xml version="1.0" encoding="utf-8"?>
    <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="book-id">
      <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
        <dc:identifier id="book-id">test-folio-language-{language}</dc:identifier>
        <dc:title>{escape(title)}</dc:title>
        <dc:creator>{escape(author)}</dc:creator>
        <dc:language>{escape(language)}</dc:language>
      </metadata>
      <manifest><item id="chapter" href="chapter.xhtml" media-type="application/xhtml+xml"/></manifest>
      <spine><itemref idref="chapter"/></spine>
    </package>'''
    container = '''<?xml version="1.0" encoding="utf-8"?>
    <container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0">
      <rootfiles><rootfile full-path="OPS/package.opf" media-type="application/oebps-package+xml"/></rootfiles>
    </container>'''
    chapter = f'''<?xml version="1.0" encoding="utf-8"?>
    <html xmlns="http://www.w3.org/1999/xhtml" xml:lang="{language}"><head><title>Test</title></head>
    <body><p>Original synthetic language regression fixture: {escape(language)}</p></body></html>'''
    output = io.BytesIO()
    with ZipFile(output, 'w') as archive:
        archive.writestr('mimetype', 'application/epub+zip', compress_type=ZIP_STORED)
        archive.writestr('META-INF/container.xml', container)
        archive.writestr('OPS/package.opf', opf)
        archive.writestr('OPS/chapter.xhtml', chapter)
    return output.getvalue()

epubs = {route: make_epub(*spec) for route, spec in book_specs.items()}

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == '/ready':
            body = b'OK'
            self.send_response(200)
            self.send_header('Content-Type', 'text/plain')
        elif self.path in epubs:
            body = epubs[self.path]
            self.send_response(200)
            self.send_header('Content-Type', 'application/epub+zip')
        else:
            self.send_error(404)
            return
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        print('HTTP:', fmt % args, flush=True)

server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
(root / 'port.txt').write_text(str(server.server_address[1]))
server.serve_forever()
PY

python3 -u "$scratch/fixture-server.py" "$scratch" > "$scratch/server.log" 2>&1 &
server=$!
ready=0
for attempt in {1..100}; do
    if [[ -s "$scratch/port.txt" ]]; then
        port=$(<"$scratch/port.txt")
        if /usr/bin/curl --silent --fail --max-time 1 "http://127.0.0.1:$port/ready" >/dev/null; then
            ready=1
            break
        fi
    fi
    sleep 0.1
done
if [[ "$ready" != 1 ]]; then
    echo 'FAIL: loopback fixture server failed to start' >&2
    cat "$scratch/server.log" >&2
    exit 1
fi

cat > "$scratch/Extensions/language-queue-test.js" <<JS
// Local, synthetic EPUB fixtures; this script never reaches public sources.
var source = {
  id: 'language-queue-test',
  name: 'Language regression fixture',
  description: 'Loopback-only signed Folio language regression',
  version: '1.0',
  allowedHosts: ['http://127.0.0.1:$port'],
  settings: [],
  search: function (query) {
    var text = String(query).toLowerCase();
    var root = 'http://127.0.0.1:$port/epub/';
    function copy(id, title, language, count, filename) {
      return {id: id, title: title, authors: ['Case Author'],
        language: language, downloadCount: count,
        origin: 'synthetic public-domain fixture',
        downloads: [{format: 'epub', url: root + filename}]};
    }
    if (text.indexOf('language fallback') >= 0) {
      folio.log('Fixture: provider marks two editions unknown, but first OPF is German; third declares German');
      return [
        copy('a-unknown-german', 'Language Fallback', null, 900, 'fallback-german.epub'),
        copy('b-unknown-english', 'Language Fallback', null, 5, 'fallback-english.epub'),
        copy('c-declared-german', 'Language Fallback', 'de', 2000, 'declared-german.epub')
      ];
    }
    if (text.indexOf('wrong only') >= 0) {
      return [copy('a-sole-unknown-german', 'Wrong Only', null, 20, 'only-german.epub')];
    }
    if (text.indexOf('declared wrong') >= 0) {
      return [copy('a-explicit-german', 'Declared Wrong', 'de', 100, 'declared-german.epub')];
    }
    return [];
  },
  recent: function () { return []; }
};
JS

python3 - "$scratch" <<'PY'
import json, sys, time, uuid
from pathlib import Path
root = Path(sys.argv[1])
sources = {
    'language-queue-test': {'file': 'language-queue-test.js', 'enabled': True, 'builtIn': False, 'config': {}},
    'demeter': {'file': 'demeter.js', 'enabled': False, 'builtIn': True, 'config': {}},
    'gutenberg': {'file': 'gutenberg.js', 'enabled': False, 'builtIn': True, 'config': {}},
}
(root / 'Extensions' / 'extensions.json').write_text(json.dumps(sources))
now = time.time() - 978307200
titles = ['Language Fallback', 'Wrong Only', 'Declared Wrong']
jobs = [dict(
    id=str(uuid.uuid4()).upper(), title=title, author='Case Author',
    expectedLanguage='en', cover=None, hardcoverBookID=None, hardcoverPages=None,
    stage='queued', statusText='Queued in isolated test harness', detailLog=[],
    error=None, importedBookID=None, createdAt=now+i, updatedAt=now+i
) for i, title in enumerate(titles)]
(root / 'download-queue.json').write_text(json.dumps(jobs))
PY

# FOLIO_DATA_DIR is the ONLY persistent store for this signed app launch.
# The optional screenshot is written into the same throwaway directory.
# More frames allow the full queue/importer to finish and persist all jobs.
echo 'Testing signed Folio.app DownloadQueue with isolated synthetic OPF languages…'
(
    cd "$app"
    FOLIO_DATA_DIR="$scratch" FOLIO_SELECT_DOWNLOADING=1 \
      FOLIO_LAYER_CAPTURE=1 FOLIO_SHOT_FRAMES="${FOLIO_LANGUAGE_TEST_FRAMES:-1050}" \
      "$binary" --screenshot "$scratch/queue-language.png" \
      > "$scratch/folio.log" 2>&1
) || {
    echo 'FAIL: signed Folio process returned an error' >&2
    tail -70 "$scratch/folio.log" >&2
    exit 1
}

python3 - "$scratch" <<'PY'
import json, sys
from pathlib import Path

root = Path(sys.argv[1])
jobs_file = root / 'download-queue.json'
assert jobs_file.is_file(), 'Queue persistence missing'
jobs = {j['title']:j for j in json.loads(jobs_file.read_text())}
assert set(jobs) == {'Language Fallback', 'Wrong Only', 'Declared Wrong'}, jobs

def log_of(job):
    return '\n'.join(job['detailLog'])

fallback = jobs['Language Fallback']
assert fallback['stage'] == 'completed', 'Unknown German to English fallback was not completed: ' + repr(fallback)
assert fallback['importedBookID'], 'Successful fallback has no imported book ID'
log = log_of(fallback)
german = log.find('Trying Language regression fixture record a-unknown-german:')
english = log.find('Trying Language regression fixture record b-unknown-english:')
assert 0 <= german < english, 'Unknown-language candidates were not attempted German first, English next: ' + log
assert 'downloaded EPUB declares de, requested en' in log, 'German OPF rejection was not logged: ' + log
assert 'temporary import removed, trying next edition' in log, 'Temporary German import cleanup not recorded: ' + log
assert 'Verified EPUB package language en matches requested en' in log, 'English OPF verification was not logged: ' + log
assert 'c-declared-german' in log and 'source language de differs from requested en' in log, \
    'Explicitly German source record was not rejected during candidate selection: ' + log

sole = jobs['Wrong Only']
assert sole['stage'] == 'failed', 'Wrong-language-only job must fail: ' + repr(sole)
assert sole.get('importedBookID') is None, 'Wrong-language-only job left an imported ID'
sole_log = log_of(sole)
assert 'downloaded EPUB declares de, requested en' in sole_log, 'Sole German OPF was not actually validated: ' + sole_log
assert 'temporary import removed' in sole_log, 'Wrong-language-only temporary import was not removed: ' + sole_log

explicit = jobs['Declared Wrong']
assert explicit['stage'] == 'failed', 'Explicitly German-only job must fail: ' + repr(explicit)
assert explicit.get('importedBookID') is None, 'Explicitly German-only job has an imported ID'
assert ('No EPUB confirmed in en was found' in (explicit['error'] or '') or
        'No EPUB in requested language en was found' in (explicit['error'] or '')), explicit
assert 'source language de differs from requested en' in log_of(explicit), explicit

lib_file = root / 'library.json'
assert lib_file.is_file(), 'No library.json was persisted after the successful English import'
books = json.loads(lib_file.read_text()).get('books', [])
assert len(books) == 1, 'Rejected German files contaminated the isolated library: ' + repr(books)
book = books[0]
assert book['id'].upper() == fallback['importedBookID'].upper(), book
assert book['title'] == 'Language Fallback' and book['author'] == 'Case Author', book
assert book.get('language') == 'en', 'Persisted successful book language must be English: ' + repr(book)

files = list((root / 'Files').glob('*.epub'))
assert len(files) == 1, 'German EPUB files remained under Files/: ' + repr(files)
extracted = [p for p in (root / 'Extracted').iterdir() if p.is_dir()]
assert len(extracted) == 1, 'Rejected German EPUBs left extracted folders: ' + repr(extracted)
opf = extracted[0] / 'OPS' / 'package.opf'
assert opf.is_file() and '<dc:language>en</dc:language>' in opf.read_text(), 'Persisted EPUB OPF is not English'

server_log = (root / 'server.log').read_text()
for route in ['/epub/fallback-german.epub', '/epub/fallback-english.epub', '/epub/only-german.epub']:
    assert route in server_log, 'Expected actual HTTP EPUB GET missing: ' + route
assert '/epub/declared-german.epub' not in server_log, 'Explicitly German edition must be rejected without downloading'

print('PASS: signed Folio.app DownloadQueue with FOLIO_DATA_DIR isolated library')
print('  Unknown German EPUB: downloaded, OPF de rejected, temporary import removed')
print('  Next unknown English EPUB: downloaded, OPF en verified, queue completed')
print('  Wrong-language-only EPUB: OPF de rejected, queue failed, no library entry')
print('  Explicit German source record: rejected before GET, queue failed')
print('  Persisted library: exactly one English EPUB; rejected German files absent')
PY
