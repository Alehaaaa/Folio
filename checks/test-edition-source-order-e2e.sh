#!/bin/zsh
# End-to-end: the real Folio.app download queue with an isolated FOLIO_DATA_DIR,
# loopback-only fixture sources and original synthetic EPUBs.
#  1. A download picked as a translated edition ("Puerto de Cristal" for the work
#     "Glass Harbor") is found under the edition title with no metadata lookups,
#     verified, and taken from the source made for that language even though a
#     general source sorts first.
#  2. Between two general sources with equal copies, the reader's source order
#     (by name when unset) wins, not the source ID.
# Never touches the user's library, settings, accounts or public providers.
set -euo pipefail

here="${0:A:h}"
binary="${FOLIO_BINARY:-$here/../app/.build/release/Folio}"
scratch=$(mktemp -d "${TMPDIR:-/tmp/}folio-edition-order.XXXXXXXX")
server=0
cleanup() {
    if [[ "$server" != 0 ]]; then kill "$server" 2>/dev/null || :; fi
    rm -rf -- "$scratch"
}
trap cleanup EXIT
[[ -x "$binary" ]] || { echo "FAIL: Folio binary not found: $binary" >&2; exit 1; }
mkdir -p "$scratch/Extensions"

cat > "$scratch/fixture-server.py" <<'PY'
"""Loopback-only server for original synthetic EPUBs."""
import io, sys
from html import escape
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from zipfile import ZipFile, ZIP_STORED
root = Path(sys.argv[1])
specs = {
    '/epub/puerto-general.epub': ('Puerto de Cristal', 'Mara Quill', 'es'),
    '/epub/puerto-spanish.epub': ('Puerto de Cristal', 'Mara Quill', 'es'),
    '/epub/lantern-alpha.epub': ('Lantern Field', 'Mara Quill', 'en'),
    '/epub/lantern-beta.epub': ('Lantern Field', 'Mara Quill', 'en'),
}
def make(title, author, lang):
    opf = f'''<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id">
<metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="id">folio-fixture-{escape(title)}</dc:identifier>
<dc:title>{escape(title)}</dc:title><dc:creator>{escape(author)}</dc:creator><dc:language>{lang}</dc:language></metadata>
<manifest><item id="c" href="c.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="c"/></spine></package>'''
    container = '''<?xml version="1.0"?><container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0">
<rootfiles><rootfile full-path="OPS/package.opf" media-type="application/oebps-package+xml"/></rootfiles></container>'''
    chapter = f'<html xmlns="http://www.w3.org/1999/xhtml"><body><p>Synthetic fixture {lang}</p></body></html>'
    out = io.BytesIO()
    with ZipFile(out, 'w') as z:
        z.writestr('mimetype', 'application/epub+zip', compress_type=ZIP_STORED)
        z.writestr('META-INF/container.xml', container)
        z.writestr('OPS/package.opf', opf)
        z.writestr('OPS/c.xhtml', chapter)
    return out.getvalue()
