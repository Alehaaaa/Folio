#!/bin/zsh
# Actual signed macOS Folio DownloadQueue end-to-end availability/language tests.
# Run: /bin/zsh checks/test-source-availability-e2e.sh
#
# This uses ONLY original synthetic EPUB bytes served from 127.0.0.1, an
# isolated FOLIO_DATA_DIR, and two temporary source plugins. It does not access
# a real catalogue or the user's library. No production files are edited.
set -euo pipefail

here="${0:A:h}"
app="$here/../app"
binary="$app/Folio.app/Contents/MacOS/Folio"
scratch=$(mktemp -d "${TMPDIR:-/tmp/}folio-source-availability.XXXXXXXX")
server=0
cleanup() {
    if [[ "$server" != 0 ]]; then kill "$server" 2>/dev/null || :; fi
    rm -rf -- "$scratch"
}
trap cleanup EXIT

if [[ ! -x "$binary" ]] || ! /usr/bin/codesign --verify --deep --strict "$app/Folio.app" >/dev/null 2>&1; then
    print -u2 "FAIL: a valid signed Folio.app is required; no build or re-sign will be performed."
    exit 1
fi

mkdir -p "$scratch/home" "$scratch/data/Extensions"

# A normal FOLIO_DATA_DIR override covers LibraryStore but NOT WidgetKit's
# shared app-group snapshot. A narrow, additional macOS sandbox guard protects
# real user group/widget and Folio app-support files during the signed app run.
# Paths are built at runtime, not hard-coded to an individual's home directory.
python3 - "$HOME" "$scratch/protect-production.sb" <<'PY'
import json, sys
from pathlib import Path
home, output = Path(sys.argv[1]), Path(sys.argv[2])
group = home / 'Library' / 'Group Containers' / 'L4947CL6Q2.app.folio.reader'
support = home / 'Library' / 'Application Support' / 'Folio'
profile = ['(version 1)', '(allow default)']
for path in (group, support):
    # Protect the user-visible /Users/... path and its firmlink-resolved form.
    profile.append('(deny file-write* (subpath ' + json.dumps(str(path)) + '))')
    profile.append('(deny file-write* (subpath ' + json.dumps('/System/Volumes/Data' + str(path)) + '))')
output.write_text('\n'.join(profile) + '\n')
PY

# The fixture HTTP process is not sandboxed; only the signed Folio app is.
# It binds an ephemeral loopback port. No external destinations are served.
cat > "$scratch/fixture-server.py" <<'PY'
from html import escape
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from io import BytesIO
from pathlib import Path
from zipfile import ZipFile, ZIP_STORED
import sys

root = Path(sys.argv[1])
books = {
    '/epub/want-second.epub': ('Want', 'Case Author', 'en'),
    '/epub/language-second-en.epub': ('Language Choice', 'Case Author', 'en'),
    '/epub/language-first-de.epub': ('Language Choice', 'Case Author', 'de'),
    '/epub/german-selected-de.epub': ('German Selected', 'Case Author', 'de'),
    '/epub/german-selected-en.epub': ('German Selected', 'Case Author', 'en'),
    '/epub/opf-first-de.epub': ('OPF Fallback', 'Case Author', 'de'),
    '/epub/opf-second-en.epub': ('OPF Fallback', 'Case Author', 'en'),
}

def epub(title, author, language):
    opf = f'''<?xml version="1.0" encoding="utf-8"?>
    <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id">
      <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
        <dc:identifier id="id">synthetic-availability-{escape(title)}-{language}</dc:identifier>
        <dc:title>{escape(title)}</dc:title>
        <dc:creator>{escape(author)}</dc:creator>
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
      <head><title>Test chapter</title></head><body>
      <p>Original synthetic fixture for testing {escape(title)} in {language}.</p>
      </body></html>'''
    target = BytesIO()
    with ZipFile(target, 'w') as archive:
        archive.writestr('mimetype', 'application/epub+zip', compress_type=ZIP_STORED)
        archive.writestr('META-INF/container.xml', container)
        archive.writestr('OPS/package.opf', opf)
        archive.writestr('OPS/chapter.xhtml', chapter)
    return target.getvalue()

