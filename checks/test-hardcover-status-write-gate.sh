#!/bin/bash
# Compiles the production Hardcover status-write gate in isolation. No
# authentication, account data, network access or user mutations are involved.
set -euo pipefail
cd "$(dirname "$0")/.."
scratch=$(mktemp -d "${TMPDIR:-/tmp/}folio-status-gate.XXXXXXXX")
trap 'rm -rf "$scratch"' EXIT
python3 - "$scratch/test.swift" <<'PY'
from pathlib import Path
import sys
source = Path('app/Sources/Folio/Hardcover.swift').read_text()
start = source.index('/// Prevents a status batch')
end = source.index('\n@Observable', start)
gate = source[start:end]
Path(sys.argv[1]).write_text('''import Foundation
''' + gate + '''
actor Counter {
    var active = 0
    var peak = 0
    var completed = 0
    func begin() { active += 1; peak = max(peak, active) }
    func end() { active -= 1; completed += 1 }
    func result() -> (Int, Int) { (peak, completed) }
}
@main struct Test {
    static func main() async {
        let gate = HCStatusWriteGate.shared
        let count = Counter()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    await gate.enter()
                    await count.begin()
                    try? await Task.sleep(for: .milliseconds(10))
                    await count.end()
                    await gate.leave()
                }
            }
        }
        let (peak, total) = await count.result()
        precondition(peak == 1, "status mutations must never overlap")
        precondition(total == 20, "all waiting status mutations must finish")
        print("PASS 20 concurrent status writes serialize without lost waiters")
    }
}
''')
PY
swiftc -swift-version 5 -parse-as-library "$scratch/test.swift" -o "$scratch/test"
"$scratch/test"
