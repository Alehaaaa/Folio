import Foundation
import NaturalLanguage

/// Conservative comparisons for linking an imported EPUB with a Hardcover catalogue book.
/// Nothing based on a partial/fuzzy title or the order of search results is auto-linked.
enum BookAutoMatch {
    struct Candidate: Equatable {
        let id: Int
        let title: String
        let authors: String
    }

    static func words(_ value: String) -> [String] {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    static func sameTitle(_ lhs: String, _ rhs: String) -> Bool {
        let a = words(lhs)
        return a.count > 0 && a == words(rhs)
    }

    static func sameAuthor(_ lhs: String, _ rhs: String) -> Bool {
        let a = words(lhs)
        guard a.count >= 2 else { return false }
        // Inverted EPUB creator names such as "Backman, Fredrik" are common.
        // Only reorder a person's name; never accept a substring of a surname.
        let normalized = a.sorted()
        if words(rhs).sorted() == normalized { return true }
        return rhs.split(separator: ",").contains { words(String($0)).sorted() == normalized }
    }

    /// Source catalogs often append a series name/number to the book title.
    /// Accept a recognized *bibliographic* suffix, never an arbitrary prefix
    /// or an adaptation. Keep sameTitle strict for Hardcover auto-linking.
    static func sameEditionTitle(_ expected: String, _ actual: String) -> Bool {
        if sameTitle(expected, actual) { return true }
        let wanted = words(expected)
        let found = words(actual)
        guard !wanted.isEmpty, found.count > wanted.count,
              Array(found.prefix(wanted.count)) == wanted else { return false }
        let extra = Array(found.dropFirst(wanted.count))
        // Only book/series descriptors are safe to ignore. This deliberately
        // does not turn arbitrary fuzzy/contains matching into auto-import.
        let disallowed: Set<String> = [
            "abridged", "adapted", "adaptation", "annotated", "commentary",
            "analysis", "summary", "summaries", "study", "guide", "workbook",
            "preview", "sample", "excerpts", "extract", "retelling", "parody",
            "graphic", "comic", "manga", "illustrated", "movie", "screenplay",
            "companion", "unofficial", "fan", "collection", "omnibus",
            "novella", "shortened", "simplified", "translation",
            "bundle", "boxset", "boxed", "anthology", "complete",
            "key", "takeaways", "readers", "recap", "questions", "review"
        ]
        guard extra.count <= 20, !extra.contains(where: { disallowed.contains($0) }) else { return false }
        // Multiple volumes bundled under the first book's title are not the
        // individual book, even if the catalog says "Books 1-3".
        let suffix = actual.dropFirst(min(actual.count, expected.count))
        if suffix.range(of: #"(?i)\bbooks?\s+[0-9]+\s*[-–]\s*[0-9]+\b"#,
                        options: .regularExpression) != nil { return false }
        let descriptors: Set<String> = [
            "series", "saga", "book", "books", "volume", "vol",
            "part", "novel", "cycle", "chronicles"
        ]
        // A few catalogues append a plain '#4' or '(4)' series number.
        let numericEdition = extra.count <= 3 &&
            extra.contains(where: { Int($0) != nil }) &&
            actual.contains(where: { $0 == "#" || $0 == "(" })
        if extra.contains(where: { descriptors.contains($0) }) || numericEdition { return true }
        // Some catalogues add the work's normal, descriptive subtitle rather
        // than a series label (e.g. "Want: Sexual Fantasies by Anonymous").
        // Require one real subtitle, not a concatenation of catalogue aliases,
        // a repeated title, a bundled work, or a study/preview adaptation.
        let parts = actual.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, sameTitle(expected, String(parts[0])),
              (2...6).contains(extra.count) else { return false }
        let prefixWords = Set(wanted)
        guard !extra.contains(where: { prefixWords.contains($0) }) else { return false }
        return true
    }

    /// A role label like "Pierce Brown (Author)" is formatting, not a new
    /// contributor. Other people and translator/editor names remain excluded.
    static func sameEditionAuthor(_ expected: String, _ actual: String) -> Bool {
        if words(expected).count == 1 { return words(expected) == words(actual) }
        if sameAuthor(expected, actual) { return true }
        var actualWords = words(actual)
        // Providers sometimes join editor and author credit for the same
        // person, e.g. "Gillian Anderson (ed) Anderson, Gillian".
        // Ignore only standalone role *words*, never different contributors.
        actualWords.removeAll { ["author", "writer", "editor", "edited", "ed"].contains($0) }
        if sameAuthor(expected, actualWords.joined(separator: " ")) { return true }
        // Some Anna result rows duplicate the same writer as both a library
        // catalog name and a normalized name: "Brown, Pierce Pierce Brown".
        // Each repeated segment must consist of precisely the same author;
        // never accept a different co-author or editor.
        let wanted = words(expected).sorted()
        let count = wanted.count
        guard count >= 2, actualWords.count == count * 2 else { return false }
        return Array(actualWords.prefix(count)).sorted() == wanted &&
               Array(actualWords.dropFirst(count)).sorted() == wanted
    }

    static func uniqueExact(title: String, author: String, in results: [Candidate]) -> Int? {
        guard !words(title).isEmpty, words(author).count >= 2 else { return nil }
        let ids = Set(results.filter { sameTitle(title, $0.title) && sameAuthor(author, $0.authors) }.map(\.id))
        return ids.count == 1 ? ids.first : nil
    }

    /// ISBNs must carry a correct check digit; opaque UUIDs and store IDs are ignored.
    static func isbn(in identifier: String) -> String? {
        let stripped = identifier.replacingOccurrences(
            of: "(?i)^\\s*(?:urn:)?isbn(?:-?1[03])?\\s*[:=-]?\\s*",
            with: "",
            options: .regularExpression
        )
        let compact = stripped.uppercased().filter { ("0"..."9").contains(String($0)) || $0 == "X" }
        let numbers = compact.compactMap(\.wholeNumberValue)
        switch compact.count {
        case 13 where numbers.count == 13 && (compact.hasPrefix("978") || compact.hasPrefix("979")):
            let sum = numbers.enumerated().reduce(0) { $0 + $1.element * ($1.offset.isMultiple(of: 2) ? 1 : 3) }
            return sum.isMultiple(of: 10) ? compact : nil
        case 10 where numbers.count >= 9:
            guard compact.prefix(9).allSatisfy({ ("0"..."9").contains(String($0)) }),
                  let last = compact.last, ("0"..."9").contains(String(last)) || last == "X" else { return nil }
            let firstNine = Array(numbers.prefix(9))
            let final = compact.hasSuffix("X") ? 10 : (numbers.last ?? -1)
            let sum = zip(firstNine, (2...10).reversed()).reduce(0) { $0 + $1.0 * $1.1 } + final
            return sum.isMultiple(of: 11) ? compact : nil
        default:
            return nil
        }
    }
}

/// Unambiguous edition languages only. Missing metadata is not English.
enum BookLanguage {
    static var preferred: String { code(Locale.preferredLanguages.first) ?? "en" }

