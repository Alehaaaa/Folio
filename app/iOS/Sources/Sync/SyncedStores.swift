import Foundation

/// The settings Folio Sync carries besides books: your ratings, followed
/// authors, saved series and edits to books you don't own. The Home nook's
/// arrangement and the reader's themes stay on each device, since screens differ.
@MainActor
enum FolioSyncedStores {
    static func register() {
        FolioSyncedValues.register("ratings",
            read: { FolioMyRatings.shared.syncJSON },
            write: { FolioMyRatings.shared.adoptSynced($0) })
        FolioSyncedValues.register("followedAuthors",
            read: { FolioFollowedAuthors.shared.syncJSON },
            write: { FolioFollowedAuthors.shared.adoptSynced($0) })
        FolioSyncedValues.register("savedSeries",
            read: { FolioSavedSeries.shared.syncJSON },
            write: { FolioSavedSeries.shared.adoptSynced($0) })
        FolioSyncedValues.register("bookEdits",
            read: { FolioBookOverrides.shared.syncJSON },
            write: { FolioBookOverrides.shared.adoptSynced($0) })
    }
}

/// Stable JSON for synced settings: sorted keys, so the same value always
/// reads the same and isn't taken for a change.
enum FolioSyncedJSON {
    static func encode<T: Encodable>(_ value: T) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) }
    }

    static func decode<T: Decodable>(_ json: String) -> T? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try? decoder.decode(T.self, from: Data(json.utf8))
    }
}
