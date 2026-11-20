import Foundation

/// Only full bibliographic matches can trigger an unattended download. The source's genuine
/// download count, when exposed, can rank equivalent editions; mirror-link counts never do.
enum AutomaticEPUBChoice {
    static func sameTitle(_ expected: String, _ actual: String) -> Bool {
        BookAutoMatch.sameEditionTitle(expected, actual)
    }

    static func sameAuthor(_ expected: String, _ actual: String) -> Bool {
        let words = BookAutoMatch.words(expected)
        guard !words.isEmpty else { return false }
        // One-word author names (e.g. Homer) must match in full, too.
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
            // A declared matching language outranks any unknown edition,
            // regardless of popularity or source.
            let aVerified = BookLanguage.matches(a.result.language, expected: expectedLanguage) == true
            let bVerified = BookLanguage.matches(b.result.language, expected: expectedLanguage) == true
            if aVerified != bVerified { return aVerified }
            // Providers can count downloads differently; compare popularity only
            // between copies reported by the same source.
            if a.sourceID != b.sourceID { return a.sourceID < b.sourceID }
            let aCount = a.result.downloadCount.flatMap { $0 >= 0 ? $0 : nil }
            let bCount = b.result.downloadCount.flatMap { $0 >= 0 ? $0 : nil }
            if aCount != bCount { return (aCount ?? -1) > (bCount ?? -1) }
            // A direct EPUB URL is a modest reliability signal, not a popularity estimate.
            let aDirect = a.result.preferred?.url.pathExtension.lowercased() == "epub"
            let bDirect = b.result.preferred?.url.pathExtension.lowercased() == "epub"
            if aDirect != bDirect { return aDirect }
            // Stable tie-breaker even when servers return equal-quality copies in new orders.
            if a.result.id != b.result.id { return a.result.id < b.result.id }
            return (a.result.preferred?.url.absoluteString ?? "") < (b.result.preferred?.url.absoluteString ?? "")
        }
    }
}

