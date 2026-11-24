#!/bin/zsh
# Folio iPhone Simulator: real app, WKWebView, URLSession and EPUB imports.
# All books/files are synthetic public-domain-title fixtures on HTTPS localhost.
# Creates and deletes its own simulator; never touches an existing library.
set -euo pipefail

here="${0:A:h}"
repo="$here/.."
app="$repo/app/iOS"
simBundle="${FOLIO_IOS_SIMULATOR_APP:-/tmp/folio-parallel-simulator/Build/Products/Debug-iphonesimulator/Folio.app}"
scratch=$(mktemp -d "${TMPDIR:-/tmp/}folio-lectulandia-ios.XXXXXXXX")
sim=''
server=0
bounded_simctl() {
    local seconds="$1"
    shift
    FOLIO_IOS_SIMCTL_TIMEOUT="$seconds" python3 "$here/test-lectulandia-ios-simctl.py" "$@"
}
cleanup() {
    if (( server != 0 )); then kill "$server" 2>/dev/null || :; fi
    if [[ -n "$sim" ]]; then
        bounded_simctl 12 terminate "$sim" app.folio.reader.ios >/dev/null 2>&1 || :
        bounded_simctl 20 shutdown "$sim" >/dev/null 2>&1 || :
        bounded_simctl 20 delete "$sim" >/dev/null 2>&1 || print -u2 "WARNING: simulator $sim requires manual deletion"
    fi
    if [[ "${FOLIO_IOS_KEEP_TEST_ARTIFACTS:-0}" == 1 ]]; then
        print "RETAINED: $scratch"
    else
        rm -rf -- "$scratch"
    fi
}
trap cleanup EXIT

if [[ ! -d "$simBundle" ]]; then
    print -u2 "Build a simulator app first and set FOLIO_IOS_SIMULATOR_APP: $simBundle"
    exit 1
fi
print "SIMULATOR APP: $simBundle"

# A locally generated test CA is trusted only by the disposable simulator.
# The host's own trust store, user keychains and all existing simulators remain untouched.
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 1 \
    -keyout "$scratch/ca.key" -out "$scratch/ca.crt" \
    -subj '/CN=Folio Isolated iOS Simulator Test CA' > "$scratch/cert.log" 2>&1
/usr/bin/openssl req -newkey rsa:2048 -nodes -sha256 \
    -keyout "$scratch/server.key" -out "$scratch/server.csr" \
    -subj '/CN=localhost' >> "$scratch/cert.log" 2>&1
cat > "$scratch/server.ext" <<'EXT'
basicConstraints=CA:FALSE
keyUsage=digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=DNS:localhost,IP:127.0.0.1
EXT
/usr/bin/openssl x509 -req -sha256 -days 1 \
    -in "$scratch/server.csr" -CA "$scratch/ca.crt" -CAkey "$scratch/ca.key" -CAcreateserial \
    -out "$scratch/server.crt" -extfile "$scratch/server.ext" >> "$scratch/cert.log" 2>&1

cat > "$scratch/server.py" <<'PY'
import json,sys,time,threading,io,base64,ssl
from html import escape
from pathlib import Path
from zipfile import ZipFile,ZIP_STORED
from http.server import BaseHTTPRequestHandler,ThreadingHTTPServer
root=Path(sys.argv[1]); events=root/'events.jsonl'; lock=threading.Lock()
titles={'quijote':'Don Quijote de la Mancha','celestina':'La Celestina',
        'poema':'Poema del Cid','blocked':'Libro sin permiso',
        'wronglang':'Libro con idioma equivocado',
        'wrongtitle':'Libro con título equivocado',
        'nearby':'Libro sin coincidencia'}
authors={'quijote':'Miguel de Cervantes','celestina':'Fernando de Rojas',
         'poema':'Autor clásico','blocked':'Autor clásico',
         'wronglang':'Autor clásico','wrongtitle':'Autor clásico',
         'nearby':'Autor clásico'}
def event(route,action,slug,code=0,cookies=(),referer_ok=False,ua_ok=False):
    with lock:
        with events.open('a') as f:
            f.write(json.dumps(dict(route=route,action=action,slug=slug,code=code,
                                    cookies=list(cookies),referer_ok=referer_ok,
                                    ua_ok=ua_ok,t=time.monotonic()))+'\n')
