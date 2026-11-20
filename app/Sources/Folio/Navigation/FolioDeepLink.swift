import Foundation

/// The single place that interprets widget and external Folio links.
/// Legacy library status links route into the combined My Shelves views.
@MainActor
enum FolioDeepLink {
    case read(UUID)
    case select(SidebarItem)

    static func resolve(_ url: URL, library: LibraryStore) -> FolioDeepLink? {
        guard url.scheme == "folio-reader" else { return nil }
        let value = url.pathComponents.dropFirst().first
        switch url.host() {
        case "read":
            guard let id = value.flatMap(UUID.init(uuidString:)), library.book(id) != nil else { return nil }
            return .read(id)
        case "library":
            guard let filter = value.flatMap(LibraryFilter.init(rawValue:)) else { return nil }
            return .select(filter.unifiedShelf.map(SidebarItem.shelf) ?? .library(filter))
        case "collection":
            guard let id = value.flatMap(UUID.init(uuidString:)),
                  library.data.collections.contains(where: { $0.id == id }) else { return nil }
            return .select(.collection(id))
        case "shelf":
            guard let value, let status = Int(value).flatMap(HCStatus.init(rawValue:)) else { return nil }
            return .select(.shelf(status))
        case "goals": return .select(.goals)
        case "downloads": return .select(.downloading)
        default: return nil
        }
    }
}
