import Foundation

@main
struct AutoMatchSmoke {
    static func main() {
        func candidate(_ id: Int, _ title: String, _ authors: String) -> BookAutoMatch.Candidate {
            .init(id: id, title: title, authors: authors)
        }

        assert(BookAutoMatch.isbn(in: "9780306406157") == "9780306406157")
        assert(BookAutoMatch.isbn(in: "urn:isbn:978-0-306-40615-7") == "9780306406157")
        assert(BookAutoMatch.isbn(in: "ISBN-13: 978-0-306-40615-7") == "9780306406157")
        assert(BookAutoMatch.isbn(in: "ISBN13: 9780306406157") == "9780306406157")
        assert(BookAutoMatch.isbn(in: "0306406152") == "0306406152")
        assert(BookAutoMatch.isbn(in: "9780306406158") == nil)
        assert(BookAutoMatch.isbn(in: "4780306406158") == nil)
        assert(BookAutoMatch.isbn(in: "X306406152") == nil)
        assert(BookAutoMatch.isbn(in: "urn:uuid:829a04a9-31ff-46c7-9e72-774623fa136c") == nil)

        assert(BookAutoMatch.sameTitle("L’Étranger", "L'Etranger"))
        assert(BookAutoMatch.sameAuthor("Backman,Fredrik", "Fredrik Backman"))
        assert(BookAutoMatch.sameAuthor("Philip Fracassi", "Philip Fracassi, Other Contributor"))
        assert(!BookAutoMatch.sameAuthor("Philip Fracassi", "Different Fracassi"))
        assert(!BookAutoMatch.sameEditionTitle("Dune", "Dune: La saga completa"))
        assert(!BookAutoMatch.sameEditionTitle("Don Quijote", "Don Quijote: Colección integral"))
        assert(BookAutoMatch.sameEditionTitle("Iron Gold", "Iron Gold: Book 4 of the Red Rising Saga"))
        assert(BookAutoMatch.sameEditionAuthor("Frank Herbert", "Herbert, Frank"))
        assert(!BookAutoMatch.sameEditionAuthor("Frank Herbert", "Brian Herbert, Frank Herbert, Kevin J. Anderson"))

        let verified = candidate(101, "The Third Rule of Time Travel", "Philip Fracassi")
        let differentAuthor = candidate(102, "The Third Rule of Time Travel", "Someone Else")
        let shortenedTitle = candidate(103, "The Third Rule", "Philip Fracassi")

        assert(BookAutoMatch.uniqueExact(title: verified.title, author: verified.authors,
                                         in: [shortenedTitle, differentAuthor, verified]) == 101)
        assert(BookAutoMatch.uniqueExact(title: verified.title, author: verified.authors,
                                         in: [verified, candidate(105, verified.title, verified.authors)]) == nil)
        assert(BookAutoMatch.uniqueExact(title: verified.title, author: verified.authors,
                                         in: [differentAuthor]) == nil)
        assert(BookAutoMatch.uniqueExact(title: verified.title, author: "",
                                         in: [verified]) == nil)
        assert(BookAutoMatch.uniqueExact(title: "A Little Life", author: verified.authors,
                                         in: [verified]) == nil)
        assert(BookAutoMatch.uniqueExact(title: verified.title, author: verified.authors,
                                         in: [verified, verified]) == 101)

        print("PASS: valid ISBN-10/13, UUID rejection, exact title/author matching, and ambiguous match rejection")
    }
}