def make_epub(slug):
    title=escape('Obra ajena al título solicitado' if slug=='wrongtitle' else titles[slug])
    author=escape(authors[slug]);language='en' if slug=='wronglang' else 'es'
    container='''<?xml version="1.0"?><container xmlns="urn:oasis:names:tc:opendocument:xmlns:container"
      version="1.0"><rootfiles><rootfile full-path="OPS/package.opf"
      media-type="application/oebps-package+xml"/></rootfiles></container>'''
    opf=f'''<?xml version="1.0"?><package xmlns="http://www.idpf.org/2007/opf" version="3.0"
      unique-identifier="bookid"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
      <dc:identifier id="bookid">folio-original-ios-{slug}</dc:identifier><dc:title>{title}</dc:title>
      <dc:creator>{author}</dc:creator><dc:language>{language}</dc:language></metadata>
      <manifest><item id="chapter" href="chapter.xhtml" media-type="application/xhtml+xml"/></manifest>
      <spine><itemref idref="chapter"/></spine></package>'''
    chapter=f'''<html xmlns="http://www.w3.org/1999/xhtml"><body><p>Synthetic fixture: {title}.
      This is original test prose, not the published work.</p></body></html>'''
    buf=io.BytesIO()
    with ZipFile(buf,'w') as z:
        z.writestr('mimetype','application/epub+zip',compress_type=ZIP_STORED)
        z.writestr('META-INF/container.xml',container)
        z.writestr('OPS/package.opf',opf)
        z.writestr('OPS/chapter.xhtml',chapter)
    return buf.getvalue()
files={s:make_epub(s) for s in titles}
png=base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO4t+kUAAAAASUVORK5CYII=')
class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        route=self.path.split('?',1)[0]
        if route=='/ready':self.send_response(200);self.end_headers();self.wfile.write(b'ready');return
        parts=route.strip('/').split('/')
        stage,slug=(parts+[None,None])[:2]
        if slug not in titles or stage not in ('catalog','landing','partner','file','cover'):
            self.send_error(404);return
        cookie=self.headers.get('Cookie','');referer=self.headers.get('Referer','')
        cookies=tuple(s for s in titles if 'folio_ios='+s in cookie)
        origin='https://127.0.0.1:'+str(self.server.server_address[1])
        referer_ok=referer.rstrip('/')==origin+'/partner/'+slug
        ua_ok=bool(self.headers.get('User-Agent',''))
        event(route,'start',slug,cookies=cookies,referer_ok=referer_ok,ua_ok=ua_ok)
        if stage=='catalog':
            time.sleep(0.75)
            body=b'''<html><body><div id="ready">No JavaScript yet</div><script>
              document.getElementById('ready').textContent='JS ready';</script></body></html>'''
            code,mime=200,'text/html'
        elif stage=='landing':
            body=(f'''<html><body><p>Normal countdown</p><script>setTimeout(function(){{
              location.replace('{origin}/partner/{slug}');
            }},750);</script></body></html>''').encode()
            code,mime=200,'text/html'
        elif stage=='partner':
            body=(f'''<html><body><p>Partner download page</p><script>setTimeout(function(){{
              var a=document.createElement('a');a.id='downloadB';a.href='{origin}/file/{slug}';
              a.textContent='Download';document.body.appendChild(a);
            }},550);</script></body></html>''').encode()
            code,mime=200,'text/html'
        elif stage=='cover':
            code,mime,body=200,'image/png',png
        elif slug=='blocked' and not (root/'permit-blocked').exists():
            self.send_response(302)
            self.send_header('Location','https://unverified-fixture.invalid/blocked.epub')
            self.end_headers();event(route,'end',slug,302,cookies,referer_ok,ua_ok);return
        elif 'folio_ios='+slug not in cookie:
            code,mime,body=403,'text/plain',b'Missing browser session cookie'
        elif not referer_ok:
            code,mime,body=403,'text/plain',b'Missing same-origin HTTPS Referer'
        else:
            time.sleep(0.8)
            code,mime,body=200,'application/epub+zip',files[slug]
        try:
            self.send_response(code);self.send_header('Content-Type',mime)
            self.send_header('Content-Length',str(len(body)))
            if stage=='catalog':self.send_header('Set-Cookie','folio_ios='+slug+'; Path=/; Secure; HttpOnly; SameSite=Lax')
            self.end_headers();self.wfile.write(body)
        except (BrokenPipeError,ConnectionResetError):pass
        event(route,'end',slug,code,cookies,referer_ok,ua_ok)
    def log_message(self,*args):pass