    static func code(_ value: String?) -> String? {
        guard let value else { return nil }
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty, !text.contains(","), !text.contains(";"),
              !text.contains("/"), !["und", "mul", "unknown", "none", "n/a", "-"].contains(text)
        else { return nil }
        let aliases = [
            "english": "en", "german": "de", "deutsch": "de",
            "spanish": "es", "español": "es", "french": "fr", "français": "fr",
            "italian": "it", "portuguese": "pt", "dutch": "nl",
            "japanese": "ja", "chinese": "zh", "russian": "ru",
            "polish": "pl", "swedish": "sv", "norwegian": "no",
            "eng": "en", "deu": "de", "ger": "de", "spa": "es",
            "fra": "fr", "fre": "fr", "ita": "it", "por": "pt",
            "nld": "nl", "dut": "nl", "jpn": "ja", "zho": "zh",
            "chi": "zh", "rus": "ru"
        ]
        if let known = aliases[text] { return known }
        let primary = text.replacingOccurrences(of: "_", with: "-").split(separator: "-").first.map(String.init) ?? ""
        guard primary.count == 2 || primary.count == 3,
              primary.unicodeScalars.allSatisfy({ (97...122).contains(Int($0.value)) })
        else { return nil }
        return aliases[primary] ?? primary
    }

    /// The language of an EPUB: its declared dc:language, otherwise what the
    /// opening chapters are written in (only when the recognizer is confident).
    static func detect(declared: String?, chapters: [URL]) -> String? {
        if let code = code(declared) { return code }
        var sample = ""
        for url in chapters.prefix(12) {
            guard let html = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let text = html
                .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
                .replacingOccurrences(of: "&[a-zA-Z#0-9]+;", with: " ", options: .regularExpression)
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            sample += text + " "
            if sample.count > 6000 { break }
        }
        guard sample.count > 400 else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(sample.prefix(6000)))
        guard let best = recognizer.languageHypotheses(withMaximum: 1).first, best.value > 0.8 else { return nil }
        return code(best.key.rawValue)
    }

    /// English name Hardcover uses for a language ("es" is "Spanish").
    static func englishName(_ code: String) -> String? {
        Locale(identifier: "en_US").localizedString(forLanguageCode: code)
    }

    /// nil: language unverified, eligible for download and OPF inspection.
    /// false: the source explicitly advertises the wrong language.
    static func matches(_ actual: String?, expected: String) -> Bool? {
        guard let actual = code(actual), let expected = code(expected) else { return nil }
        return actual == expected
    }
}
