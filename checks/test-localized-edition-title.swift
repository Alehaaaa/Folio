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
        // Edition titles are picked among real ones, never rewritten.
        let picks: [(String, [String], String)] = [
            ("CAMINO DE REYES (SAGA EL ARCHIVO DE LAS TORMENTAS)",
             ["Palabras radiantes", "El camino de los reyes"], "El camino de los reyes"),
            ("El camino de reyes", ["El camino de los reyes"], "El camino de reyes"),
            ("CAMINO DE LOS REYES (EL ARCHIVO DE LAS TORMENTAS 1)",
             ["El camino de los reyes (El Archivo de las Tormentas 1)", "El camino de los reyes", "Palabras radiantes"],
             "El camino de los reyes"),
            ("CAMINO DE LOS REYES (EL ARCHIVO DE LAS TORMENTAS 1)", ["Palabras radiantes"],
             "CAMINO DE LOS REYES (EL ARCHIVO DE LAS TORMENTAS 1)"),
            ("Juramentada / Oathbringer", ["Juramentada", "JURAMENTADA"], "Juramentada"),
            ("El nombre del viento", ["EL NOMBRE DEL VIENTO", "Nombre del viento"], "El nombre del viento"),
        ]
        for (chosen, others, want) in picks {
            let got = EditionTitle.best(chosen, among: others)
            print(got == want ? "PASS" : "FAIL", "best \(chosen) -> \(got)")
            if got != want { failed = true }
        }
        let languageTitles = ["CAMINO DE LOS REYES (EL ARCHIVO DE LAS TORMENTAS 1)", "El camino de los reyes"]
        for (current, want) in [("The Way of Kings", "El camino de los reyes"),
                                ("CAMINO DE LOS REYES (EL ARCHIVO DE LAS TORMENTAS 1)", "El camino de los reyes"),
                                ("Elantris", "Elantris")] {
            let got = EditionTitle.languageTitle(current, among: current == "Elantris" ? [] : languageTitles)
            print(got == want ? "PASS" : "FAIL", "language \(current) -> \(got)")
            if got != want { failed = true }
        }
        // Untagged editions stand in only for the same title, never translate one.
        for (current, entries, want) in [
            ("CAMINO DE LOS REYES (EL ARCHIVO DE LAS TORMENTAS 1)",
             [EditionTitle.untaggedMark + "El camino de los reyes"], "El camino de los reyes"),
            ("The Way of Kings", [EditionTitle.untaggedMark + "El camino de los reyes"], "The Way of Kings"),
            ("", [String](), ""),
        ] {
            let got = EditionTitle.languageTitle(current, among: entries)
            print(got == want ? "PASS" : "FAIL", "untagged \(current) -> \(got)")
            if got != want { failed = true }
        }
        // Real data, 2026-11-26: Open Library's Spanish editions.
        let m = EditionTitle.untaggedMark
        for (current, entries, want) in [
            ("CAMINO DE LOS REYES (EL ARCHIVO DE LAS TORMENTAS 1)",
             ["CAMINO DE LOS REYES (EL ARCHIVO DE LAS TORMENTAS 1)", m + "The Way of Kings (1 of 5)",
              m + "La via dei re. Le cronache della Folgoluce", m + "El camino de los reyes", m + "The Way of Kings"],
             "El camino de los reyes"),
            ("Juramentada / Oathbringer",
             ["Juramentada / Oathbringer", m + "Oathbringer 2. Cilt", m + "Oathbringer"], "Juramentada"),
            ("Oathbringer", ["Juramentada / Oathbringer", m + "Oathbringer"], "Juramentada"),
        ] {
            let got = EditionTitle.languageTitle(current, among: entries)
            print(got == want ? "PASS" : "FAIL", "real \(current) -> \(got)")
            if got != want { failed = true }
        }
        let matches: [(String, String, Bool)] = [
            ("Camino de los reyes", "El camino de los reyes (El Archivo de las Tormentas 1)", true),
            ("El camino de los reyes", "El camino de los reyes (El Archivo de las Tormentas 1)", true),
            ("Camino de los reyes", "El camino de los reyes (Edición ilustrada 2)", false),
        ]
        for (expected, actual, want) in matches {
            let got = BookAutoMatch.sameEditionTitle(expected, actual)
            print(got == want ? "PASS" : "FAIL", "match \(expected) ~ \(actual) -> \(got)")
            if got != want { failed = true }
        }
        exit(failed ? 1 : 0)
    }
}
