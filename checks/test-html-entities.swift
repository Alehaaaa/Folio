// swiftc -swift-version 5 app/Sources/Folio/WebText.swift checks/test-html-entities.swift -o /tmp/t && /tmp/t
import Foundation

@main struct HTMLEntitiesCheck {
    static func main() {
        let cases: [(String, String)] = [
            ("J.K. Rowling, Adolfo Mu&amp;ntilde;oz Garc&amp;iacute;a, Alicia Dellepiane, Nieves Mart&amp;iacute;n Azofra",
             "J.K. Rowling, Adolfo Muñoz García, Alicia Dellepiane, Nieves Martín Azofra"),
            ("Adolfo Mu&ntilde;oz Garc&iacute;a", "Adolfo Muñoz García"),
            ("El se&#241;or de los anillos", "El señor de los anillos"),
            ("El se&#xF1;or &#X26; c&iacute;a", "El señor & cía"),
            ("Tom &amp;amp; Jerry", "Tom & Jerry"),
            ("&laquo;Cien a&ntilde;os&raquo; &mdash; Garc&iacute;a M&aacute;rquez", "«Cien años» — García Márquez"),
            ("It&apos;s &quot;fine&quot;", "It's \"fine\""),
            ("Salt & Pepper", "Salt & Pepper"),
            ("A &unknown; entity & a lone ampersand;", "A &unknown; entity & a lone ampersand;"),
            ("R&D", "R&D"),
            ("", ""),
        ]
        var failed = false
        for (input, want) in cases {
            let got = input.decodingHTMLEntities
            print(got == want ? "PASS" : "FAIL", got)
            if got != want { failed = true; print("     wanted:", want) }
        }
        // Pages decode with the character set they declare, not always UTF-8.
        let latin1 = "Adolfo Muñoz García".data(using: .isoLatin1)!
        let pages: [(String, Data, String?, String)] = [
            ("header ISO-8859-1", latin1, "text/html; charset=ISO-8859-1", "Adolfo Muñoz García"),
            ("meta windows-1252", Data("<meta charset=\"windows-1252\">".utf8) + latin1, "text/html", "<meta charset=\"windows-1252\">Adolfo Muñoz García"),
            ("undeclared UTF-8", Data("Adolfo Muñoz García".utf8), nil, "Adolfo Muñoz García"),
            ("undeclared Latin-1", latin1, "text/html", "Adolfo Muñoz García"),
            ("header UTF-8", Data("Martín".utf8), "application/json; charset=utf-8", "Martín"),
        ]
        for (name, data, contentType, want) in pages {
            let got = FolioWebText.string(from: data, contentType: contentType)
            print(got == want ? "PASS" : "FAIL", "\(name): \(got)")
            if got != want { failed = true }
        }
        exit(failed ? 1 : 0)
    }
}