epubs = {path: epub(*data) for path, data in books.items()}

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == '/ready':
            code, mime, data = 200, 'text/plain', b'OK'
        elif self.path in epubs:
            code, mime, data = 200, 'application/epub+zip', epubs[self.path]
        elif self.path == '/epub/offline-primary.epub':
            code, mime, data = 503, 'text/plain', b'Partner temporarily unavailable'
        elif self.path == '/epub/offline-secondary.epub':
            code, mime, data = 404, 'text/plain', b'File not found'
        else:
            self.send_error(404)
            return
        self.send_response(code)
        self.send_header('Content-Type', mime)
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)
    def log_message(self, fmt, *args):
        print('HTTP:', fmt % args, flush=True)

server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
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
    print -u2 'FAIL: loopback fixture server did not start'
    cat "$scratch/server.log" >&2
    exit 1
fi

# Enabled source A sorts before enabled source B. Each represents an independent
# trusted localhost provider. No actual Anna/paid/mirror endpoints are used.
for name in primary secondary; do
    if [[ "$name" == primary ]]; then
        id='availability-01-primary'
        label='Primary Fixture'
    else
        id='availability-02-secondary'
        label='Secondary Fixture'
    fi
    cat > "$scratch/data/Extensions/$id.js" <<JS
var source = {
  id: '$id', name: '$label',
  description: 'Ephemeral localhost source-availability regression fixture',
  version: '1.0', settings: [],
  allowedHosts: ['http://127.0.0.1:$port'],
  search: function(query) {
    var text = String(query).toLowerCase();
    var base = 'http://127.0.0.1:$port/epub/';
    function result(id, title, language, filename) {
      return {
        id: id, title: title, authors: ['Case Author'],
        language: language, origin: '$label', downloadCount: 9,
        downloads: filename ? [{format: 'epub', url: base + filename}] : []
      };
    }
    if (text.indexOf('want') >= 0) {
      if ('$name' === 'primary') {
        folio.log('Want: credible catalogue record exists but has no downloadable link; continue other sources');
        return [result('want-no-link', 'Want', 'en', null)];
      }
      return [result('want-second-en', 'Want', 'en', 'want-second.epub')];
    }
    if (text.indexOf('language choice') >= 0) {
      return '$name' === 'primary'
        ? [result('language-de', 'Language Choice', 'de', 'language-first-de.epub')]
        : [result('language-en', 'Language Choice', 'en', 'language-second-en.epub')];
    }
    if (text.indexOf('german selected') >= 0) {
      return '$name' === 'primary'
        ? [result('chosen-de', 'German Selected', 'de', 'german-selected-de.epub')]
        : [result('not-chosen-en', 'German Selected', 'en', 'german-selected-en.epub')];
    }
    if (text.indexOf('opf fallback') >= 0) {
      // Both catalogues claim EN. The first EPUB OPF declares DE instead.
      return '$name' === 'primary'
        ? [result('opf-lying-en', 'OPF Fallback', 'en', 'opf-first-de.epub')]
        : [result('opf-real-en', 'OPF Fallback', 'en', 'opf-second-en.epub')];
    }
    if (text.indexOf('no accessible') >= 0) {
      folio.log('No Accessible: known matching listing, but no downloadable free EPUB partner link');
      throw new Error('Search worked, but free EPUB partner links could not be resolved (no downloadable links)');
    }
    if (text.indexOf('offline links') >= 0) {
      return '$name' === 'primary'
        ? [result('offline-primary', 'Offline Links', 'en', 'offline-primary.epub')]
        : [result('offline-secondary', 'Offline Links', 'en', 'offline-secondary.epub')];
    }
    return [];
  },
  recent: function() { return []; }
};
JS
done

python3 - "$scratch/data" <<'PY'
import json, sys, time, uuid
from pathlib import Path
root = Path(sys.argv[1])
settings = {
    id: {'file': id+'.js', 'enabled': True, 'builtIn': False, 'config': {}}
    for id in ('availability-01-primary', 'availability-02-secondary')
}
settings.update({
    'demeter': {'file':'demeter.js', 'enabled':False, 'builtIn':True, 'config':{}},
    'gutenberg': {'file':'gutenberg.js', 'enabled':False, 'builtIn':True, 'config':{}}
})
(root/'Extensions'/'extensions.json').write_text(json.dumps(settings))
titles = ('Want', 'Language Choice', 'OPF Fallback', 'No Accessible', 'Offline Links', 'German Selected')
now = time.time() - 978307200
jobs = [{
    'id': str(uuid.uuid4()).upper(), 'title':title, 'author':'Case Author',
    'expectedLanguage':('de' if title == 'German Selected' else 'en'),
    'cover':None, 'hardcoverBookID':None, 'hardcoverPages':None,
    'stage':'queued', 'statusText':'Awaiting isolated availability E2E', 'detailLog':[],
    'error':None, 'importedBookID':None, 'createdAt':now+i, 'updatedAt':now+i
} for i,title in enumerate(titles)]
(root/'download-queue.json').write_text(json.dumps(jobs))
PY

