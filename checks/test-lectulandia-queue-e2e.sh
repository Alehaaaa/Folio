#!/bin/zsh
# Native Folio queue regression using a Lectulandia-shaped local Spanish catalogue.
# Book titles are public domain; EPUB body text is original synthetic fixture content.
# This validates queue/browser/import plumbing, not the external Lectulandia network.
# Run: /bin/zsh checks/test-lectulandia-queue-e2e.sh
# Only the signed Folio.app executable, synthetic localhost HTTP and ephemeral
# FOLIO_DATA_DIR are used; no real EPUBs, user library, source sites, or build.
set -euo pipefail

here="${0:A:h}"
app="$here/../app"
binary="$app/Folio.app/Contents/MacOS/Folio"
scratch=$(mktemp -d "${TMPDIR:-/tmp/}folio-lectulandia-queue-e2e.XXXXXXXX")
server=0
cleanup() {
    if [[ "$server" != 0 ]]; then kill "$server" 2>/dev/null || :; fi
    if [[ "${FOLIO_LECTULANDIA_KEEP_ARTIFACTS:-0}" != 1 ]]; then
        rm -rf -- "$scratch"
    else
        print "RETAINED TEST ARTIFACTS: $scratch"
    fi
}
trap cleanup EXIT

if [[ ! -x "$binary" ]] || ! /usr/bin/codesign --verify --deep --strict "$app/Folio.app" >/dev/null 2>&1; then
    print -u2 "FAIL: valid signed Folio.app is required; script never builds or installs."
    exit 1
fi
mkdir -p "$scratch/home" "$scratch/data/Extensions"
python3 - "$HOME" "$scratch/protect-production.sb" <<'PY'
import json, sys
from pathlib import Path
home, output=Path(sys.argv[1]),Path(sys.argv[2])
rules=['(version 1)','(allow default)']
for root in (home/'Library'/'Group Containers'/'L4947CL6Q2.app.folio.reader',
             home/'Library'/'Application Support'/'Folio'):
    for variant in (str(root),'/System/Volumes/Data'+str(root)):
        rules.append('(deny file-write* (subpath '+json.dumps(variant)+'))')
output.write_text('\n'.join(rules)+'\n')
PY

cat > "$scratch/fixture-server.py" <<'PY'
"""Cookie-isolated, browser-JS EPUB source fixture served only on 127.0.0.1."""
import sys, json, time, threading
from pathlib import Path
from io import BytesIO
from zipfile import ZipFile,ZIP_STORED
from http.server import BaseHTTPRequestHandler,ThreadingHTTPServer

root=Path(sys.argv[1])
events=root/'http-events.jsonl'
guard=threading.Lock()
names=['quijote','lazarillo','celestina','poema']
titles={'quijote':'Don Quijote de la Mancha','lazarillo':'Lazarillo de Tormes','celestina':'La Celestina','poema':'Poema del Cid'}

def record(route,phase,slug='',cookie='',status=None):
    with guard:
        with events.open('a') as f:
            f.write(json.dumps(dict(route=route,phase=phase,slug=slug,cookie=cookie,
                                    status=status,t=time.monotonic(),wall=time.time()))+'\n')
            f.flush()

def epub(slug):
    title=titles[slug]
    metadata=f'''<?xml version="1.0" encoding="utf-8"?>
    <package xmlns="http://www.idpf.org/2007/opf" unique-identifier="id" version="3.0">
      <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
        <dc:identifier id="id">browser-isolation-{slug}</dc:identifier>
        <dc:title>{title}</dc:title>
        <dc:creator>Autor clásico</dc:creator><dc:language>es</dc:language>
      </metadata>
      <manifest><item id="chapter" href="chapter.xhtml" media-type="application/xhtml+xml"/></manifest>
      <spine><itemref idref="chapter"/></spine>
    </package>'''
    container='''<?xml version="1.0" encoding="utf-8"?>
    <container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0">
      <rootfiles><rootfile full-path="OPS/package.opf" media-type="application/oebps-package+xml"/></rootfiles>
    </container>'''
    chapter=f'''<?xml version="1.0" encoding="utf-8"?>
    <html xmlns="http://www.w3.org/1999/xhtml" xml:lang="es">
    <head><title>Local test only</title></head>
    <body><p>Original synthetic content for {title}. No copyrighted novel.</p></body></html>'''
    out=BytesIO()
    with ZipFile(out,'w') as z:
        z.writestr('mimetype','application/epub+zip',compress_type=ZIP_STORED)
        z.writestr('META-INF/container.xml',container)
        z.writestr('OPS/package.opf',metadata)
        z.writestr('OPS/chapter.xhtml',chapter)
    return out.getvalue()