server=ThreadingHTTPServer(('127.0.0.1',0),Handler)
tls=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
tls.load_cert_chain(root/'server.crt',root/'server.key')
server.socket=tls.wrap_socket(server.socket,server_side=True)
(root/'port').write_text(str(server.server_address[1]))
server.serve_forever()
PY

python3 -u "$scratch/server.py" "$scratch" > "$scratch/server.log" 2>&1 &
server=$!
for i in {1..100}; do
    [[ -s "$scratch/port" ]] && break
    sleep 0.1
done
[[ -s "$scratch/port" ]] || { print -u2 'No localhost fixture server'; exit 1; }
port=$(<"$scratch/port")
curl --fail --silent --max-time 2 --cacert "$scratch/ca.crt" "https://127.0.0.1:$port/ready" >/dev/null

sim=$(bounded_simctl 35 create "Folio-Lectulandia-CI-$$" \
    "${FOLIO_IOS_SIMULATOR_DEVICE_TYPE:-com.apple.CoreSimulator.SimDeviceType.iPhone-16e}" \
    "${FOLIO_IOS_SIMULATOR_RUNTIME:-com.apple.CoreSimulator.SimRuntime.iOS-26-2}")
print "iOS E2E simulator: $sim"
bounded_simctl 40 boot "$sim"
print 'iOS E2E: waiting for isolated simulator boot…'
bounded_simctl "${FOLIO_IOS_BOOT_TIMEOUT:-240}" bootstatus "$sim" -b >/dev/null
bounded_simctl 45 keychain "$sim" add-root-cert "$scratch/ca.crt"
bounded_simctl 70 install "$sim" "$simBundle"
container=$(bounded_simctl 40 get_app_container "$sim" app.folio.reader.ios data)
data="$container/Documents/FolioE2E"
mkdir -p "$data/Extensions"

cat > "$data/Extensions/ios-fixture.js" <<'JS'
var source={
 id:'ios-fixture',name:'Spanish iOS WebKit Test',version:'1.0',languages:['es'],
 allowedHosts:['https://127.0.0.1:__PORT__'],settings:[],
 search:function(q,page,lang,title,author){
  var list=[['quijote','Don Quijote de la Mancha','Miguel de Cervantes'],
            ['celestina','La Celestina','Fernando de Rojas'],
            ['poema','Poema del Cid','Autor clásico'],
            ['blocked','Libro sin permiso','Autor clásico'],
            ['wronglang','Libro con idioma equivocado','Autor clásico'],
            ['wrongtitle','Libro con título equivocado','Autor clásico'],
            ['nearby','Libro sin coincidencia','Autor clásico']];
  var matches=list.filter(function(v){return String(q).toLowerCase().indexOf(v[1].toLowerCase())>=0;});
  if(!matches.length)return [];
  var found=matches[0],slug=found[0];
  var html=folio.browser.open('https://127.0.0.1:__PORT__/catalog/'+slug);
  if(html.indexOf('JS ready')<0)throw Error('WebKit JavaScript was not executed');
  folio.log('iOS browser catalog '+slug+' ready');
  return [{id:slug,title:slug==='nearby'?'Unrelated and different work':found[1],authors:[found[2]],language:'es',
           cover:'https://127.0.0.1:__PORT__/cover/'+slug,
           downloads:[{format:'epub',url:'https://127.0.0.1:__PORT__/landing/'+slug}]}];
 },
 prepareDownload:function(url){
  var slug=url.split('/').pop();
  folio.browser.open(url);
  if(folio.browser.waitFor('#downloadB')!=='true')throw Error('Countdown did not finish');
  var page=folio.browser.url();
  if(page!=='https://127.0.0.1:__PORT__/partner/'+slug)throw Error('Partner redirect failed: '+page);
  var final=folio.browser.evaluate("document.querySelector('#downloadB').href");
  if(final!=='https://127.0.0.1:__PORT__/file/'+slug)throw Error('Unexpected provider link');
  folio.log('iOS countdown completed '+slug);
  return final;
 },recent:function(){return [];}
};
JS
sed -i '' "s/__PORT__/$port/g" "$data/Extensions/ios-fixture.js"
node --check "$data/Extensions/ios-fixture.js"

