import Foundation

/// Whether a catalogue book (Hardcover, Open Library, a source result) and a
/// library copy are the same book, whatever edition, catalogue or file wrote
/// the title. "Balada de Pájaros Cantores y Serpientes" from Open Library,
/// "Balada de pájaros cantores y serpientes (Los Juegos del Hambre)" from a
/// file and "Collins, Suzanne" as the byline are all one book.
///
/// Two titles match when one's full form equals any form of the other. Full
/// forms drop only series labels, brackets and a leading article; looser forms
/// also drop a subtitle after a colon or dash. Two loose forms never match each
/// other, so "Mistborn: The Final Empire" never stands for "Mistborn: Secret
/// History". Authors match by a shared surname.
enum LibraryMatch {
    struct Forms: Hashable {
        var full: Set<String> = []
        var loose: Set<String> = []
        var all: Set<String> { full.union(loose) }
    }

    /// The forms of every title a book is known by, bilingual parts included.
    static func forms(_ titles: [String]) -> Forms {
        var out = Forms()
        for title in titles {
            // "Juramentada / Oathbringer", but never each book of a box set
            // ("The Hunger Games / Catching Fire / Mockingjay").
            let parts = EditionTitle.bilingualParts(title)
            for value in [title] + (parts.count == 2 ? parts : []) {
                let f = forms(of: value)
                out.full.formUnion(f.full)
                out.loose.formUnion(f.loose)
            }
        }
        out.loose.subtract(out.full)
        return out
    }

    /// Lists ask for the same titles on every redraw, and each form runs a few
    /// regular expressions.
    private final class FormCache: @unchecked Sendable {
        let lock = NSLock()
        var forms: [String: Forms] = [:]
    }
    private static let cache = FormCache()

    static func forms(of title: String) -> Forms {
        cache.lock.lock()
        let hit = cache.forms[title]
        cache.lock.unlock()
        if let hit { return hit }
        let value = computeForms(title)
        cache.lock.lock()
        if cache.forms.count > 20_000 { cache.forms.removeAll() }
        cache.forms[title] = value
        cache.lock.unlock()
        return value
    }

    private static func computeForms(_ title: String) -> Forms {
        var out = Forms()
        let core = EditionTitle.titleCore(title)
        guard !core.isEmpty else { return out }
        out.full.insert(core.joined(separator: " "))
        // Every bracketed label, wherever it is: "(Los Juegos del Hambre)".
        let unbracketed = title.replacingOccurrences(of: #"\s*[\(\[][^\(\)\[\]]*[\)\]]"#, with: " ",
                                                     options: .regularExpression)
        add(unbracketed, to: &out.loose)
        // A file name's leading number: "01 - El camino de los reyes".
        let numbered = unbracketed.replacingOccurrences(of: #"^\s*[0-9]+\s*[\.\-–_]?\s+"#, with: "",
                                                        options: .regularExpression)
        add(numbered, to: &out.loose)
        // The title without its subtitle: "Dune: Edición ilustrada", "Balada… - Los Juegos del Hambre".
        for separator in [":", " - ", " – ", " — ", ". "] {
            if let range = numbered.range(of: separator) {
                add(String(numbered[..<range.lowerBound]), to: &out.loose)
            }
        }
        out.loose.subtract(out.full)
        return out
    }

    private static func add(_ value: String, to set: inout Set<String>) {
        var words = BookAutoMatch.words(value)
        if words.count > 1, EditionTitle.leadingArticles.contains(words[0]) { words.removeFirst() }
        guard !words.isEmpty, words.joined().count > 1 else { return }
        set.insert(words.joined(separator: " "))
    }

    /// The surnames in a byline, folded: "Suzanne Collins" and "Collins, Suzanne"
    /// share "collins"; "Brandon Sanderson & Dan Wells" gives both.
    static func surnames(_ byline: String) -> Set<String> {
        let separators = [" & ", " and ", " y ", " e ", " et ", " und ", ";", "/", ","]
        var segments = [byline]
        for separator in separators {
            segments = segments.flatMap { $0.components(separatedBy: separator) }
        }
        var out = Set<String>()
        for segment in segments {
            let words = BookAutoMatch.words(segment).filter { $0.count > 1 && Int($0) == nil }
            guard let last = words.last, !["unknown", "anonymous", "anonimo", "author", "varios"].contains(last) else { continue }
            out.insert(last)
        }
        return out
    }

    static func sameTitle(_ a: Forms, _ b: Forms) -> Bool {
        !a.full.isDisjoint(with: b.all) || !b.full.isDisjoint(with: a.all)
    }

    /// Authors agree when they share a surname. A side with no author at all
    /// (an untagged file) can't disagree.
    static func sameAuthor(_ a: Set<String>, _ b: Set<String>) -> Bool {
        a.isEmpty || b.isEmpty || !a.isDisjoint(with: b)
    }

    static func same(titles: [String], author: String, as otherTitles: [String], by otherAuthor: String) -> Bool {
        let a = surnames(author), b = surnames(otherAuthor)
        guard sameAuthor(a, b) else { return false }
        let fa = forms(titles), fb = forms(otherTitles)
        // Without an author on a side, only full titles count.
        if a.isEmpty || b.isEmpty { return !fa.full.isDisjoint(with: fb.full) }
        return sameTitle(fa, fb)
    }

    /// The library, looked up by title forms and surname at once.
    struct Index {
        private struct Entry { let position: Int; let surnames: Set<String>; let forms: Forms }
        private var entries: [Entry] = []
        private var byForm: [String: [Int]] = [:]

        init(_ books: [(title: String, author: String)]) {
            for (position, book) in books.enumerated() {
                let entry = Entry(position: position, surnames: LibraryMatch.surnames(book.author),
                                  forms: LibraryMatch.forms([book.title]))
                for form in entry.forms.all { byForm[form, default: []].append(entries.count) }
                entries.append(entry)
            }
        }

        /// Positions of the books that match, in library order.
        func matches(titles: [String], author: String) -> [Int] {
            let wanted = LibraryMatch.forms(titles)
            let names = LibraryMatch.surnames(author)
            var seen = Set<Int>()
            var out: [Int] = []
            for form in wanted.all {
                for i in byForm[form] ?? [] where seen.insert(i).inserted {
                    let entry = entries[i]
                    guard LibraryMatch.sameAuthor(names, entry.surnames) else { continue }
                    let match = names.isEmpty || entry.surnames.isEmpty
                        ? !wanted.full.isDisjoint(with: entry.forms.full)
                        : LibraryMatch.sameTitle(wanted, entry.forms)
                    if match { out.append(entry.position) }
                }
            }
            return out.sorted()
        }
    }
}
