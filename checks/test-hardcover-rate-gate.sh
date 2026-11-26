#!/bin/zsh
# Compile the production HCRateGate actor (no API credentials/network) and check
# that it charges Hardcover's real per-field cost, follows its RateLimit headers,
# waits out short throttles and fails fast on long ones.
set -euo pipefail
cd "${0:A:h}/.."
scratch=$(mktemp -d "${TMPDIR:-/tmp/}folio-hardcover-gate.XXXXXXXX")
trap 'rm -rf -- "$scratch"' EXIT
python3 - "$scratch/fixture.swift" <<'PY'
from pathlib import Path
import sys
source=Path('app/Sources/Folio/Hardcover.swift').read_text()
start=source.index('/// Keeps requests under Hardcover')
end=source.index('\n@Observable',start)
gate=source[start:end]
Path(sys.argv[1]).write_text('''import Foundation
struct HCError: Error { var message: String; var rateLimited = false }
''' + gate + '''
func check(_ ok: Bool, _ what: String) { if !ok { fatalError(what) }; print("PASS " + what) }
@main struct Test {
  static func main() async throws {
    let bookPage = """
    query BookPage($id: Int!, $uid: Int!) {
      books(where: {id: {_eq: $id}}, limit: 1) { id title image { url } }
      editions(where: {book_id: {_eq: $id}}, order_by: {users_count: desc}, limit: 1) { id title } fallbackEdition: editions(limit: 1) { id }
      book_series(where: {book_id: {_eq: $id}}) { position series { id name } }
      user_books(where: {user_id: {_eq: $uid}, book_id: {_eq: $id}}, limit: 1) { id }
    }
    """
    check(HCRateGate.cost(of: bookPage) == 5, "book page costs its 5 top-level fields")
    check(HCRateGate.cost(of: "query { me { id username name image { url } } }") == 1, "me costs 1")
    check(HCRateGate.cost(of: "query T { a: me { id } b: me { name } __typename }") == 2, "aliases count, introspection is free")
    let batchedStatuses = """
    mutation StatusBatch {
      s0: update_user_book(id: 15, object: {status_id: 2}) { id error }
      s1: insert_user_book(object: {book_id: 23, status_id: 1}) { id error }
      d0: update_user_book_read(id: 99, object: {finished_at: "2026-11-24"}) { id error }
    }
    """
    check(HCRateGate.cost(of: batchedStatuses) == 3, "batched mutation charges each aliased write separately")
    check(HCRateGate.cost(of: "query S($q: String!) { search(query: $q, fields: \\"title,{x}\\") { results } }") == 1, "strings and arguments ignored")

    // A burst of book pages must stay inside the bucket (8 of Hardcover's 10).
    let gate = HCRateGate()
    let start = Date()
    var spent: [(Double, Int)] = []
    for _ in 0..<4 {
      try await gate.wait(cost: 5)
      spent.append((Date().timeIntervalSince(start), 5))
    }
    // Simulated server bucket: 10 capacity, 1/s refill; must never go negative.
    var bucket = 10.0, last = 0.0
    for (t, c) in spent { bucket = min(10, bucket + (t - last)); last = t; bucket -= Double(c); check(bucket >= 0, String(format: "server bucket never overdrawn at %.1fs (%.1f left)", t, bucket)) }

    // Server says only 1 left: the gate trusts it.
    let g2 = HCRateGate()
    await g2.noteHeaders(rateLimit: "\\"Free\\";r=1;t=0, \\"daily\\";r=4000;t=5000", policy: "\\"Free\\";q=60;w=60;burst=10, \\"daily\\";q=5000;w=86400")
    let t2 = Date(); try await g2.wait(cost: 3)
    check(Date().timeIntervalSince(t2) > 2, "follows RateLimit remaining from Hardcover")

    // Short 429: wait it out instead of failing.
    let g3 = HCRateGate()
    await g3.noteRateLimit(retryAfter: "2")
    let t3 = Date(); try await g3.wait(cost: 1)
    check(Date().timeIntervalSince(t3) >= 1.9, "short 429 is waited out")

    let paced = HCRateGate()
    try await paced.wait()
    let secondStart = Date()
    try await paced.wait()
    check(Date().timeIntervalSince(secondStart) >= 0.30, "startup requests are paced even with tokens available")

    let dated = HCRateGate()
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
    await dated.noteRateLimit(retryAfter: formatter.string(from: Date().addingTimeInterval(120)))
    do {
      try await dated.wait()
      fatalError("Long HTTP-date Retry-After must deny network admission")
    } catch let error as HCError {
      check(error.rateLimited, "HTTP-date Retry-After is honored")
    }

    // Daily limit used up: every caller fails at once, without touching the network.
    let g4 = HCRateGate()
    await g4.noteHeaders(rateLimit: "\\"daily\\";r=0;t=3600", policy: nil)
    var denied = 0
    let t4 = Date()
    await withTaskGroup(of: Bool.self) { group in
      for _ in 0..<20 { group.addTask { do { try await g4.wait(); return false } catch let e as HCError { return e.rateLimited } catch { return false } } }
      for await rejected in group where rejected { denied += 1 }
    }
    check(denied == 20 && Date().timeIntervalSince(t4) < 1, "daily limit rejects 20 callers locally and fast")
  }
}
''')
PY
swiftc -swift-version 5 -parse-as-library "$scratch/fixture.swift" -o "$scratch/test"
"$scratch/test"