python3 - "$data" <<'PY'
import json,sys,time,uuid
from pathlib import Path
root=Path(sys.argv[1])
scripts={}
for name in ['annas-archive-free','lectulandia','demeter','gutenberg','metadata-amazon',
             'metadata-apple-books','metadata-google-books','metadata-hardcover','metadata-open-library']:
    scripts[name]={'file':name+'.js','enabled':False,'builtIn':True,'config':{}}
scripts['ios-fixture']={'file':'ios-fixture.js','enabled':True,'builtIn':False,'config':{}}
(root/'Extensions/extensions.json').write_text(json.dumps(scripts))
now=time.time()-978307200
books=[('Don Quijote de la Mancha','Miguel de Cervantes','queued'),
       ('La Celestina','Fernando de Rojas','queued'),
       ('Poema del Cid','Autor clásico','downloading'),
       ('Libro sin permiso','Autor clásico','queued'),
       ('Libro cancelado','Autor clásico','cancelled'),
       ('Libro con idioma equivocado','Autor clásico','queued'),
       ('Libro con título equivocado','Autor clásico','queued'),
       ('Libro sin coincidencia','Autor clásico','queued')]
jobs=[dict(id=str(uuid.uuid4()).upper(),title=t,author=a,expectedLanguage='es',
           cover=None,hardcoverBookID=None,hardcoverPages=None,stage=stage,
           statusText='Synthetic simulator job',detailLog=[],error=None,importedBookID=None,
           createdAt=now+i,updatedAt=now+i)
      for i,(t,a,stage) in enumerate(books)]
(root/'download-queue.json').write_text(json.dumps(jobs))
PY

start=$SECONDS
print 'iOS E2E: launching native Folio and waiting for synthetic EPUB import…'
SIMCTL_CHILD_FOLIO_DATA_DIR="$data" \
  bounded_simctl "${FOLIO_IOS_LAUNCH_TIMEOUT:-80}" launch "$sim" app.folio.reader.ios
result=''
while (( SECONDS-start < 110 )); do
    result=$(python3 - "$data/download-queue.json" <<'PY'
import json,sys
jobs=json.load(open(sys.argv[1]))
print(','.join(j['stage'] for j in jobs))
PY
    )
    if [[ "$result" == 'completed,completed,completed,failed,cancelled,failed,failed,failed' ]]; then break; fi
    sleep 2
done
bounded_simctl 25 io "$sim" screenshot "$scratch/iphone.png" >/dev/null || print -u2 'WARNING: iOS screenshot unavailable'

python3 - "$data" "$scratch" "$result" "$((SECONDS-start))" <<'PY'
import sys,json,zipfile,xml.etree.ElementTree as ET
from pathlib import Path
root,scratch,stages,seconds=Path(sys.argv[1]),Path(sys.argv[2]),sys.argv[3],int(sys.argv[4])
jobs=json.loads((root/'download-queue.json').read_text())
print('iOS STAGES',stages,'seconds',seconds)
for j in jobs:
 print(' ',j['title'],j['stage'],j.get('error'),j.get('detailLog',[])[-3:])
assert stages=='completed,completed,completed,failed,cancelled,failed,failed,failed',('unexpected queue stages',stages)
assert all(job.get('importedBookID') for job in jobs[:3]),'completed jobs lack imported book IDs'
assert all(job.get('importedBookID') is None for job in jobs[3:]),'failed/cancelled job imported a file'
assert 'downloaded EPUB declares en' in '\n'.join(jobs[5].get('detailLog',[])),jobs[5]
assert 'Imported EPUB metadata did not match' in '\n'.join(jobs[6].get('detailLog',[])),jobs[6]
assert not any('Verifying the imported EPUB metadata' in entry for entry in jobs[7].get('detailLog',[])),jobs[7]
books=json.loads((root/'library.json').read_text()).get('books',[])
expected={'Don Quijote de la Mancha':'Miguel de Cervantes',
          'La Celestina':'Fernando de Rojas','Poema del Cid':'Autor clásico'}
