// swiftc -swift-version 5 app/Sources/Folio/BookAutoMatch.swift app/Sources/Folio/EditionTitle.swift checks/test-localized-edition-title.swift -o /tmp/t && /tmp/t
import Foundation

@main struct LocalizedEditionTitleCheck {
    static func main() {
        let cases: [(String, String, String)] = [
            ("Casa capitular / Chapterhouse Dune", "Chapterhouse: Dune", "Casa capitular"),
            ("Chapterhouse: Dune / Casa capitular", "Chapterhouse: Dune", "Casa capitular"),
            ("Duna = Dune", "Dune", "Duna"),
            ("Casa Capitular: Dune", "Chapterhouse: Dune", "Casa Capitular: Dune"),
            ("Harry Potter y el prisionero de Azkaban", "Harry Potter and the Prisoner of Azkaban", "Harry Potter y el prisionero de Azkaban"),
            // Neither part is the original: keep the whole title.
            ("Ida / Vuelta", "Dune", "Ida / Vuelta"),
            // Both parts translated, original absent: keep as is.
            ("El hobbit / Bilbo", "The Hobbit", "El hobbit / Bilbo"),
        ]
        var failed = false
        for (edition, original, want) in cases {
            let got = BookAutoMatch.localizedEditionTitle(edition, original: original)
            print(got == want ? "PASS" : "FAIL", "\(edition) [\(original)] -> \(got)")
            if got != want { failed = true }
        }
        exit(failed ? 1 : 0)
    }
}