# All persistent Folio state goes to temp FOLIO_DATA_DIR. The secondary OS
# sandbox prevents App Group widget and real Folio Application Support writes.
# A throwaway HOME also avoids transient user preferences outside this test.
echo 'Running signed Folio.app with six isolated source-availability jobs…'
(
    cd "$app"
    HOME="$scratch/home" CFFIXED_USER_HOME="$scratch/home" \
      FOLIO_DATA_DIR="$scratch/data" FOLIO_SELECT_DOWNLOADING=1 \
      FOLIO_LAYER_CAPTURE=1 FOLIO_SHOT_FRAMES="${FOLIO_AVAILABILITY_TEST_FRAMES:-1800}" \
      /usr/bin/sandbox-exec -f "$scratch/protect-production.sb" \
      "$binary" --screenshot "$scratch/data/snapshot.png" \
      > "$scratch/folio.log" 2>&1
) || {
    print -u2 'FAIL: signed Folio.app failed to launch or complete its isolated test window'
    tail -80 "$scratch/folio.log" >&2
    exit 1
}

python3 - "$scratch" <<'PY'
import json, sys
from pathlib import Path
root = Path(sys.argv[1])
data = root/'data'
jobs = {j['title']:j for j in json.loads((data/'download-queue.json').read_text())}
expected_titles = {'Want','Language Choice','OPF Fallback','No Accessible','Offline Links','German Selected'}
assert set(jobs) == expected_titles, ('Unexpected jobs', jobs)
assert all(job['expectedLanguage'] == ('de' if title == 'German Selected' else 'en')
           for title,job in jobs.items()), 'Explicit language selection not preserved in jobs: '+repr(jobs)
def log(job): return '\n'.join(job.get('detailLog',[]))

# (1) The first source has a genuine title/author EN listing but zero links.
# Search must continue to the second independent source and import its EPUB.
want = jobs['Want']
assert want['stage'] == 'completed' and want.get('importedBookID'), ('Want fallback failed', want)
assert 'Trying Secondary Fixture record want-second-en:' in log(want), log(want)
assert 'Trying Primary Fixture record want-no-link:' not in log(want), log(want)
assert 'no downloadable link' in log(want).lower(), 'First source availability failure not diagnosed: '+log(want)

# (2) The source declares German; never fetch or import it when EN requested.
pair = jobs['Language Choice']
assert pair['stage'] == 'completed' and pair.get('importedBookID'), ('Language choice failed', pair)
assert 'source language de differs from requested en' in log(pair), log(pair)
assert 'Trying Secondary Fixture record language-en:' in log(pair), log(pair)
assert 'Trying Primary Fixture record language-de:' not in log(pair), log(pair)

# (3) Source EN is untrusted until OPF checked; remove a German import, then
# fall through to the next English provider rather than ending the whole queue.
opf = jobs['OPF Fallback']
assert opf['stage'] == 'completed' and opf.get('importedBookID'), ('OPF fallback failed', opf)
report = log(opf)
first = report.find('Trying Primary Fixture record opf-lying-en:')
second = report.find('Trying Secondary Fixture record opf-real-en:')
assert 0 <= first < second, 'Expected first DE OPF then second EN source, in that order: '+report
assert 'downloaded EPUB declares de, requested en' in report, report
assert 'temporary import removed, trying next edition' in report, report
assert 'Verified EPUB package language en matches requested en' in report, report

# (4a) No free partner URLs despite catalogue hits yields an actionable reason,
# not a false title/author/language mismatch and not a phantom library entry.
missing = jobs['No Accessible']
assert missing['stage'] == 'failed' and not missing.get('importedBookID'), missing
reason = (missing.get('error') or '').lower()
# Signed bundles can precede the newest Swift error wording while the prime
# rebuilds. In either version the *persisted user-facing error* must explicitly
# identify source/link availability rather than silently failing or treating
# the book as a title or language mismatch.
assert ('no accessible free epub link' in reason or
        'no downloadable links' in reason or
        'partner links could not be resolved' in reason), missing
assert 'no downloadable links' in log(missing).lower(), log(missing)
assert 'error:' in log(missing).lower(), log(missing)
assert 'matching book listings exist' in reason and 'no accessible free epub link' in reason, (
    'New signed Folio build must classify unavailable matching free links as availability, not title/language mismatch', missing)