assert len(books)==3 and {b.get('title') for b in books}==set(expected),books
assert all(b.get('language')=='es' and b.get('author')==expected[b['title']] for b in books),books
assert {str(b['id']).upper() for b in books}=={j['importedBookID'].upper() for j in jobs[:3]}
files=list((root/'Files').glob('*.epub'))
assert len(files)==3
for book in files:
 with zipfile.ZipFile(book) as z:
  assert z.namelist()[0]=='mimetype' and z.read('mimetype')==b'application/epub+zip'
  container=ET.fromstring(z.read('META-INF/container.xml'))
  package=container.find('.//{*}rootfile')
  assert package is not None
  opf=ET.fromstring(z.read(package.attrib['full-path']))
  def field(name):
   e=opf.find('.//{http://purl.org/dc/elements/1.1/}'+name)
   assert e is not None and e.text, (book,name)
   return e.text
  title,author,language=field('title'),field('creator'),field('language')
  assert expected.get(title)==author and language=='es',(title,author,language)
  text=z.read('OPS/chapter.xhtml').decode('utf-8')
  assert 'Synthetic fixture:' in text and 'original test prose' in text
log='\n'.join(l for j in jobs for l in j.get('detailLog',[]))
assert all(s in log for s in ('iOS browser catalog','iOS countdown completed',
                             'Verified EPUB package language es matches requested es'))
assert 'Blocked: the download tried to move to another server' in log
assert 'Previous operation interrupted; queued for retry' in log
events=[json.loads(line) for line in (scratch/'events.jsonl').read_text().splitlines()]
for slug in ('quijote','celestina','poema'):
 for stage in ('catalog','landing','file'):
  entries=[e for e in events if e['route']=='/'+stage+'/'+slug]
  assert any(e['action']=='start' for e in entries),('missing browser/network request',stage,slug)
  assert any(e['action']=='end' and e['code']==200 for e in entries),('no successful request',stage,slug)
  if stage=='file':
   assert all(e['cookies']==[slug] for e in entries),('cookie missing or leaked between jobs',slug,entries)
assert any(e['route']=='/file/blocked' and e['code']==302 for e in events), 'external redirect guard not exercised'
assert not any('cancelled' in e['route'] for e in events), 'cancelled job unexpectedly accessed network'
for slug in ('wronglang','wrongtitle'):
 assert any(e['route']=='/file/'+slug and e['action']=='end' and e['code']==200 and e['referer_ok'] for e in events), ('negative OPF fixture not downloaded',slug)
assert not any(e['route'] in ('/file/nearby','/landing/nearby') for e in events), 'unrelated source title was wrongly downloaded'
for slug in ('quijote','celestina','poema'):
 assert any(e['route']=='/partner/'+slug and e['code']==200 for e in events),('WebKit partner redirect missing',slug)
 assert any(e['route']=='/file/'+slug and e['code']==200 and e['referer_ok'] and e['ua_ok'] for e in events),('HTTPS Referer/User-Agent not forwarded',slug)
first={};last={}
for e in events:
 if e['action']=='start':first.setdefault(e['route'],e['t'])
 else:last[e['route']]=e['t']
catalog=['/catalog/quijote','/catalog/celestina','/catalog/poema']
overlap=sum(max(first[a],first[b])<min(last[a],last[b])
            for i,a in enumerate(catalog) for b in catalog[i+1:])
assert overlap>=1,('iOS search requests unexpectedly serialized',events)
print('PASS iOS WKWebView, countdown, protected Cookie EPUB, language and metadata import')
print('PASS refused unverified redirect, recovered interrupted job, retained cancelled job')
print('PASS rejects EPUB language=en for required es, mismatched OPF title, unrelated catalogue title')
print('METRIC iOS parallel catalogue overlaps',overlap,'of 3 pairs; total elapsed',seconds,'seconds')
PY