epubs={slug:epub(slug) for slug in names}

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path=='/ready':
            self.send_response(200);self.end_headers();self.wfile.write(b'OK');return
        route=self.path.split('?',1)[0]
        parts=route.strip('/').split('/')
        stage,slug=(parts+[None,None])[:2]
        if slug not in names or stage not in ('page','landing','file'):
            self.send_error(404);return
        cookie=self.headers.get('Cookie','')
        expected='folio_job_session='+slug
        record(route,'start',slug,cookie)
        # Give WKWebViews enough time to overlap on the wire (not merely
        # concurrently enqueued); fail the test if browser access is serial.
        if stage=='page':
            time.sleep(2.25)
            body=('''<!doctype html><html><head><title>Browser Test</title></head>
            <body><div id="start">Loading</div>
            <script>document.getElementById("start").textContent="JS executed";</script>
            </body></html>''').encode()
            status=200
            mime='text/html; charset=utf-8'
        elif stage=='landing':
            time.sleep(0.3)
            if expected not in cookie:
                status,mime,body=403,'text/plain',b'Wrong browser session cookie on landing'
            else:
                status,mime=200,'text/html; charset=utf-8'
                final=f'http://127.0.0.1:{self.server.server_address[1]}/file/{slug}'
                body=('''<!doctype html><html><body>
                <p>Free partner countdown <span class="js-partner-countdown">1</span></p>
                <script>setTimeout(function(){
                   var node=document.createElement("span");
                   node.className="bg-gray-200 break-all";
                   node.textContent='''+json.dumps(final)+''';
                   document.body.appendChild(node);
                },950);</script></body></html>''').encode()
        else:
            time.sleep(1.4)
            if expected not in cookie:
                status,mime,body=403,'text/plain',b'Browser session cookie missing or leaked'
            else:
                status,mime,body=200,'application/epub+zip',epubs[slug]
        try:
            self.send_response(status)
            self.send_header('Content-Type',mime)
            self.send_header('Content-Length',str(len(body)))
            if stage=='page':
                # Only this page sets the per-job private HttpOnly cookie.
                # If a browser/session is shared, a sibling's navigation
                # overwrites it before landing/file verification.
                self.send_header('Set-Cookie',expected+'; Path=/; HttpOnly; SameSite=Lax')
            self.end_headers();self.wfile.write(body)
        except (BrokenPipeError,ConnectionResetError):
            pass
        record(route,'end',slug,cookie,status)
    def log_message(self,fmt,*args):
        print('HTTP:',fmt % args,flush=True)

server=ThreadingHTTPServer(('127.0.0.1',0),Handler)
(root/'port').write_text(str(server.server_address[1]))
server.serve_forever()
PY

python3 -u "$scratch/fixture-server.py" "$scratch" > "$scratch/server.log" 2>&1 &
server=$!
ready=0
for n in {1..100}; do
    if [[ -s "$scratch/port" ]]; then
        port=$(<"$scratch/port")
        if /usr/bin/curl --silent --fail --max-time 1 "http://127.0.0.1:$port/ready" >/dev/null; then
            ready=1; break
        fi
    fi
    sleep 0.1
done
if [[ "$ready" != 1 ]]; then
    print -u2 'FAIL: localhost browser fixture server did not start'
    cat "$scratch/server.log" >&2
    exit 1
fi

