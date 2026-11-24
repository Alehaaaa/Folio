#!/bin/zsh
# Live, native macOS Folio import of a public-domain Spanish book.
# Uses a freshly signed copy of the current SwiftPM release executable,
# a private Folio data directory, and the real unmodified Lectulandia JS.
# Run from the repo root: zsh checks/test-lectulandia-live-app-e2e.sh
set -euo pipefail

here="${0:A:h}"
repo="$here/.."
app="$repo/app"
binary="$app/.build/release/Folio"
template="$app/Folio.app"
scratch=$(mktemp -d "${TMPDIR:-/tmp/}folio-lectulandia-live.XXXXXXXX")
pid=0
cleanup() {
    if [[ "$pid" != 0 ]]; then kill "$pid" 2>/dev/null || :; fi
    if [[ "${FOLIO_LECTULANDIA_KEEP_ARTIFACTS:-0}" != 1 ]]; then
        rm -rf -- "$scratch"
    else
        print "RETAINED: $scratch"
    fi
}
trap cleanup EXIT

if [[ ! -x "$binary" || ! -d "$template" ]]; then
    print -u2 "Build app first: cd app && swift build -c release (and supply app/Folio.app template)"
    exit 1
fi
mkdir -p "$scratch/home" "$scratch/data/Extensions"
/usr/bin/ditto "$template" "$scratch/Folio.app"
/bin/cp "$binary" "$scratch/Folio.app/Contents/MacOS/Folio"
/usr/bin/codesign --force --deep --sign - --timestamp=none "$scratch/Folio.app" >/dev/null 2>&1
/usr/bin/codesign --verify --deep --strict "$scratch/Folio.app"
/bin/cp "$repo/extensions/lectulandia.js" "$scratch/data/Extensions/lectulandia.js"

python3 - "$scratch/data" "$HOME" "$scratch/protect-production.sb" <<'PY'
import json, sys, time, uuid
from pathlib import Path
root, home, policy = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3])
root.joinpath('Extensions/extensions.json').write_text(json.dumps({
  'lectulandia': {'file':'lectulandia.js','enabled':True,'builtIn':False,'config':{}},
  # The startup updater can install managed sources that were absent before
  # launch. Seed them disabled so this is an exact Lectulandia-only run.
  'annas-archive-free': {'file':'annas-archive-free.js','enabled':False,'builtIn':True,'config':{}},
  'demeter': {'file':'demeter.js','enabled':False,'builtIn':True,'config':{}},
  'gutenberg': {'file':'gutenberg.js','enabled':False,'builtIn':True,'config':{}}
}))
now = time.time()-978307200
root.joinpath('download-queue.json').write_text(json.dumps([{
  'id':str(uuid.uuid4()).upper(),
  'title':'Don Quijote de la Mancha','author':'Miguel de Cervantes',
  'cover':None,'hardcoverBookID':None,'hardcoverPages':None,
  'expectedLanguage':'es','stage':'queued','statusText':'Waiting for public-domain source',
  'detailLog':[],'error':None,'importedBookID':None,
  'createdAt':now,'updatedAt':now
}]))
rules=['(version 1)','(allow default)']
for folder in (home/'Library'/'Group Containers'/'L4947CL6Q2.app.folio.reader',
               home/'Library'/'Application Support'/'Folio'):
  for item in (str(folder),'/System/Volumes/Data'+str(folder)):
    rules.append('(deny file-write* (subpath '+json.dumps(item)+'))')
policy.write_text('\n'.join(rules)+'\n')
PY

print "LIVE Lectulandia: searching and importing Don Quijote in isolated Folio.app"
started=$SECONDS
HOME="$scratch/home" FOLIO_DATA_DIR="$scratch/data" FOLIO_SELECT_DOWNLOADING=1 \
  /usr/bin/sandbox-exec -f "$scratch/protect-production.sb" \
  "$scratch/Folio.app/Contents/MacOS/Folio" \
  >"$scratch/folio.log" 2>&1 &
pid=$!
stage=''
while (( SECONDS - started < 260 )); do
    if [[ -f "$scratch/data/download-queue.json" ]]; then
        stage=$(python3 - "$scratch/data/download-queue.json" <<'PY'
import json, sys
print(json.load(open(sys.argv[1]))[0]['stage'])
PY
        )
        [[ "$stage" == 'completed' || "$stage" == 'failed' ]] && break
    fi
    kill -0 "$pid" 2>/dev/null || break
    sleep 2
done
elapsed=$((SECONDS - started))
kill "$pid" 2>/dev/null || :
wait "$pid" 2>/dev/null || :
pid=0

python3 - "$scratch/data" "$elapsed" <<'PY'
import json,sys,zipfile,xml.etree.ElementTree as ET
from pathlib import Path
root, elapsed = Path(sys.argv[1]), int(sys.argv[2])
job=json.loads((root/'download-queue.json').read_text())[0]
print('LIVE RESULT:',job['stage'],'elapsed_seconds=',elapsed,'status=',job['statusText'])
for line in job.get('detailLog',[])[-16:]: print('  LOG:',line)
if job['stage']!='completed':
    print('ERROR:',job.get('error'))
    raise SystemExit(1)
files=list((root/'Files').glob('*.epub'))
assert len(files)==1, f'Expected one imported EPUB, got {len(files)}'
with zipfile.ZipFile(files[0]) as z:
    names=z.namelist()
    assert 'META-INF/container.xml' in names
    container=ET.fromstring(z.read('META-INF/container.xml'))
    node=container.find('.//{*}rootfile')
    assert node is not None
    opf=ET.fromstring(z.read(node.attrib['full-path']))
    title=opf.find('.//{http://purl.org/dc/elements/1.1/}title')
    language=opf.find('.//{http://purl.org/dc/elements/1.1/}language')
    creator=opf.find('.//{http://purl.org/dc/elements/1.1/}creator')
    print('IMPORTED EPUB:',files[0].stat().st_size,'bytes',
          'title=',title.text if title is not None else None,
          'author=',creator.text if creator is not None else None,
          'language=',language.text if language is not None else None)
    assert language is not None and language.text.lower().split('-')[0] in ('es','spa')
assert job.get('importedBookID')
library=json.loads((root/'library.json').read_text())
assert 'books' in library and len(library['books'])>=1
print('PASS: real Lectulandia browser countdown, HTTPS partner download and verified Spanish library import')
PY
