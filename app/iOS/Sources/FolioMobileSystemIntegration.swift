import CoreSpotlight
import ImageIO
import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - Home-screen quick actions

/// The book a Home-screen quick action asked to open, until the app shows it.
@Observable
@MainActor
final class FolioShortcutRouter {
    static let shared = FolioShortcutRouter()
    static let readType = "folio.read"

    var pending: UUID?

    func handle(_ item: UIApplicationShortcutItem) {
        guard item.type == Self.readType,
              let raw = item.userInfo?["id"] as? String,
              let id = UUID(uuidString: raw) else { return }
        pending = id
    }
}

/// Receives quick actions: at launch through the scene options, later through the scene delegate.
final class FolioAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        if let item = options.shortcutItem { FolioShortcutRouter.shared.handle(item) }
        let configuration = UISceneConfiguration(name: nil, sessionRole: session.role)
        configuration.delegateClass = FolioSceneDelegate.self
        return configuration
    }
}

final class FolioSceneDelegate: NSObject, UIWindowSceneDelegate {
    func windowScene(_ windowScene: UIWindowScene, performActionFor shortcutItem: UIApplicationShortcutItem,
                     completionHandler: @escaping (Bool) -> Void) {
        FolioShortcutRouter.shared.handle(shortcutItem)
        completionHandler(true)
    }
}

// MARK: - Quick actions and Spotlight

@MainActor
enum FolioSystemIntegration {
    nonisolated private static let domain = "folio.library"
    private static var indexedFingerprint: Int?

    /// Refreshes the quick actions (the books opened last) and the iPhone search index.
    static func update(_ library: LibraryStore) {
        let recent = library.books
            .filter { $0.status != .finished && $0.lastOpenedAt != nil }
            .sorted { ($0.lastOpenedAt ?? .distantPast) > ($1.lastOpenedAt ?? .distantPast) }
            .prefix(3)
        UIApplication.shared.shortcutItems = recent.map { book in
            UIApplicationShortcutItem(
                type: FolioShortcutRouter.readType,
                localizedTitle: book.title,
                localizedSubtitle: nil,
                icon: UIApplicationShortcutIcon(systemImageName: "book"),
                userInfo: ["id": book.id.uuidString as NSString]
            )
        }
        indexForSearch(library)
    }

    /// Library books in iPhone search: title, author and a small cover. Only re-indexed
    /// when a book's title, author or cover changes.
    private static func indexForSearch(_ library: LibraryStore) {
        struct Entry: Sendable {
            let id: String, title: String, author: String
            let cover: URL?
        }
        let entries = library.books.map {
            Entry(id: $0.id.uuidString, title: $0.title, author: $0.author, cover: library.coverURL($0))
        }
        var hasher = Hasher()
        for entry in entries {
            hasher.combine(entry.id)
            hasher.combine(entry.title)
            hasher.combine(entry.author)
            hasher.combine(entry.cover)
        }
        let fingerprint = hasher.finalize()
        guard fingerprint != indexedFingerprint else { return }
        indexedFingerprint = fingerprint
        Task.detached(priority: .background) {
            let items = entries.map { entry -> CSSearchableItem in
                let attributes = CSSearchableItemAttributeSet(contentType: .content)
                attributes.title = entry.title
                attributes.contentDescription = entry.author
                if !entry.author.isEmpty { attributes.authorNames = [entry.author] }
                attributes.thumbnailData = entry.cover.flatMap { Self.thumbnail($0) }
                return CSSearchableItem(uniqueIdentifier: entry.id, domainIdentifier: Self.domain, attributeSet: attributes)
            }
            let index = CSSearchableIndex.default()
            index.deleteSearchableItems(withDomainIdentifiers: [Self.domain]) { _ in
                index.indexSearchableItems(items) { error in
                    if let error { FolioLog.log("Spotlight: \(error.localizedDescription)", "search") }
                }
            }
        }
    }

    nonisolated private static func thumbnail(_ url: URL) -> Data? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 180
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: image).jpegData(compressionQuality: 0.7)
    }

    /// The book id of a tapped iPhone search result.
    static func bookID(from activity: NSUserActivity) -> UUID? {
        (activity.userInfo?[CSSearchableItemActivityIdentifier] as? String).flatMap(UUID.init(uuidString:))
    }
}
