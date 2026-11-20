"""Only local, deterministic test data; no real external pages or user profiles."""
from http.server import BaseHTTPRequestHandler, HTTPServer
from io import BytesIO
from zipfile import ZipFile, ZIP_STORED
import sys
import time

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == '/slow_download/local-fixture/0/0':
            started = getattr(self.server, 'slow_started', None)
            if started is None:
                self.server.slow_started = time.monotonic()
                started = self.server.slow_started
            if time.monotonic() - started < 1.5:
                html = b'''<!doctype html><html><body><p>Please wait
                <span class="js-partner-countdown">2</span> seconds to download this file.</p>
                <script>let waitSeconds=2;setTimeout(()=>location.assign(location.href),2000);</script>
                </body></html>'''
            else:
                html = b'''<!doctype html><html><body><p>Download now</p>
                <span class="bg-gray-200 break-all">http://127.0.0.1:18773/protected-book.epub</span>
                </body></html>'''
            self.send_response(200)
            self.send_header('Content-Type','text/html; charset=utf-8')
            self.send_header('Set-Cookie','folio_browser_check=passed; Path=/; HttpOnly; SameSite=Lax')
            self.send_header('Content-Length',str(len(html)))
            self.end_headers()
            self.wfile.write(html)
            return
        if self.path == '/protected-book.epub':
            if 'folio_browser_check=passed' not in self.headers.get('Cookie', ''):
                self.send_error(403, 'Browser verification required')
                return
            book = BytesIO()
            with ZipFile(book, 'w') as archive:
                archive.writestr('mimetype', 'application/epub+zip', compress_type=ZIP_STORED)
                archive.writestr('META-INF/container.xml', '<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0"><rootfiles><rootfile full-path="OPS/package.opf" media-type="application/oebps-package+xml"/></rootfiles></container>')
                archive.writestr('OPS/package.opf', '<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="uid">folio-local-fixture</dc:identifier><dc:title>Test Book</dc:title><dc:creator>Test Author</dc:creator><dc:language>en</dc:language></metadata><manifest><item id="content" href="chapter.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="content"/></spine></package>')
                archive.writestr('OPS/chapter.xhtml', '<html xmlns="http://www.w3.org/1999/xhtml"><body><p>Local test chapter.</p></body></html>')
            payload = book.getvalue()
            self.send_response(200)
            self.send_header('Content-Type', 'application/epub+zip')
            self.send_header('Content-Length', str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return
        if self.path == '/redirect':
            self.send_response(302)
            self.send_header('Location', 'https://example.invalid/unsafe-redirect')
            self.end_headers()
            return
        if self.path == '/same-host-redirect':
            self.send_response(302)
            self.send_header('Location', '/page')
            self.end_headers()
            return
        if self.path != '/page':
            self.send_error(404)
            return
        html = '''<!doctype html><html><head><title>WebKit background probe</title></head>
        <body><div data-ad-slot="test">Advertisement</div>
        <script>document.addEventListener('DOMContentLoaded', function () {
          let el=document.createElement('h1'); el.id='dynamic';
          el.textContent='JS executed'; document.body.appendChild(el);
        });</script></body></html>'''.encode('utf-8')
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Set-Cookie', 'folio_browser_check=passed; Path=/; HttpOnly; SameSite=Lax')
        self.send_header('Content-Length', str(len(html)))
        self.end_headers()
        self.wfile.write(html)

    def log_message(self, fmt, *args):
        print('HTTP:', fmt % args, flush=True)

if __name__ == '__main__':
    HTTPServer(('127.0.0.1', int(sys.argv[1])), Handler).serve_forever()
