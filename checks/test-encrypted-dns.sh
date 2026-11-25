#!/bin/zsh
# Encrypted DNS (DNS over HTTPS) for Folio's own requests, for every provider.
# Compiles the real app/Sources/Folio/EncryptedDNS.swift with a tiny driver and checks:
#  1. Off: lookups are ordinary system lookups.
#  2. Each provider (Cloudflare, Google, Quad9, AdGuard, Mullvad, NextDNS, a
#     custom DoH URL): the provider answers a real DoH query, status is active,
#     and the system resolver receives Folio's lookups as need-encryption
#     (proved from mDNSResponder's own log), while Open Library, Hardcover and
#     Gutenberg answer.
#  3. Provider unreachable: status is unavailable and requests still work
#     through the network's DNS. NextDNS without an ID asks for setup.
# Only public book-metadata hosts and DNS providers are contacted.
set -euo pipefail
here="${0:A:h}"
scratch=$(mktemp -d "${TMPDIR:-/tmp/}folio-dns.XXXXXXXX")
trap 'rm -rf "$scratch"' EXIT
cat > "$scratch/main.swift" <<'SWIFT'
import Foundation
@main struct Driver {
    @MainActor static func main() async {
        let args = CommandLine.arguments
        let name = args[1], provider = args[2], value = args.count > 3 ? args[3] : ""
        for key in [FolioEncryptedDNS.key, FolioEncryptedDNS.providerKey, FolioEncryptedDNS.nextDNSKey, FolioEncryptedDNS.customKey] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        let dns = FolioEncryptedDNS.shared
        if provider != "off" {
            dns.provider = FolioEncryptedDNS.Provider(rawValue: provider)!
            if provider == "nextdns" { dns.nextDNSID = value }
            if provider == "custom" { dns.customURL = value }
            dns.enabled = true
        }
        try? await Task.sleep(for: .seconds(1)) // let the debounced check from the setters pass
        await dns.apply()
        print("STATUS \(name) \(dns.status)")
        if dns.status == .needsSetup { return }
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
                print("FETCH \(name) \(URL(string: url)!.host!) HTTP \((response as! HTTPURLResponse).statusCode)")
            } catch {
                print("FETCH \(name) \(URL(string: url)!.host!) error \((error as NSError).code)")
            }
        }
        for key in [FolioEncryptedDNS.key, FolioEncryptedDNS.providerKey, FolioEncryptedDNS.nextDNSKey, FolioEncryptedDNS.customKey] {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}
SWIFT
swiftc -swift-version 5 -parse-as-library "$here/../app/Sources/Folio/EncryptedDNS.swift" "$scratch/main.swift" -o "$scratch/folio-dns-check" 2>&1 | grep -E 'error' && exit 1
cd "$scratch"
# name provider value expected-status
cases=(
  "dnsoff off - off"
  "dnscloudflare cloudflare - active"
  "dnsgoogle google - active"
  "dnsquad9 quad9 - active"
  "dnsadguard adguard - active"
  "dnsmullvad mullvad - active"
  "dnsnextdns nextdns ${FOLIO_TEST_NEXTDNS_ID:-abc123} active"
  "dnscustom custom https://dns.google/dns-query active"
  "dnsdown custom https://192.0.2.1/dns-query unavailable"
  "dnsunset nextdns - needsSetup"
)
: > expected.txt
for c in $cases; do
  set -- ${=c}
  cp folio-dns-check "$1"
  v="$3"; [[ "$v" == "-" ]] && v=""
  ./"$1" "$1" "$2" "$v" > "$1.txt"
  cat "$1.txt"
  echo "$1 $4" >> expected.txt
done
sleep 2
/usr/bin/log show --last 5m --predicate 'process == "mDNSResponder" AND eventMessage CONTAINS "getaddrinfo start"' 2>/dev/null \
  | grep -oE 'options: 0x[0-9A-F]+ \{[^}]*\}, client pid: [0-9]+ \(dns[a-z0-9]+\)' \
  | sed -E 's/client pid: [0-9]+ //' | sort | uniq -c > resolver.txt || true
cat resolver.txt
python3 - "$scratch" <<'PY'
import sys
from pathlib import Path
root = Path(sys.argv[1])
res = (root / 'resolver.txt').read_text().splitlines()
fails = []
for line in (root / 'expected.txt').read_text().split('\n'):
    if not line: continue
    name, want = line.split()
    text = (root / f'{name}.txt').read_text()
    if f'STATUS {name} {want}' not in text:
        fails.append(f'{name}: expected {want}, got {text.splitlines()[0] if text else "nothing"}'); continue
    if want == 'needsSetup':
        print(f'PASS {name}: asks for setup'); continue
    for host in ['openlibrary.org', 'api.hardcover.app', 'www.gutenberg.org']:
        l = next(l for l in text.splitlines() if f' {host} ' in l)
        if 'HTTP' not in l: fails.append(f'{name}: request failed: {l}')
    fresh = next(l for l in text.splitlines() if 'nip.io' in l)
    if 'error -1004' not in fresh: fails.append(f'{name}: fresh name did not resolve: {fresh}')
    mine = [l for l in res if f'({name})' in l]
    encrypted = any('need-encryption' in l for l in mine)
    if want == 'active' and not encrypted: fails.append(f'{name}: lookups were not encrypted: {mine}')
    if want != 'active' and encrypted: fails.append(f'{name}: used encryption while {want}: {mine}')
    print(f'PASS {name}: {want}, every host answers, ' + ('lookups encrypted' if want == 'active' else 'network DNS'))
if fails:
    print('\n'.join('FAIL ' + f for f in fails)); sys.exit(1)
PY
