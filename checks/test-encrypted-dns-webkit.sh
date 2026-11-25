#!/bin/zsh
# Encrypted DNS for pages in Folio's background source browser (WebKit).
# WebKit resolves names in its own system process, so Folio tunnels it through
# FolioEncryptedDNSWebProxy (a local HTTP CONNECT proxy) when Encrypted DNS is on.
# Checks, with Cloudflare DoH active:
#  1. Through the proxy, URLSession HTTPS (CONNECT) and plain HTTP work, and a
#     multi-megabyte EPUB downloads byte for byte.
#  2. A WKWebView using the proxy loads real pages (Open Library, Gutenberg),
#     and a never-seen name is looked up by Folio itself with need-encryption.
#  3. Without the proxy, WebKit's lookups are not made by Folio (the gap this fixes).
set -euo pipefail
here="${0:A:h}"
scratch=$(mktemp -d "${TMPDIR:-/tmp/}folio-dnsweb.XXXXXXXX")
trap 'rm -rf "$scratch"' EXIT
cat > "$scratch/main.swift" <<'SWIFT'
import AppKit
import WebKit

@MainActor final class Loader: NSObject, WKNavigationDelegate {
    var done: CheckedContinuation<String, Never>?
    func webView(_ w: WKWebView, didFinish n: WKNavigation!) { done?.resume(returning: "loaded \(w.title ?? "")"); done = nil }
    func webView(_ w: WKWebView, didFail n: WKNavigation!, withError e: Error) { done?.resume(returning: "error \((e as NSError).code)"); done = nil }
    func webView(_ w: WKWebView, didFailProvisionalNavigation n: WKNavigation!, withError e: Error) { done?.resume(returning: "error \((e as NSError).code)"); done = nil }
}

