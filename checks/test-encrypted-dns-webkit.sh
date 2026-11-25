#!/bin/zsh
# Encrypted DNS for pages in Folio's background source browser (WebKit).
# WebKit resolves names in its own system process, so Folio tunnels it through
# FolioEncryptedDNSWebProxy (a local HTTP CONNECT proxy) when Encrypted DNS is on.
# Checks, with Cloudflare DoH active:
#  1. Through the proxy, URLSession HTTPS (CONNECT) and plain HTTP work, and a
#     multi-megabyte file downloads byte for byte.
#  2. A WKWebView using the proxy loads real pages (Open Library, example.com),
#     and a never-seen name is looked up by Folio itself with need-encryption.
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
        for url in ["https://openlibrary.org/search.json?q=dune&limit=1", "http://example.com/", "https://github.com/w3c/epubcheck/releases/download/v5.1.0/epubcheck-5.1.0.zip"] {
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
    for url in ["https://openlibrary.org/", "https://example.com/", "https://\(fresh):9/"] {
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
sleep 2
for f in proxy; do
  echo "-- lookups during the $f run:"
  /usr/bin/log show --last 5m --predicate 'process == "mDNSResponder" AND eventMessage CONTAINS "getaddrinfo start"' 2>/dev/null \
    | grep -oE 'options: 0x[0-9A-F]+ \{[^}]*\}, client pid: [0-9]+ \([^)]*\)' | sed -E 's/client pid: [0-9]+ //' | sort | uniq -c | tee $f.res || true
done
python3 - "$scratch" <<'PY'
import sys
from pathlib import Path
r = Path(sys.argv[1])
proxy = (r/'proxy.txt').read_text()
pres = (r/'proxy.res').read_text()
fails = []
def need(cond, msg): (None if cond else fails.append(msg))
need('STATUS proxy active' in proxy, 'Cloudflare not active')
need('SESSION openlibrary.org HTTP 200' in proxy, 'HTTPS through proxy failed')
need('SESSION example.com HTTP 200' in proxy, 'plain HTTP through proxy failed')
big = next((l for l in proxy.splitlines() if l.startswith('SESSION github.com')), '')
need('HTTP 200' in big and 'zip' in big and int(big.split()[4]) > 1000000, 'Large download through proxy failed: ' + big)
need('WEB proxy openlibrary.org loaded' in proxy, 'WebKit via proxy could not load Open Library')
need(int(next(l for l in proxy.splitlines() if l.startswith('TUNNELS')).split()[1]) >= 3, 'WebKit did not use the proxy')
need('WEB proxy example.com loaded Example Domain' in proxy, 'WebKit via proxy could not load example.com')
mine = [l for l in pres.splitlines() if '(dnswebproxy)' in l]
need(mine and all('need-encryption' in l for l in mine), 'Folio lookups were not all encrypted:\n' + pres)
webkit = [l for l in pres.splitlines() if 'WebKit' in l or 'com.apple.WebKit' in l]
print('WebKit networking lookups while proxied:', webkit or 'none')
if fails: print('\n'.join('FAIL ' + f for f in fails)); sys.exit(1)
print('PASS: through the proxy, HTTPS, plain HTTP and a multi-megabyte download work')
print('PASS: WebKit loads real pages through the proxy and its lookups are made by Folio with need-encryption')
PY
