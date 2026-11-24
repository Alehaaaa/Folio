#!/bin/zsh
# Compile the actual production HCRateGate actor (no API credentials/network),
# verify a shared 429 breaker and bounded request concurrency.
set -euo pipefail
cd "${0:A:h}/.."
scratch=$(mktemp -d "${TMPDIR:-/tmp/}folio-hardcover-gate.XXXXXXXX")
trap 'rm -rf -- "$scratch"' EXIT
python3 - "$scratch/fixture.swift" <<'PY'
from pathlib import Path
import sys
source=Path('app/Sources/Folio/Hardcover.swift').read_text()
start=source.index('actor HCRateGate {')
end=source.index('\n@Observable',start)
gate=source[start:end]
Path(sys.argv[1]).write_text('''import Foundation
struct HCError: Error { var message: String; var rateLimited = false }
''' + gate + '''
@main struct Test {
  static func main() async throws {
    let gate = HCRateGate.shared
    try await gate.wait()
    await gate.noteRateLimit(retryAfter: "5")
    let first = Date()
    var denied = 0
    await withTaskGroup(of: Bool.self) { group in
      for _ in 0..<20 {
        group.addTask {
          do { try await gate.wait(); return false }
          catch let e as HCError { return e.rateLimited }
          catch { return false }
        }
      }
      for await rejected in group where rejected { denied += 1 }
    }
    guard denied == 20, Date().timeIntervalSince(first) < 1 else {
      fatalError("429 breaker failed fast or allowed requests: \\(denied)")
    }
    print("PASS 429: 20 concurrent requests rejected locally without network or queue wait")
    try await Task.sleep(for: .seconds(5.1))
    let restored = Date()
    try await gate.wait()
    guard Date().timeIntervalSince(restored) < 0.7 else { fatalError("Breaker did not recover") }
    let paced = Date()
    try await withThrowingTaskGroup(of: Void.self) { group in
      for _ in 0..<5 { group.addTask { try await gate.wait() } }
      for try await _ in group { }
    }
    let elapsed = Date().timeIntervalSince(paced)
    guard elapsed >= 0.6, elapsed < 4 else { fatalError("Unsafe burst pacing: \\(elapsed)") }
    print(String(format:"PASS recovery and shared request pacing: five dispatches in %.2fs",elapsed))
  }
}
''')
PY
swiftc -swift-version 5 -parse-as-library "$scratch/fixture.swift" -o "$scratch/test"
"$scratch/test"
