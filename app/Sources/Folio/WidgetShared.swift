import Foundation

/// A compact, account-free data contract between Folio and its WidgetKit extension.
/// Never store access tokens or private book contents here.
enum FolioWidgetStorage {
    #if os(iOS)
    // iOS requires a provisioned group.* identifier to share read-only
    // widget snapshots with the Folio WidgetKit extension.
    static let appGroup = "group.app.folio.reader.ios"
    #else
    // On macOS a Team-ID-prefixed group can be used without embedded provisioning profiles.
    static let appGroup = "L4947CL6Q2.app.folio.reader"
    #endif
    static let snapshotFile = "widget-snapshot.json"

    static var container: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
    }

    static var snapshotURL: URL? {
        container?.appendingPathComponent(snapshotFile)
    }

    static var coverDirectory: URL? {
        container?.appendingPathComponent("WidgetCovers", isDirectory: true)
    }

    static func read() -> FolioWidgetSnapshot? {
        guard let snapshotURL,
              let data = try? Data(contentsOf: snapshotURL) else { return nil }
        return try? JSONDecoder().decode(FolioWidgetSnapshot.self, from: data)
    }

    static func coverURL(for name: String) -> URL? {
        guard !name.contains("/"), !name.contains("\\"), name != ".", name != ".." else { return nil }
        return coverDirectory?.appendingPathComponent(name)
    }
}

struct FolioWidgetBook: Codable, Identifiable, Hashable {
    var id: String
    var title: String
    var author: String
    var progress: Double?
    var coverName: String?
    var deepLink: String
}

struct FolioWidgetList: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var symbol: String
    var count: Int
    var books: [FolioWidgetBook]
    var deepLink: String
}

struct FolioWidgetGoals: Codable, Hashable {
    var todayMinutes: Double = 0
    var dailyGoal: Int = 5
    var streak: Int = 0
    var finishedThisYear: Int = 0
    var yearlyGoal: Int = 3
}

struct FolioWidgetSnapshot: Codable {
    var updatedAt: Date = .now
    var lists: [FolioWidgetList] = []
    var goals = FolioWidgetGoals()

    /// Older widgets saved the three local status lists before they were merged
    /// into My Shelves. Preserve those configurations across the change.
    static func canonicalListID(_ id: String?) -> String? {
        switch id {
        case "reading": "shelf-2"
        case "want": "shelf-1"
        case "finished": "shelf-3"
        default: id
        }
    }

    func list(_ id: String?) -> FolioWidgetList {
        let resolvedID = Self.canonicalListID(id)
        return lists.first(where: { $0.id == resolvedID })
            ?? lists.first(where: { $0.id == "continue" })
            ?? Self.preview.lists[0]
    }

    static let preview = FolioWidgetSnapshot(
        lists: [
            FolioWidgetList(
                id: "continue", name: "Continue Reading", symbol: "book", count: 2,
                books: [
                    FolioWidgetBook(id: "preview1", title: "Your next chapter", author: "Continue reading in Folio", progress: 0.42, coverName: nil, deepLink: "folio-reader://library/reading"),
                    FolioWidgetBook(id: "preview2", title: "A good book awaits", author: "Your library", progress: 0.15, coverName: nil, deepLink: "folio-reader://library/all")
                ], deepLink: "folio-reader://library/reading"
            )
        ], goals: FolioWidgetGoals(todayMinutes: 3, dailyGoal: 5, streak: 2, finishedThisYear: 1, yearlyGoal: 3)
    )
}