# (4b) Accessible-looking HTTP links that fail as 503 and 404 also must fail,
# without creating a library entry or silently claiming success.
offline = jobs['Offline Links']
assert offline['stage'] == 'failed' and not offline.get('importedBookID'), offline
assert 'No matching EPUB could be downloaded' in (offline.get('error') or ''), offline
assert 'Trying Primary Fixture record offline-primary:' in log(offline), log(offline)
assert 'Trying Secondary Fixture record offline-secondary:' in log(offline), log(offline)
assert any(token in log(offline).lower() for token in ('503','404','unavailable')), log(offline)

# Explicit language selection is per-job: this request is DE, unlike the five
# other EN jobs, and must accept DE while skipping a simultaneous EN candidate.
german = jobs['German Selected']
assert german['stage'] == 'completed' and german.get('importedBookID'), ('Explicitly chosen German edition failed', german)
assert german['expectedLanguage'] == 'de', german
assert 'Trying Primary Fixture record chosen-de:' in log(german), log(german)
assert 'source language en differs from requested de' in log(german), log(german)
assert 'Trying Secondary Fixture record not-chosen-en:' not in log(german), log(german)
assert 'Verified EPUB package language de matches requested de' in log(german), log(german)

# Nothing in the local library may survive except three EN and one explicitly
# selected DE book. Rejected OPF-DE from an EN job must not remain.
lib = data/'library.json'
assert lib.is_file(), 'Successful queue imports did not persist library.json'
books = json.loads(lib.read_text()).get('books', [])
assert len(books) == 4, 'Failed or rejected EPUB contaminated the isolated library: '+repr(books)
assert {b['title'] for b in books} == {'Want','Language Choice','OPF Fallback','German Selected'}, books
for title in ('Want','Language Choice','OPF Fallback','German Selected'):
    job = jobs[title]
    entry = next(b for b in books if b['title']==title)
    assert entry['id'].upper() == job['importedBookID'].upper(), (title, entry, job)
    expected_lang = 'de' if title == 'German Selected' else 'en'
    assert entry['author']=='Case Author' and entry.get('language')==expected_lang, (title,entry)
files = list((data/'Files').glob('*.epub'))
assert len(files) == 4, 'Wrong-language or failed files remain in Files/: '+repr(files)
extracted = [p for p in (data/'Extracted').iterdir() if p.is_dir()]
assert len(extracted)==4, 'Rejected temporary import was not removed: '+repr(extracted)
for folder in extracted:
    opf = folder/'OPS'/'package.opf'
    assert opf.is_file(), opf
    text = opf.read_text()
    # All remaining extracted packages must belong to accepted known books.
    assert ('<dc:language>en</dc:language>' in text or '<dc:language>de</dc:language>' in text), opf
    if '<dc:language>de</dc:language>' in text:
        assert '<dc:title>German Selected</dc:title>' in text, 'Rejected OPF-DE candidate survived: '+str(opf)

# Verify HTTP traffic: actual EPUB downloads, and no request for the advertised
# German edition that should have been rejected at the source-metadata stage.
http = (root/'server.log').read_text()
for path,status in (
    ('want-second.epub',200), ('language-second-en.epub',200),
    ('opf-first-de.epub',200), ('opf-second-en.epub',200), ('german-selected-de.epub',200),
    ('offline-primary.epub',503), ('offline-secondary.epub',404)
):
    assert 'GET /epub/'+path+' HTTP/1.1" '+str(status) in http, (path, http)
assert 'GET /epub/language-first-de.epub HTTP/1.1' not in http, 'Declared DE source was fetched: '+http
assert 'GET /epub/german-selected-en.epub HTTP/1.1' not in http, 'EN source was fetched for the explicitly DE job: '+http

print('PASS (1): Want — first credible source has no file link; second source downloads a verified EN EPUB')
print('PASS (2): DE source edition skipped before HTTP; available EN edition imported')
print('PASS (3): source claims EN / OPF declares DE; bad import removed and next EN copy imported')
print('PASS (4): no free link or HTTP 503/404 -> clear failed state, no extra imported books')
print('PASS (5): expectedLanguage=de persisted in its own job; accepted DE EPUB and skipped EN edition')
print('PASS: signed Folio DownloadQueue, 6 jobs; exactly 3 EN + 1 explicitly chosen DE EPUB in isolated FOLIO_DATA_DIR')
print('PASS: actual localhost HTTP responses verified; production widget/app support writes sandbox-denied')
PY
