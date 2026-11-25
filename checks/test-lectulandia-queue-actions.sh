#!/bin/zsh
# Exercise production DownloadQueue.swift methods against a real localhost HTTP transfer.
set -euo pipefail
here="${0:A:h}"
cd "$here/.."
scratch=$(mktemp -d "${TMPDIR:-/tmp/}folio-queue-actions.XXXXXXXX")
server=0
cleanup() { if [[ "$server" != 0 ]]; then kill "$server" 2>/dev/null || :; fi; rm -rf "$scratch"; }
trap cleanup EXIT
mkdir -p "$scratch/data"
cat > "$scratch/server.py" <<'PY'
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import sys,time
root=Path(sys.argv[1]); attempts=0
class Handler(BaseHTTPRequestHandler):
 def do_GET(self):
  global attempts
  if self.path=='/slow':
   (root/'data'/'slow-started').write_text('started')
   try:
    self.send_response(200)
    self.send_header('Content-Length',str(1024*1024))
    self.end_headers()
    for _ in range(1000):
     self.wfile.write(b'x'*1024)
     self.wfile.flush()
     time.sleep(0.05)
   except (BrokenPipeError,ConnectionResetError):
    (root/'data'/'slow-disconnected').write_text('cancelled')
   return
  elif self.path=='/flaky':
   attempts+=1
   code=503 if attempts==1 else 200
  else: code=404
  try:
   self.send_response(code);self.end_headers();self.wfile.write(b'EPUB fixture data')
  except (BrokenPipeError,ConnectionResetError): pass
 def log_message(self,*args): pass
server=ThreadingHTTPServer(('127.0.0.1',0),Handler)
(root/'port').write_text(str(server.server_address[1]))
server.serve_forever()
PY
python3 -u "$scratch/server.py" "$scratch" > "$scratch/server.log" 2>&1 &
server=$!
for i in {1..50}; do [[ -s "$scratch/port" ]] && break; sleep 0.1; done
[[ -s "$scratch/port" ]] || { print -u2 'FAIL server startup'; exit 1; }
swiftc -swift-version 5 -parse-as-library app/Sources/Folio/DownloadQueue.swift app/Sources/Folio/EditionTitle.swift checks/test-lectulandia-queue-actions.swift -o "$scratch/actions"
FOLIO_DATA_DIR="$scratch/data" FOLIO_FIXTURE_URL="http://127.0.0.1:$(<"$scratch/port")" "$scratch/actions"
