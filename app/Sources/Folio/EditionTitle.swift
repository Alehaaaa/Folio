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