cat > "$scratch/data/Extensions/browser-parallel-fixture.js" <<JS
var source={
  id:'browser-parallel-fixture',name:'Lectulandia Queue Fixture',
  version:'1.0',description:'Four independent offscreen WKWebView sessions',
  allowedHosts:['http://127.0.0.1:$port'],settings:[],
  search:function(query) {
    var q=String(query).toLowerCase();
    var slug=null;
    ['quijote','lazarillo','celestina','poema'].forEach(function(item) {
      var titles={'quijote':'don quijote de la mancha','lazarillo':'lazarillo de tormes','celestina':'la celestina','poema':'poema del cid'};
      if(q.indexOf(titles[item])>=0)slug=item;
    });
    if(!slug)return [];
    folio.log('Lectulandia search start '+slug);
    var body=folio.browser.open('http://127.0.0.1:$port/page/'+slug);
    if(body.indexOf('JS executed')<0)throw new Error('Browser JS not rendered: '+slug);
    folio.log('Lectulandia search page JS executed '+slug);
    return [{
      id:'browser-'+slug,title:({'quijote':'Don Quijote de la Mancha','lazarillo':'Lazarillo de Tormes','celestina':'La Celestina','poema':'Poema del Cid'})[slug],
      authors:['Autor clásico'],language:'es',origin:'localhost browser fixture',
      downloads:[{format:'epub',url:'http://127.0.0.1:$port/landing/'+slug}]
    }];
  },
  prepareDownload:function(url) {
    var slug=String(url).split('/').pop();
    folio.log('Lectulandia prepare start '+slug);
    var page=folio.browser.open(url);
    if(page.indexOf('js-partner-countdown')<0)
      throw new Error('Landing page missing normal countdown: '+slug);
    var ok=folio.browser.waitFor('span.bg-gray-200.break-all');
    if(ok!=='true')throw new Error('Countdown element never appeared: '+slug);
    var final=folio.browser.evaluate("document.querySelector('span.bg-gray-200.break-all').textContent.trim()");
    if(final.indexOf('/file/'+slug)<0)
      throw new Error('Wrong final browser URL: '+slug);
    folio.log('Lectulandia prepare ready '+slug);
    return final;
  },
  recent:function(){return [];}
};
JS

python3 - "$scratch/data" <<'PY'
import json,sys,time,uuid
from pathlib import Path
d=Path(sys.argv[1])
settings={
  'browser-parallel-fixture':{'file':'browser-parallel-fixture.js','enabled':True,'builtIn':False,'config':{}},
  'demeter':{'file':'demeter.js','enabled':False,'builtIn':True,'config':{}},
  'gutenberg':{'file':'gutenberg.js','enabled':False,'builtIn':True,'config':{}}
}
(d/'Extensions'/'extensions.json').write_text(json.dumps(settings))
now=time.time()-978307200
titles=['Don Quijote de la Mancha','Lazarillo de Tormes','La Celestina','Poema del Cid','Libro inexistente','Libro cancelado']
jobs=[dict(id=str(uuid.uuid4()).upper(),title=title,author='Autor clásico',
           expectedLanguage='es',cover=None,hardcoverBookID=None,hardcoverPages=None,
           stage=('cancelled' if title=='Libro cancelado' else 'downloading' if title=='Poema del Cid' else 'queued'),statusText='Lectulandia-style isolated queue fixture',detailLog=(['Interrupted transfer before prior shutdown'] if title=='Poema del Cid' else []),
           error=None,importedBookID=None,createdAt=now+i,updatedAt=now+i)
      for i,title in enumerate(titles)]
(d/'download-queue.json').write_text(json.dumps(jobs))
PY

echo 'Signed Folio parallel WebKit stress: four browser.open + countdown + cookie EPUB jobs…'
echo "BUILD: $(/usr/bin/stat -f '%Sm (%z bytes)' -t '%Y-%m-%dT%H:%M:%S' "$binary")"
(
    cd "$app"
    HOME="$scratch/home" CFFIXED_USER_HOME="$scratch/home" \
      FOLIO_DATA_DIR="$scratch/data" FOLIO_SELECT_DOWNLOADING=1 \
      FOLIO_LAYER_CAPTURE=1 FOLIO_SHOT_FRAMES="${FOLIO_LECTULANDIA_QUEUE_FRAMES:-2400}" \
      /usr/bin/sandbox-exec -f "$scratch/protect-production.sb" \
      "$binary" --screenshot "$scratch/data/browser-parallel.png" \
      > "$scratch/folio.log" 2>&1
) || {
    print -u2 'FAIL: signed Folio crashed/failed during concurrent WebKit browser jobs.'
    tail -90 "$scratch/folio.log" >&2
    exit 1
}

python3 - "$scratch" <<'PY'
import json,sys
from pathlib import Path
root=Path(sys.argv[1]);data=root/'data'
titles={'Don Quijote de la Mancha','Lazarillo de Tormes','La Celestina','Poema del Cid','Libro inexistente','Libro cancelado'}
jobs={j['title']:j for j in json.loads((data/'download-queue.json').read_text())}
assert set(jobs)==titles, jobs
for title,job in jobs.items():
    if title=='Libro cancelado':
        assert job['stage']=='cancelled' and not job.get('importedBookID'),job
        continue
    if title=='Libro inexistente':
        assert job['stage']=='failed' and not job.get('importedBookID'),job
        continue
    assert job['stage']=='completed' and job.get('importedBookID'), ('Browser job did not finish',title,job)
    assert job['expectedLanguage']=='es', job
    log='\n'.join(job.get('detailLog',[]))
    if title=='Poema del Cid':
        assert 'Previous operation interrupted; queued for retry' in log,log
    slug={'Don Quijote de la Mancha':'quijote','Lazarillo de Tormes':'lazarillo','La Celestina':'celestina','Poema del Cid':'poema'}[title]
    assert 'Lectulandia search page JS executed '+slug in log, (title,log)
    assert 'Lectulandia prepare ready '+slug in log, (title,log)
    assert 'Verified EPUB package language es matches requested es' in log, (title,log)

