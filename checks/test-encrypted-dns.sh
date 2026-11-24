#!/bin/zsh
# Encrypted DNS (Cloudflare 1.1.1.1) for Folio's own requests.
# Compiles the real app/Sources/Folio/EncryptedDNS.swift with a tiny driver and checks:
#  1. Off: lookups are ordinary system lookups.
#  2. On: the Cloudflare check passes, status is active, and the system
#     resolver receives Folio's lookups as need-encryption (proved from
#     mDNSResponder's own log), while Open Library, Hardcover and Gutenberg answer.
#  3. Cloudflare unreachable: status is unavailable and requests still work
#     through the network's DNS.
# Only public book-metadata hosts are contacted; no account or library is used.
set -euo pipefail
here="${0:A:h}"
scratch=$(mktemp -d "${TMPDIR:-/tmp/}folio-dns.XXXXXXXX")
trap 'rm -rf "$scratch"' EXIT
cat > "$scratch/main.swift" <<'SWIFT'
import Foundation
@main struct Driver {
    @MainActor static func main() async {
        let mode = CommandLine.arguments[1]
        let dns = FolioEncryptedDNS.shared
        dns.enabled = mode != "off"
        await dns.apply()
        print("STATUS \(mode) \(dns.status)")
        let hosts = ["https://openlibrary.org/search.json?q=dune&limit=1",
                     "https://api.hardcover.app/v1/graphql",
                     "https://www.gutenberg.org/ebooks/84",
                     // Never looked up before, so the answer can't come from a cache.
                     "https://f\(UInt32.random(in: 1...UInt32.max)).127-0-0-1.nip.io:9/"]
        for url in hosts {
            var request = URLRequest(url: URL(string: url)!)
            request.timeoutInterval = 12
            do {
                let (_, response) = try await URLSession(configuration: .ephemeral).data(for: request)
                print("FETCH \(mode) \(URL(string: url)!.host!) HTTP \((response as! HTTPURLResponse).statusCode)")
            } catch {
                print("FETCH \(mode) \(URL(string: url)!.host!) error \((error as NSError).code)")
            }
        }
        UserDefaults.standard.removeObject(forKey: FolioEncryptedDNS.key)
    }
}
SWIFT
swiftc -swift-version 5 -parse-as-library "$here/../app/Sources/Folio/EncryptedDNS.swift" "$scratch/main.swift" -o "$scratch/folio-dns-check" 2>&1 | grep -E 'error' && exit 1
cd "$scratch"
cp folio-dns-check dnsoff; cp folio-dns-check dnson; cp folio-dns-check dnsdown
./dnsoff off > off.txt
./dnson on > on.txt
FOLIO_DNS_PROBE_URL="https://192.0.2.1/dns-query" ./dnsdown on > down.txt
sleep 2
/usr/bin/log show --last 3m --predicate 'process == "mDNSResponder" AND eventMessage CONTAINS "getaddrinfo start"' 2>/dev/null \
  | grep -oE 'options: 0x[0-9A-F]+ \{[^}]*\}, client pid: [0-9]+ \((dnsoff|dnson|dnsdown)\)' \
  | sed -E 's/client pid: [0-9]+ //' | sort | uniq -c > resolver.txt || true
cat off.txt on.txt down.txt resolver.txt
python3 - "$scratch" <<'PY'
import sys
from pathlib import Path
root = Path(sys.argv[1])
off, on, down, res = [(root / n).read_text() for n in ['off.txt', 'on.txt', 'down.txt', 'resolver.txt']]
assert 'STATUS off off' in off, off
assert 'STATUS on active' in on, on
assert 'STATUS on unavailable' in down, down
for text in (off, on, down):
    for host in ['openlibrary.org', 'api.hardcover.app', 'www.gutenberg.org']:
        line = next(l for l in text.splitlines() if f' {host} ' in l)
        assert 'HTTP' in line, 'Request failed: ' + line
    fresh = next(l for l in text.splitlines() if 'nip.io' in l)
    assert 'error -1004' in fresh, 'Fresh name did not resolve (expected connection refused): ' + fresh
assert 'need-encryption' in next((l for l in res.splitlines() if '(dnson)' in l), ''), 'On: lookups were not encrypted:\n' + res
assert all('need-encryption' not in l for l in res.splitlines() if '(dnsoff)' in l or '(dnsdown)' in l), 'Off/unavailable used encryption:\n' + res
print('PASS: off uses the network DNS; every host answers')
print('PASS: on passes the Cloudflare check and the system resolver encrypts every Folio lookup; every host answers')
print('PASS: with Cloudflare unreachable Folio stays on the network DNS and every host still answers')
PY