@MainActor func run(_ mode: String) async {
    for key in [FolioEncryptedDNS.key, FolioEncryptedDNS.providerKey] { UserDefaults.standard.removeObject(forKey: key) }
    let dns = FolioEncryptedDNS.shared
    dns.provider = .cloudflare
    dns.enabled = true
    try? await Task.sleep(for: .seconds(1))
    await dns.apply()
    print("STATUS \(mode) \(dns.status)")
    let fresh = "f\(UInt32.random(in: 1...UInt32.max)).127-0-0-1.nip.io"
    let config = WKWebViewConfiguration()
    config.websiteDataStore = .nonPersistent()
    if mode == "proxy" {
        let proxy = FolioEncryptedDNSWebProxy.shared
        config.websiteDataStore.proxyConfigurations = await proxy.proxyConfigurations()
        let port = Int(await proxy.port()!.rawValue)
        let c = URLSessionConfiguration.ephemeral
        c.connectionProxyDictionary = [
            kCFNetworkProxiesHTTPSEnable as String: 1, kCFNetworkProxiesHTTPSProxy as String: "127.0.0.1", kCFNetworkProxiesHTTPSPort as String: port,
            kCFNetworkProxiesHTTPEnable as String: 1, kCFNetworkProxiesHTTPProxy as String: "127.0.0.1", kCFNetworkProxiesHTTPPort as String: port,
        ]
        c.timeoutIntervalForRequest = 30
        let session = URLSession(configuration: c)
        for url in ["https://openlibrary.org/search.json?q=dune&limit=1", "http://neverssl.com/", "https://www.gutenberg.org/ebooks/84.epub3.images"] {
            do {
                let (data, response) = try await session.data(from: URL(string: url)!)
                let zip = data.prefix(2) == Data("PK".utf8) ? " zip" : ""
                print("SESSION \(URL(string: url)!.host!) HTTP \((response as! HTTPURLResponse).statusCode) \(data.count) bytes\(zip)")
            } catch { print("SESSION \(URL(string: url)!.host!) error \((error as NSError).code)") }
        }
    }
    let web = WKWebView(frame: .init(x: 0, y: 0, width: 800, height: 600), configuration: config)
    let window = NSWindow(contentRect: web.frame, styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = web
    let loader = Loader()
    web.navigationDelegate = loader
    for url in ["https://openlibrary.org/", "https://www.gutenberg.org/ebooks/84", "https://\(fresh):9/"] {
        let result: String = await withCheckedContinuation { c in
            loader.done = c
            web.load(URLRequest(url: URL(string: url)!, timeoutInterval: 20))
        }
        print("WEB \(mode) \(URL(string: url)!.host!.hasPrefix("f") && url.contains("nip.io") ? "fresh" : URL(string: url)!.host!) \(result)")
    }
    if mode == "proxy" { print("TUNNELS \(FolioEncryptedDNSWebProxy.shared.tunnelsOpened)") }
    print("FRESH \(fresh)")
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
Task { @MainActor in
    await run(CommandLine.arguments[1])
    exit(0)
}
app.run()
SWIFT
swiftc -swift-version 5 "$here/../app/Sources/Folio/EncryptedDNS.swift" "$here/../app/Sources/Folio/EncryptedDNSWebProxy.swift" "$scratch/main.swift" -o "$scratch/dnsweb" 2>&1 | grep -E 'error' && exit 1
cd "$scratch"
cp dnsweb dnswebproxy; cp dnsweb dnswebdirect
./dnswebproxy proxy | tee proxy.txt
./dnswebdirect direct | tee direct.txt
sleep 2
for f in proxy direct; do
  name=$(grep FRESH $f.txt | awk '{print $2}')
  echo "-- lookups of $name ($f):"
  /usr/bin/log show --last 5m --predicate "process == \"mDNSResponder\" AND eventMessage CONTAINS \"getaddrinfo start\" AND eventMessage CONTAINS \"$name\"" 2>/dev/null \
    | grep -oE 'options: 0x[0-9A-F]+ \{[^}]*\}, client pid: [0-9]+ \([^)]*\)' | sed -E 's/client pid: [0-9]+ //' | sort | uniq -c | tee $f.res || true
done
python3 - "$scratch" <<'PY'
import sys
from pathlib import Path
r = Path(sys.argv[1])
proxy, direct = (r/'proxy.txt').read_text(), (r/'direct.txt').read_text()
pres, dres = (r/'proxy.res').read_text(), (r/'direct.res').read_text()
fails = []
def need(cond, msg): (None if cond else fails.append(msg))
need('STATUS proxy active' in proxy, 'Cloudflare not active')
need('SESSION openlibrary.org HTTP 200' in proxy, 'HTTPS through proxy failed')
need('SESSION neverssl.com HTTP 200' in proxy, 'plain HTTP through proxy failed')
epub = next((l for l in proxy.splitlines() if l.startswith('SESSION www.gutenberg.org')), '')
need('HTTP 200' in epub and 'zip' in epub and int(epub.split()[4]) > 200000, 'EPUB download through proxy failed: ' + epub)
need('WEB proxy openlibrary.org loaded' in proxy, 'WebKit via proxy could not load Open Library')
need('WEB proxy www.gutenberg.org loaded' in proxy, 'WebKit via proxy could not load Gutenberg')
need(int(next(l for l in proxy.splitlines() if l.startswith('TUNNELS')).split()[1]) >= 3, 'WebKit did not use the proxy')
need('need-encryption' in pres and '(dnswebproxy)' in pres, 'With the proxy, the fresh name was not resolved encrypted by Folio:\n' + pres)
need('(dnswebdirect)' not in dres, 'Without the proxy Folio itself resolved the WebKit name?')
need('WEB direct openlibrary.org loaded' in direct, 'WebKit direct could not load Open Library')
print('Without the proxy, WebKit lookups came from:', dres.strip() or '(not in log)')
if fails: print('\n'.join('FAIL ' + f for f in fails)); sys.exit(1)
print('PASS: through the proxy, HTTPS, plain HTTP and a full EPUB download work')
print('PASS: WebKit loads real pages through the proxy and its lookups are made by Folio with need-encryption')
print('PASS: without the proxy WebKit resolves names outside Folio (the gap this closes)')
PY
