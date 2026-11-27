// swiftc -swift-version 5 app/Core/BookAutoMatch.swift app/Core/EditionTitle.swift app/Core/LibraryMatch.swift checks/test-library-match.swift -o /tmp/t && /tmp/t
import Foundation

@main struct LibraryMatchCheck {
    static func main() {
        // (catalogue titles, catalogue author, library title, library author, same book)
        let cases: [([String], String, String, String, Bool)] = [
            (["Balada de Pájaros Cantores y Serpientes"], "Suzanne Collins",
             "Balada de pájaros cantores y serpientes (Los Juegos del Hambre)", "Collins, Suzanne", true),
            (["The Ballad of Songbirds and Snakes", "Balada de pájaros cantores y serpientes"], "Suzanne Collins",
             "Balada de pájaros cantores y serpientes", "Suzanne Collins", true),
            (["Balada de pájaros cantores y serpientes"], "Suzzane collins",
             "Balada de pájaros cantores y serpientes: Una novela de Los Juegos del Hambre", "Suzanne Collins", true),
            (["Juramentada / Oathbringer"], "Brandon Sanderson", "Juramentada", "Brandon Sanderson", true),
            (["El camino de los reyes"], "Brandon Sanderson",
             "Camino de los reyes (El Archivo de las Tormentas 1)", "Sanderson, Brandon", true),
            (["The Way of Kings"], "Brandon Sanderson", "01 - The Way of Kings", "Brandon Sanderson", true),
            (["Dune"], "Frank Herbert", "Dune: Edición ilustrada", "Frank Herbert", true),
            (["Mistborn: The Final Empire"], "Brandon Sanderson", "Mistborn: Secret History", "Brandon Sanderson", false),
            (["Dune Messiah"], "Frank Herbert", "Dune", "Frank Herbert", false),
            (["Balada de pájaros cantores y serpientes"], "Suzanne Collins",
             "Balada de pájaros cantores y serpientes", "Pedro García", false),
            (["Sunrise on the Reaping"], "Suzanne Collins", "Amanecer en la cosecha", "Suzanne Collins", false),
            (["Amanecer en la cosecha"], "Suzanne Collins", "Amanecer en la cosecha", "", true),
        ]
        var failed = false
        for (titles, author, file, fileAuthor, want) in cases {
            let got = LibraryMatch.same(titles: titles, author: author, as: [file], by: fileAuthor)
            let index = LibraryMatch.Index([(title: "Otro libro", author: "Nadie Nunca"), (title: file, author: fileAuthor)])
            let indexed = index.matches(titles: titles, author: author) == [1]
            let ok = got == want && indexed == want
            print(ok ? "PASS" : "FAIL", "\(titles) by \(author) ~ \(file) by \(fileAuthor) -> \(got)/\(indexed)")
            if !ok { failed = true }
        }
        exit(failed ? 1 : 0)
    }
}
