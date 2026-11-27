import SwiftUI
import Observation

struct FolioFollowedAuthor: Codable, Hashable, Identifiable {
    var id: String { FolioAuthorNames.key(name) }
    var hardcoverID: Int?
    var name: String
    var imageURL: URL?
}

/// Authors the reader follows, kept on this device.
@Observable
@MainActor
final class FolioFollowedAuthors {
    static let shared = FolioFollowedAuthors()
    private static let defaultsKey = "folio.followedAuthors"

    private(set) var authors: [FolioFollowedAuthor] = []

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let saved = try? JSONDecoder().decode([FolioFollowedAuthor].self, from: data) {
            authors = saved
        }
    }

    func isFollowing(_ name: String) -> Bool {
        let key = FolioAuthorNames.key(name)
        return authors.contains { $0.id == key }
    }

    func toggle(name: String, hardcoverID: Int?, imageURL: URL?) {
        let key = FolioAuthorNames.key(name)
        if let index = authors.firstIndex(where: { $0.id == key }) {
            authors.remove(at: index)
        } else {
            authors.insert(FolioFollowedAuthor(hardcoverID: hardcoverID, name: name, imageURL: imageURL), at: 0)
        }
        save()
    }

    /// Fill in an id or portrait learned later.
    func refresh(name: String, hardcoverID: Int?, imageURL: URL?) {
        let key = FolioAuthorNames.key(name)
        guard let index = authors.firstIndex(where: { $0.id == key }) else { return }
        if authors[index].hardcoverID == hardcoverID && authors[index].imageURL == imageURL { return }
        authors[index].hardcoverID = hardcoverID ?? authors[index].hardcoverID
        authors[index].imageURL = imageURL ?? authors[index].imageURL
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(authors) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
        FolioSyncedValues.changed()
    }

    /// Folio Sync: the followed authors as one JSON value.
    var syncJSON: String? { FolioSyncedJSON.encode(authors) }

    /// Takes another device's followed authors.
    func adoptSynced(_ json: String) {
        guard let theirs: [FolioFollowedAuthor] = FolioSyncedJSON.decode(json) else { return }
        authors = theirs
        if let data = try? JSONEncoder().encode(authors) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }
}