epubs = {k: make(*v) for k, v in specs.items()}
class H(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == '/ready': body = b'OK'; self.send_response(200)
        elif self.path in epubs: body = epubs[self.path]; self.send_response(200); self.send_header('Content-Type', 'application/epub+zip')
        else: self.send_error(404); return
        self.send_header('Content-Length', str(len(body))); self.end_headers(); self.wfile.write(body)
    def log_message(self, fmt, *args): print('HTTP:', fmt % args, flush=True)
s = ThreadingHTTPServer(('127.0.0.1', 0), H)
(root / 'port.txt').write_text(str(s.server_address[1]))
s.serve_forever()
PY
python3 -u "$scratch/fixture-server.py" "$scratch" > "$scratch/server.log" 2>&1 &
server=$!
for attempt in {1..100}; do
    [[ -s "$scratch/port.txt" ]] && /usr/bin/curl -sf --max-time 1 "http://127.0.0.1:$(<"$scratch/port.txt")/ready" >/dev/null && break
    sleep 0.1
done
port=$(<"$scratch/port.txt")

# id order and name order disagree on purpose: aa-beta sorts first by ID,
# "Alpha fixture" first by name. The Spanish-only source sorts last by both.
make_source() { # id name languages lanternFile puertoFile
cat > "$scratch/Extensions/$1.js" <<JS
var source = {
  id: '$1', name: '$2', description: 'Loopback-only Folio fixture', version: '1.0',
  languages: $3, allowedHosts: ['http://127.0.0.1:$port'], settings: [],
  search: function (query) {
    var q = String(query).toLowerCase(), root = 'http://127.0.0.1:$port/epub/';
    function copy(id, title, lang, file) {
      return {id: id, title: title, authors: ['Mara Quill'], language: lang,
              origin: 'synthetic fixture', downloads: [{format: 'epub', url: root + file}]};
    }
    if (q.indexOf('puerto de cristal') >= 0 && '$5') return [copy('$1-puerto', 'Puerto de Cristal', 'es', '$5')];
    if (q.indexOf('lantern field') >= 0 && '$4') return [copy('$1-lantern', 'Lantern Field', 'en', '$4')];
    return [];
  },
  recent: function () { return []; }
};
JS
}
make_source aa-beta  'Beta fixture'    '["*"]'  lantern-beta.epub  puerto-general.epub
make_source zz-alpha 'Alpha fixture'   '["*"]'  lantern-alpha.epub ''
make_source zz-spanish 'Zeta Spanish fixture' '["es"]' '' puerto-spanish.epub

python3 - "$scratch" <<'PY'
import json, sys, time, uuid
from pathlib import Path
root = Path(sys.argv[1])
ext = {i: {'file': i + '.js', 'enabled': True, 'builtIn': False, 'config': {}}
       for i in ['aa-beta', 'zz-alpha', 'zz-spanish']}
# Every real source stays off, and managed ones are marked as already present so
# the app never installs or searches them: only loopback fixtures run.
for i in ['demeter', 'gutenberg']:
    ext[i] = {'file': i + '.js', 'enabled': False, 'builtIn': True, 'config': {}}
for i in ['annas-archive-free', 'lectulandia']:
    ext[i] = {'file': i + '.js', 'enabled': False, 'builtIn': False, 'config': {}}
(root / 'Extensions' / 'extensions.json').write_text(json.dumps(ext))
now = time.time() - 978307200
def job(i, title, lang, edition=None):
    j = dict(id=str(uuid.uuid4()).upper(), title=title, author='Mara Quill', expectedLanguage=lang,
             cover=None, hardcoverBookID=None, hardcoverPages=None, stage='queued',
             statusText='Queued in isolated test', detailLog=[], error=None, importedBookID=None,
             createdAt=now + i, updatedAt=now + i)
    if edition: j['editionTitle'] = edition
    return j
(root / 'download-queue.json').write_text(json.dumps([
    job(0, 'Glass Harbor', 'es', 'Puerto de Cristal'),
    job(1, 'Lantern Field', 'en'),
]))
PY

echo 'Testing Folio.app: translated edition title and source order…'
(
    FOLIO_DATA_DIR="$scratch" FOLIO_SELECT_DOWNLOADING=1 FOLIO_LAYER_CAPTURE=1 \
      FOLIO_SHOT_FRAMES="${FOLIO_TEST_FRAMES:-900}" \
      "$binary" --screenshot "$scratch/shot.png" > "$scratch/folio.log" 2>&1
) || { echo 'FAIL: Folio exited with an error' >&2; tail -40 "$scratch/folio.log" >&2; exit 1; }

python3 - "$scratch" <<'PY'
import json, sys
from pathlib import Path
root = Path(sys.argv[1])
jobs = {j['title']: j for j in json.loads((root / 'download-queue.json').read_text())}
log = lambda j: '\n'.join(j['detailLog'])

glass = jobs['Glass Harbor']
gl = log(glass)
assert glass['stage'] == 'completed', 'Translated edition download did not complete:\n' + gl + '\n' + repr(glass.get('error'))
assert glass.get('editionTitle') == 'Puerto de Cristal', glass
assert 'Edition chosen on the book page: Puerto de Cristal' in gl, gl
assert 'Open Library' not in gl, 'A chosen edition must not trigger metadata lookups:\n' + gl
assert 'Trying Zeta Spanish fixture record zz-spanish-puerto' in gl, 'Spanish-only source was not tried first:\n' + gl
assert 'Trying Beta fixture' not in gl, 'General source was tried before the language source succeeded:\n' + gl
for name in ["Anna's Archive", 'Lectulandia', 'Project Gutenberg']:
    assert 'Searching ' + name not in gl, 'A real source was searched in the isolated test: ' + name

lantern = jobs['Lantern Field']
ll = log(lantern)
assert lantern['stage'] == 'completed', ll
assert 'Trying Alpha fixture record zz-alpha-lantern' in ll, 'Source order (by name) did not win over ID order:\n' + ll
assert 'Trying Beta fixture' not in ll, ll

books = json.loads((root / 'library.json').read_text()).get('books', [])
by = {b['title']: b for b in books}
assert set(by) == {'Puerto de Cristal', 'Lantern Field'}, by.keys()
assert by['Puerto de Cristal'].get('language') == 'es', by['Puerto de Cristal']
server = (root / 'server.log').read_text()
assert '/epub/puerto-spanish.epub' in server and '/epub/puerto-general.epub' not in server, server
assert '/epub/lantern-alpha.epub' in server and '/epub/lantern-beta.epub' not in server, server
print('PASS: chosen translated edition found under its own title, no metadata lookups, verified es')
print('PASS: the Spanish-only source was preferred for a Spanish download over a general source')
print('PASS: between general sources, the reader order (by name) beat the source ID order')
print('PASS: isolated library holds exactly the two verified fixture EPUBs')
PY
