import SwiftUI

/// Preview and screenshot hooks kept outside the production navigation view.
/// None of these routes run unless explicitly requested by an environment flag.
@MainActor
enum FolioLaunchDiagnostics {
    static func run(library: LibraryStore, hardcover: HardcoverClient,
                    openWindow: OpenWindowAction,
                    navigate: @escaping @MainActor (SidebarItem) -> Void) async {
        if let q = ProcessInfo.processInfo.environment["FOLIO_DETAIL_THEN_SERIES"] {
            try? await Task.sleep(for: .milliseconds(600))
            if let book = try? await hardcover.search(q).first {
                PopupCenter.shared.show(AnyView(HCBookDetail(book: book))) {}
                try? await Task.sleep(for: .milliseconds(1500))
                if let series = try? await hardcover.series(forBook: book.id).first {
                    Router.shared.open(.series(name: series.name, hardcoverID: series.id))
                }
            }
        }
        if let number = ProcessInfo.processInfo.environment["FOLIO_SELECT_SHELF"].flatMap(Int.init),
           let shelf = HCStatus(rawValue: number) { navigate(.shelf(shelf)) }
        if ProcessInfo.processInfo.environment["FOLIO_SELECT_SEARCH"] != nil { navigate(.search) }
        if ProcessInfo.processInfo.environment["FOLIO_SELECT_DOWNLOADING"] != nil { navigate(.downloading) }
        if let series = ProcessInfo.processInfo.environment["FOLIO_OPEN_SERIES"] {
            try? await Task.sleep(for: .milliseconds(300))
            navigate(.library(.all))
            try? await Task.sleep(for: .milliseconds(50))
            Router.shared.open(.series(name: series, hardcoverID: nil))
        }
        if let author = ProcessInfo.processInfo.environment["FOLIO_OPEN_AUTHOR"] {
            try? await Task.sleep(for: .milliseconds(300))
            while library.importing > 0 { try? await Task.sleep(for: .milliseconds(100)) }
            navigate(.library(.all))
            try? await Task.sleep(for: .milliseconds(50))
            Router.shared.open(.author(author))
        }
        if ProcessInfo.processInfo.environment["FOLIO_INFO_LATEST"] != nil {
            try? await Task.sleep(for: .milliseconds(300))
            if let id = library.recentlyAdded.first?.id { BookDetailsPresenter.showLocal(id) }
        }
        if let value = ProcessInfo.processInfo.environment["FOLIO_INFO_BOOK_ID"],
           let id = UUID(uuidString: value), library.book(id) != nil {
            try? await Task.sleep(for: .milliseconds(300))
            BookDetailsPresenter.showLocal(id)
        }
        if ProcessInfo.processInfo.environment["FOLIO_OPEN_LATEST"] != nil {
            try? await Task.sleep(for: .milliseconds(400))
            while library.importing > 0 { try? await Task.sleep(for: .milliseconds(100)) }
            if let book = library.recentlyAdded.first { openWindow(id: "reader", value: book.id) }
        }
    }
}