books=json.loads((data/'library.json').read_text()).get('books',[])
assert len(books)==4 and {b['title'] for b in books}==titles-{'Libro inexistente','Libro cancelado'}, books
assert all(b['author']=='Autor clásico' and b.get('language')=='es' and
           b['id'].upper()==jobs[b['title']]['importedBookID'].upper()
           for b in books), books
files=list((data/'Files').glob('*.epub'))
folders=[p for p in (data/'Extracted').iterdir() if p.is_dir()]
assert len(files)==4 and len(folders)==4, ('Unexpected files or crash cleanup state',files,folders)
for folder in folders:
    opf=folder/'OPS'/'package.opf'
    assert opf.is_file() and '<dc:language>es</dc:language>' in opf.read_text(), opf

events=[json.loads(line) for line in (root/'http-events.jsonl').read_text().splitlines()]
requests={}
for e in events:
    record=requests.setdefault(e['route'],{})
    assert e['phase'] not in record, ('Duplicate browser request',e,record)
    record[e['phase']]=e
for slug in ('quijote','lazarillo','celestina','poema'):
    for stage in ('page','landing','file'):
        route=f'/{stage}/{slug}'
        entry=requests.get(route)
        assert entry and 'start' in entry and 'end' in entry, ('Missing complete browser request',route,entry)
        assert entry['end']['status']==200, ('Cookie mismatch or network error',route,entry)
        if stage!='page':
            cookie=entry['start']['cookie']
            assert f'folio_job_session={slug}' in cookie, ('Browser cookie missing',route,cookie)
            for other in ('quijote','lazarillo','celestina','poema'):
                if other!=slug:
                    assert f'folio_job_session={other}' not in cookie, (
                        'Cross-job WKWebView cookie contamination',route,cookie)
pages=[(requests['/page/'+slug]['start']['t'],requests['/page/'+slug]['end']['t'],slug)
       for slug in ('quijote','lazarillo','celestina','poema')]
overlapping=[
    (a[2],b[2]) for i,a in enumerate(pages) for b in pages[i+1:]
    if max(a[0],b[0]) < min(a[1],b[1])
]
assert len(overlapping)>=2, ('Browser page navigations were serial, not parallel',pages)
transfers=[(requests['/file/'+slug]['start']['t'],requests['/file/'+slug]['end']['t'],slug)
           for slug in ('quijote','lazarillo','celestina','poema')]
transfer_overlap=[
    (a[2],b[2]) for i,a in enumerate(transfers) for b in transfers[i+1:]
    if max(a[0],b[0]) < min(a[1],b[1])
]
assert len(transfer_overlap)>=1, ('Protected EPUB transfers never overlapped',transfers)

print('PASS: four signed Folio WKWebView jobs completed without process crash')
print('PASS: unmatched Spanish title failed, pre-cancelled job stayed cancelled, interrupted job recovered')
print('PASS: overlapping browser page GET intervals:',overlapping)
print('PASS: overlapping cookie-protected EPUB GET intervals:',transfer_overlap)
starts=[requests['/page/'+slug]['start']['t'] for slug in ('quijote','lazarillo','celestina','poema')]
ends=[requests['/file/'+slug]['end']['t'] for slug in ('quijote','lazarillo','celestina','poema')]
print(f'METRIC: four jobs from first browser request to last EPUB response: {max(ends)-min(starts):.2f}s')
print('METRIC: browser page durations:',{slug:round(requests['/page/'+slug]['end']['t']-requests['/page/'+slug]['start']['t'],2) for slug in ('quijote','lazarillo','celestina','poema')})
print('METRIC: EPUB transfer durations:',{slug:round(requests['/file/'+slug]['end']['t']-requests['/file/'+slug]['start']['t'],2) for slug in ('quijote','lazarillo','celestina','poema')})
print('PASS: distinct HttpOnly per-job cookies survived search, preparation and download without leaking')
print('PASS: four verified Spanish EPUB imports, matching identities and no failed/cancelled imports')
print('PASS: FOLIO_DATA_DIR + sandbox prevents production app-support and App Group widget writes')
PY
