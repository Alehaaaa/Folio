#!/bin/bash
# Folio Sync: merge rules and sealing. Needs swiftc (macOS, for CryptoKit).
# LIVE=1 also round-trips a sealed document through the public store.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cp "$ROOT/checks/test-cloud-sync.swift" "$TMP/main.swift"
swiftc -O -o "$TMP/merge" "$ROOT/app/Sources/Folio/CloudSyncCore.swift" "$TMP/main.swift"
"$TMP/merge"

if [ "${LIVE:-0}" = 1 ]; then
  cat > "$TMP/live.swift" <<'SWIFT'
import Foundation
let code = CloudSyncMerge.newCode()
let url = URL(string: "https://textdb.dev/api/data/")!.appendingPathComponent(CloudSyncBox.slot(for: code))
func get() async throws -> CloudSyncChannel {
    let (d, _) = try await URLSession.shared.data(from: url)
    return try CloudSyncBox.open(String(decoding: d, as: UTF8.self), code: code)
}
func put(_ c: CloudSyncChannel) async throws {
    var q = URLRequest(url: url); q.httpMethod = "POST"; q.setValue("text/plain", forHTTPHeaderField: "Content-Type")
    q.httpBody = Data(try CloudSyncBox.seal(c, code: code).utf8)
    let (_, r) = try await URLSession.shared.data(for: q)
    guard (r as! HTTPURLResponse).statusCode == 200 else { fatalError("POST \((r as! HTTPURLResponse).statusCode)") }
}
let books = (0..<800).map { i in CloudSyncRecord(keys: ["t:book\(i)", "isbn:978000000\(i)"], title: "A Fairly Long Book Title Number \(i)", author: "Some Author", progress: Double(i % 100) / 100, chapter: i % 30, fraction: 0.5, pdfPage: 0, status: "reading", finishedAt: nil, lastOpenedAt: Date(), collections: ["Favourites"], updatedAt: Date()) }
var c = try await get()
guard c.devices.isEmpty else { fatalError("new slot should be empty") }
c.devices["mac"] = CloudSyncDeviceDoc(deviceName: "Mac", platform: "mac", savedAt: Date(), books: books)
try await put(c)
var phone = try await get()
guard phone.devices["mac"]?.books.count == 800 else { fatalError("phone should see the mac's books") }
phone.devices["phone"] = CloudSyncDeviceDoc(deviceName: "iPhone", platform: "iphone", savedAt: Date(), books: [])
try await put(phone)
guard Set(try await get().devices.keys) == ["mac", "phone"] else { fatalError("both devices kept") }
print("ok   live round trip through the store (\(try CloudSyncBox.seal(phone, code: code).count) bytes for 800 books)")
SWIFT
  cp "$TMP/live.swift" "$TMP/main.swift"
  swiftc -O -o "$TMP/live" "$ROOT/app/Sources/Folio/CloudSyncCore.swift" "$TMP/main.swift"
  "$TMP/live"
fi
echo "All Folio Sync checks passed"
