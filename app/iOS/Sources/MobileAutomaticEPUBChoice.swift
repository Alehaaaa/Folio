#if os(iOS)
import Foundation

/// Kept in sync with macOS BookFlow/AutomaticEPUBChoice.swift. The desktop-only source contains
/// AppKit presentation types and cannot be compiled in the native iOS target.
/// Only exact bibliographic EPUB matches are eligible for unattended fetching.
enum AutomaticEPUBChoice {
    static func sameTitle(_ expected: String, _ actual: String) -> Bool {
        BookAutoMatch.sameEditionTitle(expected, actual)
    }

    static func sameAuthor(_ expected: String, _ actual: String) -> Bool {
        let words = BookAutoMatch.words(expected)
        guard !words.isEmpty else { return false }
        if words.count == 1 { return words == BookAutoMatch.words(actual) }
        return BookAutoMatch.sameEditionAuthor(expected, actual)
    }

    static func ranked(_ copies: [ExtensionStore.Copy], title: String, author: String,
                       expectedLanguage: String = BookLanguage.preferred) -> [ExtensionStore.Copy] {
        copies.filter {
            $0.result.preferred?.format == "epub" &&
            sameTitle(title, $0.result.title) && sameAuthor(author, $0.result.author) &&
            BookLanguage.matches($0.result.language, expected: expectedLanguage) != false
        }.sorted { a, b in
            let aExact = BookAutoMatch.sameTitle(title, a.result.title)
            let bExact = BookAutoMatch.sameTitle(title, b.result.title)
            if aExact != bExact { return aExact }
            let aVerified = BookLanguage.matches(a.result.language, expected: expectedLanguage) == true
            let bVerified = BookLanguage.matches(b.result.language, expected: expectedLanguage) == true
            if aVerified != bVerified { return aVerified }
            // Counts reported by unrelated providers are not comparable.
            if a.sourceID != b.sourceID { return a.sourceID < b.sourceID }
            let aCount = a.result.downloadCount.flatMap { $0 >= 0 ? $0 : nil }
            let bCount = b.result.downloadCount.flatMap { $0 >= 0 ? $0 : nil }
            if aCount != bCount { return (aCount ?? -1) > (bCount ?? -1) }
            // Prefer directly named EPUBs only when other evidence is equal.
            let aDirect = a.result.preferred?.url.pathExtension.lowercased() == "epub"
            let bDirect = b.result.preferred?.url.pathExtension.lowercased() == "epub"
            if aDirect != bDirect { return aDirect }
            if a.result.id != b.result.id { return a.result.id < b.result.id }
            return (a.result.preferred?.url.absoluteString ?? "") < (b.result.preferred?.url.absoluteString ?? "")
        }
    }
}
#endif