# A controlled retry after a provider fixes its redirect. The queue is seeded
# as queued before relaunch, just as a persisted retry would be; the native app
# must then rerun WebKit and import the fourth synthetic OPF without duplicates.
# (The in-app Retry button itself is outside this headless simctl-only fixture.)
bounded_simctl 30 terminate "$sim" app.folio.reader.ios
: > "$scratch/permit-blocked"
python3 - "$data/download-queue.json" <<'PY'
import json,sys,time
from pathlib import Path
path=Path(sys.argv[1]); jobs=json.loads(path.read_text())
assert [j['stage'] for j in jobs]==['completed','completed','completed','failed','cancelled','failed','failed','failed']
j=jobs[3]
j['stage']='queued';j['error']=None;j['importedBookID']=None
j['statusText']='Retry from controlled persisted fixture'
j['updatedAt']=time.time()-978307200
j['detailLog'].append('Controlled test: retry requested after provider redirect fixed')
path.write_text(json.dumps(jobs))
PY
print 'iOS E2E: relaunching native Folio for isolated failed-job retry…'
retryStart=$SECONDS
SIMCTL_CHILD_FOLIO_DATA_DIR="$data" \
  bounded_simctl "${FOLIO_IOS_LAUNCH_TIMEOUT:-80}" launch "$sim" app.folio.reader.ios
retryStage=''
while (( SECONDS-retryStart < 85 )); do
    retryStage=$(python3 - "$data/download-queue.json" <<'PY'
import json,sys
print(','.join(j['stage'] for j in json.load(open(sys.argv[1]))))
PY
    )
    [[ "$retryStage" == 'completed,completed,completed,completed,cancelled,failed,failed,failed' ]] && break
    sleep 2
done
# LibraryStore persists asynchronously after the DownloadQueue JSON reaches
# completed; a one-tick filesystem race is not a failed EPUB import.
persistStart=$SECONDS
persistedBooks=0
while (( SECONDS-persistStart < 15 )); do
    persistedBooks=$(python3 - "$data/library.json" <<'PY'
import json,sys
try: print(len(json.load(open(sys.argv[1]))['books']))
except (FileNotFoundError,KeyError,ValueError): print(0)
PY
    )
    [[ "$persistedBooks" == 4 ]] && break
    sleep 1
done
print "iOS E2E: retry stage $retryStage, persisted library books $persistedBooks"
python3 - "$data" "$scratch" "$retryStage" "$((SECONDS-retryStart))" <<'PY'
import json,sys,zipfile,xml.etree.ElementTree as ET
from pathlib import Path
root,scratch,stages,elapsed=Path(sys.argv[1]),Path(sys.argv[2]),sys.argv[3],int(sys.argv[4])
jobs=json.loads((root/'download-queue.json').read_text())
assert stages=='completed,completed,completed,completed,cancelled,failed,failed,failed',('retry stages',stages,[(j['title'],j.get('error')) for j in jobs])
assert all(j.get('importedBookID') for j in jobs[:4]) and not jobs[4].get('importedBookID')
assert not any(j.get('importedBookID') for j in jobs[5:]),'invalid title/language work imported on restart'
books=json.loads((root/'library.json').read_text())['books']
assert len(books)==4 and len(set(b['id'] for b in books))==4, books
expected={'Don Quijote de la Mancha','La Celestina','Poema del Cid','Libro sin permiso'}
assert {b['title'] for b in books}==expected
assert len(list((root/'Files').glob('*.epub')))==4
item=next(b for b in books if b['title']=='Libro sin permiso')
with zipfile.ZipFile(root/'Files'/item['fileName']) as epub:
 opf=ET.fromstring(epub.read('OPS/package.opf'))
 ns='{http://purl.org/dc/elements/1.1/}'
 assert opf.find('.//'+ns+'language').text=='es'
 assert opf.find('.//'+ns+'title').text=='Libro sin permiso'
 assert opf.find('.//'+ns+'creator').text=='Autor clásico'
events=[json.loads(line) for line in (scratch/'events.jsonl').read_text().splitlines()]
blocked=[e for e in events if e['route']=='/file/blocked' and e['action']=='end']
assert any(e['code']==302 for e in blocked),'initial rejected redirect missing'
assert any(e['code']==200 and e['cookies']==['blocked'] and e['referer_ok'] and e['ua_ok'] for e in blocked),('retry failed to transfer securely',blocked)
assert not any(e['slug']=='cancelled' for e in events),'cancelled job unexpectedly fetched on restart'
assert any('Verified EPUB package language es matches requested es' in line for line in jobs[3]['detailLog'])
print('PASS iOS persisted retry after blocked redirect: fourth EPUB imported exactly once')
print('PASS iOS cancelled job retained across two launches, zero HTTP requests')
print('METRIC isolated retry elapsed',elapsed,'seconds')
PY
