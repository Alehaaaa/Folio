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
def block(header):
    i = source.index(header)
    return source[i:source.index('\n}\n', i) + 3]
shared = block('enum FolioMobileTabLayout: Equatable {') + '\n' + block('enum FolioMobileMoreRoute: Hashable, CaseIterable {')
Path(sys.argv[1]).write_text('''import SwiftUI
import Observation

enum FolioMobileTab { case home, library, search, downloads, settings, more }
enum FolioMobileLibraryScope { case books, shelves }
enum HCStatus { case reading, read }
struct FolioMobileReading: Identifiable { let id: UUID }

''' + shared + '''
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

        nav.selectedTab = .more
        nav.morePath.append("Settings")
        let inMore = nav.navigationRootID
        nav.selectedTab = .more // tapping More again
        precondition(nav.morePath.isEmpty, "Tapping More again must close Settings/Downloads")
        precondition(nav.navigationRootID != inMore, "Tapping More again must return to its root")

        nav.selectedTab = .settings
        nav.morePath.append("Sync")
        nav.openShelf(.reading)
        precondition(nav.selectedTab == .library)
        precondition(nav.morePath.isEmpty, "Programmatic navigation must dismiss stale More submenu")

        // Pages fold into More only when the bar can't hold them. iPhones (and compact
        // iPad windows) get at most five tabs, or UIKit hides Discover in its own More.
        // Source extensions live in Settings, so every layout fits the five-tab limit.
        for layout in [FolioMobileTabLayout.compact, .full] {
            let tabs = 2 + 2 - layout.moreRoutes.count + (layout.moreRoutes.isEmpty ? 0 : 1) + 1
            precondition(tabs <= FolioMobileTabLayout.maxTabs, "\(layout) has \(tabs) tabs")
        }
        precondition(FolioMobileTabLayout(width: 393, regular: false, phone: true) == .full, "iPhone portrait shows every tab")
        precondition(FolioMobileTabLayout(width: 932, regular: true, phone: true) == .full, "iPhone landscape")
        precondition(FolioMobileTabLayout(width: 320, regular: false, phone: false) == .compact, "Slide Over")
        precondition(FolioMobileTabLayout(width: 0, regular: false, phone: true) == .full, "Unknown width")
        precondition(FolioMobileTabLayout(width: 744, regular: true, phone: false).moreRoutes.isEmpty, "iPad mini portrait shows every tab")
        print("PASS sidebar switches, tab reselect and programmatic navigation discard stale submenus")
    }
}
''')
PY
swiftc -swift-version 5 -parse-as-library "$scratch/navigation.swift" -o "$scratch/test"
"$scratch/test"
