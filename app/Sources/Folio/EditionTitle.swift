import Foundation

extension BookAutoMatch {
    /// Catalogues often list a translation under both titles, such as
    /// "Casa capitular / Chapterhouse Dune". Drop the original-language part
    /// so sources are searched with the translated title alone.
    static func localizedEditionTitle(_ edition: String, original: String) -> String {
        let trimmed = edition.trimmingCharacters(in: .whitespacesAndNewlines)
        let originalWords = words(original)
        guard !originalWords.isEmpty else { return trimmed }
        for separator in [" / ", " = ", " | "] where trimmed.contains(separator) {
            let parts = trimmed.components(separatedBy: separator)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !words($0).isEmpty }
            let isOriginal = { (part: String) in
                sameTitle(original, part) || words(part).sorted() == originalWords.sorted()
            }
            let kept = parts.filter { !isOriginal($0) }
            if kept.count == 1, kept.count < parts.count { return kept[0] }
        }
        return trimmed
    }
}

/// Catalogues store the same edition title in very different shapes:
/// "CAMINO DE LOS REYES (EL ARCHIVO DE LAS TORMENTAS 1)", "Juramentada /
/// Oathbringer", "El camino de los reyes". Titles are never rewritten: among a
/// book's real edition titles, the best-formed one is picked.
enum EditionTitle {
    /// Leading articles one catalogue keeps and another drops
    /// ("El camino de los reyes" / "Camino de los reyes").
    static let leadingArticles: Set<String> = [
        "the", "a", "an", "el", "la", "los", "las", "lo", "le", "les", "l",
        "il", "gli", "der", "die", "das", "o", "os", "as"
    ]

    static func hasLeadingArticle(_ title: String) -> Bool {
        let w = BookAutoMatch.words(title)
        return w.count > 1 && leadingArticles.contains(w[0])
    }

    /// The words that name a title, for comparing catalogue records of one
    /// book: case, a leading article, the original half of a bilingual title
    /// ("Juramentada / Oathbringer") and a trailing numbered series label in
    /// brackets ("(El archivo de las tormentas 1)") are ignored. Only used to
    /// compare; titles are never shown this way.
    static func titleCore(_ title: String) -> [String] {
        var value = title.trimmingCharacters(in: .whitespacesAndNewlines)
        for separator in [" / ", " = ", " | "] where value.contains(separator) {
            value = value.components(separatedBy: separator)[0]
        }
        while let range = value.range(of: #"\s*[\(\[]([^\(\)\[\]]*)[\)\]]\s*$"#, options: .regularExpression) {
            let label = BookAutoMatch.words(String(value[range]))
            let numbered = label.contains { Int($0) != nil } || value[range].contains("#")
            let rest = String(value[..<range.lowerBound])
            guard numbered || label.contains(where: { ["edition", "edicion", "spanish", "espanol", "bolsillo", "pocket"].contains($0) }),
                  !BookAutoMatch.words(rest).isEmpty else { break }
            value = rest
        }
        var w = BookAutoMatch.words(value)
        if w.count > 1, leadingArticles.contains(w[0]) { w.removeFirst() }
        return w
    }

    /// How far a title is from one printed on a cover: 0 for a clean one.
    static func penalty(_ raw: String) -> Int {
        let title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var score = 0
        let letters = title.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        let upper = letters.filter { CharacterSet.uppercaseLetters.contains($0) }.count
        if letters.count >= 4, upper * 10 >= letters.count * 9 { score += 4 }
        if [" / ", " = ", " | "].contains(where: { title.contains($0) }) { score += 3 }
        if title.range(of: #"[\(\[][^\(\)\[\]]*[\)\]]\s*$"#, options: .regularExpression) != nil { score += 2 }
        if title.range(of: #"(?i)[:,\-–]\s*[^:,]*\b(?:saga|serie|series|libro|book|vol|volumen|volume|tomo|trilog[ií]a|trilogy)\b[^:,]*\d+\s*$"#,
                       options: .regularExpression) != nil { score += 2 }
        if title.range(of: #"\s{2,}"#, options: .regularExpression) != nil { score += 1 }
        return score
    }

    /// The best-formed real title for `chosen` among other titles of the same
    /// book in the same language. Only a title for the same book counts (same
    /// words once case, a leading article and a series label are ignored); it
    /// wins when it keeps the leading article or is better formed. Otherwise
    /// `chosen` stays exactly as it is.
    static func best(_ chosen: String, among others: [String]) -> String {
        let wanted = titleCore(chosen)
        guard !wanted.isEmpty else { return chosen }
        var best = chosen
        var bestPenalty = penalty(chosen)
        var bestArticle = hasLeadingArticle(chosen)
        for other in others where !other.isEmpty && titleCore(other) == wanted {
            let otherPenalty = penalty(other)
            let otherArticle = hasLeadingArticle(other)
            if otherPenalty < bestPenalty || (otherPenalty == bestPenalty && otherArticle && !bestArticle) {
                best = other.trimmingCharacters(in: .whitespacesAndNewlines)
                bestPenalty = otherPenalty
                bestArticle = otherArticle
            }
        }
        return best
    }

    /// The title to show for a book in the reading language, picked among its
    /// real edition titles in that language (most-read first). A title already
    /// in that language keeps its form unless a sibling edition is better
    /// formed; any other title ("The Way of Kings") becomes the language's own
    /// ("El camino de los reyes"). Without editions in it, `current` stays.
    static func languageTitle(_ current: String, among titles: [String]) -> String {
        let titles = titles.filter { !BookAutoMatch.words($0).isEmpty }
        guard !titles.isEmpty else { return current }
        let core = titleCore(current)
        if !core.isEmpty, titles.contains(where: { titleCore($0) == core }) {
            return best(current, among: titles)
        }
        let pick = titles.first { penalty($0) == 0 } ?? titles[0]
        return best(pick, among: titles)
    }
}
