#!/bin/bash
# Verifies the actual shared FolioMobileNavigation implementation resets its
# pushed navigation state on top-level tab changes and tab reselection.
set -euo pipefail
cd "$(dirname "$0")/.."
scratch=$(mktemp -d "${TMPDIR:-/tmp/}folio-navigation-reset.XXXXXXXX")
trap 'rm -rf "$scratch"' EXIT
python3 - "$scratch/navigation.swift" <<'PY'
from pathlib import Path
import sys
source = Path('app/iOS/Sources/FolioiOSApp.swift').read_text()
start = source.index('@Observable\n@MainActor\nfinal class FolioMobileNavigation {')
end = source.index('\n}', start) + 2
Path(sys.argv[1]).write_text('''import SwiftUI
import Observation

enum FolioMobileTab { case home, library, search, downloads, sources, settings }
enum FolioMobileLibraryScope { case books, shelves }
enum HCStatus { case reading, read }
struct FolioMobileReading: Identifiable { let id: UUID }

''' + source[start:end] + '''

@main struct NavigationResetTest {
    @MainActor static func main() {
        let nav = FolioMobileNavigation()
        let initial = nav.navigationRootID
        nav.selectedTab = .settings
        precondition(nav.navigationRootID != initial)
        nav.morePath.append("Goodreads")
        precondition(nav.morePath.count == 1)

        let inSettings = nav.navigationRootID
        nav.selectedTab = .library
        precondition(nav.morePath.count == 0, "Settings submenu must close on sidebar change")
        precondition(nav.navigationRootID != inSettings, "New sidebar tab needs a fresh navigation root")

        let inLibrary = nav.navigationRootID
        nav.selectedTab = .library
        precondition(nav.navigationRootID != inLibrary, "Reselecting a tab must return to its root")

        nav.selectedTab = .settings
        nav.morePath.append("Settings")
        let inMore = nav.navigationRootID
        nav.selectedTab = .settings // tapping More again
        precondition(nav.morePath.isEmpty, "Tapping More again must close Settings/Downloads/Sources")
        precondition(nav.navigationRootID != inMore, "Tapping More again must return to its root")

        nav.selectedTab = .settings
        nav.morePath.append("Sync")
        nav.openShelf(.reading)
        precondition(nav.selectedTab == .library)
        precondition(nav.morePath.isEmpty, "Programmatic navigation must dismiss stale More submenu")
        print("PASS sidebar switches, tab reselect and programmatic navigation discard stale submenus")
    }
}
''')
PY
swiftc -swift-version 5 -parse-as-library "$scratch/navigation.swift" -o "$scratch/test"
"$scratch/test"
