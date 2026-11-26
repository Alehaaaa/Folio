import Foundation
import Security

// Folio's take on ShelfSync (github.com/Lyfts/ShelfSync): the same reading
// services, linked side by side, each kept in step with the library's status
// and reading progress. Hardcover keeps its own client (Hardcover.swift);
// these are the other services ShelfSync supports.

enum ShelfService: String, CaseIterable, Identifiable, Codable {
    case storygraph, goodreads, fable, pagebound, librarything

    var id: String { rawValue }

    var name: String {
        switch self {
        case .storygraph: "StoryGraph"
        case .goodreads: "Goodreads"
        case .fable: "Fable"
        case .pagebound: "Pagebound"
        case .librarything: "LibraryThing"
        }
    }

    var symbol: String {
        switch self {
        case .storygraph: "chart.bar.doc.horizontal"
        case .goodreads: "g.circle"
        case .fable: "text.bubble"
        case .pagebound: "book.pages"
        case .librarything: "building.columns"
        }
    }

    enum SignIn { case web, email, username }

    var signIn: SignIn {
        switch self {
        case .storygraph, .goodreads: .web
        case .fable, .pagebound: .email
        case .librarything: .username
        }
    }

    /// LibraryThing has no reading progress, only collections.
    var sendsProgress: Bool { self != .librarything }

    func supports(_ status: HCStatus) -> Bool {
        switch self {
        case .storygraph, .goodreads, .pagebound: true
        case .fable: status != .paused
        case .librarything: status != .paused && status != .dnf
        }
    }
}

struct ShelfError: LocalizedError {
    var message: String
    var signedOut = false
    var errorDescription: String? { message }

    static func signedOut(_ service: ShelfService) -> ShelfError {
        ShelfError(message: "\(service.name) signed you out. Sign in again.", signedOut: true)
    }
}

// MARK: - Accounts (kept in the keychain)

struct ShelfCookie: Codable, Hashable {
    var name: String
    var value: String
    var domain: String
    var path: String
    var expires: Double?
    var secure: Bool

    init(_ cookie: HTTPCookie) {
        name = cookie.name
        value = cookie.value
        domain = cookie.domain
        path = cookie.path
        expires = cookie.expiresDate?.timeIntervalSince1970
        secure = cookie.isSecure
    }

    init(name: String, value: String, domain: String) {
        self.name = name
        self.value = value
        self.domain = domain
        path = "/"
        expires = Date().addingTimeInterval(365 * 24 * 3600).timeIntervalSince1970
        secure = true
    }

    var cookie: HTTPCookie? {
        var props: [HTTPCookiePropertyKey: Any] = [
            .name: name, .value: value, .domain: domain, .path: path.isEmpty ? "/" : path,
        ]
        if let expires { props[.expires] = Date(timeIntervalSince1970: expires) }
        if secure { props[.secure] = "TRUE" }
        return HTTPCookie(properties: props)
    }
}

struct ShelfAccount: Codable, Equatable {
    var name: String?
    var userID: String?
    var email: String?
    var password: String?
    var idToken: String?
    var refreshToken: String?
    var expiresAt: Double?
    var apiToken: String?
    var cookies: [ShelfCookie]?
    var userAgent: String?
}

enum ShelfKeychain {
    static let service = "Folio.ShelfSync"

    static func read(_ s: ShelfService) -> ShelfAccount? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: s.rawValue, kSecReturnData as String: true]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return try? JSONDecoder().decode(ShelfAccount.self, from: d)
    }

    static func write(_ account: ShelfAccount?, for s: ShelfService) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: s.rawValue]
        SecItemDelete(base as CFDictionary)
        guard let account, let data = try? JSONEncoder().encode(account) else { return }
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }
}

// MARK: - Links between library books and each service's books

struct ShelfLink: Codable, Equatable {
    /// The service's id for the book; nil when a search found nothing.
    var id: String?
    /// A second id some services need (Pagebound's book UUID, LibraryThing's copy).
    var extra: String?
    var title: String?
    var pages: Int?
    /// The last status and percentage the service accepted.
    var status: Int?
    var percent: Int?
    var checkedAt: Date = Date()
}

struct ShelfFound {
    var id: String
    var title: String
    var author: String
    var extra: String?
    var pages: Int?
}

// MARK: - HTTP

/// One URLSession per service, with its own cookie jar seeded from the account.
final class ShelfHTTP {
    let session: URLSession
    let jar: HTTPCookieStorage?

    init(cookies: [ShelfCookie] = []) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 90
        config.httpCookieAcceptPolicy = .always
        jar = config.httpCookieStorage
        for c in cookies { if let cookie = c.cookie { jar?.setCookie(cookie) } }
        session = URLSession(configuration: config)
    }

    func cookies(matching domain: String) -> [ShelfCookie] {
        (jar?.cookies ?? []).filter { $0.domain.hasSuffix(domain) }.map { ShelfCookie($0) }
    }

    struct Reply {
        var code: Int
        var data: Data
        var url: URL?
        var text: String { String(decoding: data, as: UTF8.self) }
        var json: JSON { (try? JSONDecoder().decode(JSON.self, from: data)) ?? .null }
        var ok: Bool { (200..<300).contains(code) }
    }

    static func form(_ fields: [(String, String)]) -> String {
        fields.map { "\(escape($0.0))=\(escape($0.1))" }.joined(separator: "&")
    }

    static func escape(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    func send(_ url: URL, method: String = "GET", headers: [String: String] = [:],
              form: [(String, String)]? = nil, json: Any? = nil, timeout: TimeInterval? = nil) async throws -> Reply {
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let timeout { request.timeoutInterval = timeout }
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        if let form {
            request.httpBody = Data(Self.form(form).utf8)
            if headers["Content-Type"] == nil {
                request.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
            }
        } else if let json {
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        let http = response as? HTTPURLResponse
        return Reply(code: http?.statusCode ?? 0, data: data, url: http?.url)
    }
}

// MARK: - Small HTML helpers (the cookie-based services are scraped like ShelfSync does)

enum ShelfHTML {
    static func first(_ pattern: String, in text: String, group: Int = 1) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators, .caseInsensitive]),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              m.numberOfRanges > group, let r = Range(m.range(at: group), in: text) else { return nil }
        return String(text[r])
    }

    static func all(_ pattern: String, in text: String) -> [[String]] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators, .caseInsensitive])
        else { return [] }
        return re.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { m in
            (0..<m.numberOfRanges).map { i in
                Range(m.range(at: i), in: text).map { String(text[$0]) } ?? ""
            }
        }
    }

    static func text(_ html: String?) -> String {
        guard var s = html else { return "" }
        s = s.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        s = decode(s)
        return s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func decode(_ s: String) -> String {
        var out = s
        let named = ["&amp;": "&", "&quot;": "\"", "&#39;": "'", "&apos;": "'", "&lt;": "<", "&gt;": ">", "&nbsp;": " "]
        for (k, v) in named { out = out.replacingOccurrences(of: k, with: v) }
        for m in all("&#(x?)([0-9a-fA-F]+);", in: out) {
            let value = m[1].isEmpty ? UInt32(m[2]) : UInt32(m[2], radix: 16)
            if let value, let scalar = Unicode.Scalar(value) {
                out = out.replacingOccurrences(of: m[0], with: String(Character(scalar)))
            }
        }
        return out
    }

    /// The Rails CSRF token in a page's meta tags.
    static func csrf(_ html: String) -> String? {
        let token = first(#"<meta[^>]*name=["']csrf-token["'][^>]*content=["']([^"']+)["']"#, in: html)
            ?? first(#"<meta[^>]*content=["']([^"']+)["'][^>]*name=["']csrf-token["']"#, in: html)
            ?? first(#"<input[^>]*name=["']authenticity_token["'][^>]*value=["']([^"']+)["']"#, in: html)
        return token.map(decode)
    }

    static func input(_ name: String, in html: String) -> String? {
        let n = NSRegularExpression.escapedPattern(for: name)
        return (first(#"<input[^>]*name=["']"# + n + #"["'][^>]*value=["']([^"']*)["']"#, in: html)
            ?? first(#"<input[^>]*value=["']([^"']*)["'][^>]*name=["']"# + n + #"["']"#, in: html)).map(decode)
    }
}

// MARK: - Providers

@MainActor
protocol ShelfProvider: AnyObject {
    var service: ShelfService { get }
    var account: ShelfAccount { get }
    func search(_ query: String, isbn: Bool) async throws -> [ShelfFound]
    func setStatus(_ status: HCStatus, link: inout ShelfLink) async throws
    func setProgress(percent: Int, link: inout ShelfLink) async throws
}

/// Shared Firebase email sign-in (Fable and Pagebound both use it).
enum ShelfFirebase {
    struct Session { var idToken: String; var refreshToken: String; var expiresAt: Double; var email: String? }

    static func signIn(http: ShelfHTTP, key: String, email: String, password: String, legacy: Bool) async throws -> Session {
        let url = legacy
            ? URL(string: "https://www.googleapis.com/identitytoolkit/v3/relyingparty/verifyPassword?key=\(key)")!
            : URL(string: "https://identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=\(key)")!
        var body: [String: Any] = ["email": email, "password": password, "returnSecureToken": true]
        if !legacy { body["clientType"] = "CLIENT_TYPE_WEB" }
        let r = try await http.send(url, method: "POST", json: body)
        let j = r.json
        guard r.code == 200, let id = j["idToken"].string, let refresh = j["refreshToken"].string else {
            let message = j["error"]["message"].string ?? "HTTP \(r.code)"
            throw ShelfError(message: friendly(message))
        }
        return Session(idToken: id, refreshToken: refresh,
                       expiresAt: Date().timeIntervalSince1970 + Double(j["expiresIn"].int ?? 3600),
                       email: j["email"].string)
    }

    static func refresh(http: ShelfHTTP, key: String, token: String) async throws -> Session? {
        let url = URL(string: "https://securetoken.googleapis.com/v1/token?key=\(key)")!
        let r = try await http.send(url, method: "POST", form: [("grant_type", "refresh_token"), ("refresh_token", token)])
        let j = r.json
        guard r.code == 200, let id = j["id_token"].string, let refresh = j["refresh_token"].string else { return nil }
        return Session(idToken: id, refreshToken: refresh,
                       expiresAt: Date().timeIntervalSince1970 + Double(j["expires_in"].int ?? 3600), email: nil)
    }

    static func friendly(_ code: String) -> String {
        if code.contains("INVALID_PASSWORD") || code.contains("INVALID_LOGIN_CREDENTIALS") || code.contains("EMAIL_NOT_FOUND") {
            return "That email and password didn't work."
        }
        if code.contains("TOO_MANY_ATTEMPTS") { return "Too many attempts. Try again later." }
        return code
    }
}

// MARK: Fable (official API, Firebase sign-in)

@MainActor
final class FableProvider: ShelfProvider {
    let service = ShelfService.fable
    private(set) var account: ShelfAccount
    private let http = ShelfHTTP()
    private let save: (ShelfAccount) -> Void
    private var listIDs: [String: String]?
    static let key = "AIzaSyDEnLDTjMQ9v-XaQ7pk6pJxKrpVbX_rr6U"
    private let base = "https://api.fable.co"

    init(account: ShelfAccount, save: @escaping (ShelfAccount) -> Void) {
        self.account = account
        self.save = save
    }

    static func signIn(email: String, password: String) async throws -> ShelfAccount {
        let http = ShelfHTTP()
        let s = try await ShelfFirebase.signIn(http: http, key: key, email: email, password: password, legacy: true)
        var account = ShelfAccount(name: s.email ?? email, email: email, password: password,
                                   idToken: s.idToken, refreshToken: s.refreshToken, expiresAt: s.expiresAt)
        var request = URLRequest(url: URL(string: "https://api.fable.co/api/settings/profile/")!)
        request.setValue("JWT \(s.idToken)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await http.session.data(for: request)
        let profile = (try? JSONDecoder().decode(JSON.self, from: data)) ?? .null
        guard let id = profile["id"].string else { throw ShelfError(message: "Fable didn't return your profile.") }
        account.userID = id
        if let name = profile["display_name"].string ?? profile["username"].string { account.name = name }
        return account
    }

    private func token() async throws -> String {
        let now = Date().timeIntervalSince1970
        if let t = account.idToken, (account.expiresAt ?? 0) - 60 > now { return t }
        if let r = account.refreshToken, let s = try await ShelfFirebase.refresh(http: http, key: Self.key, token: r) {
            account.idToken = s.idToken; account.refreshToken = s.refreshToken; account.expiresAt = s.expiresAt
            save(account)
            return s.idToken
        }
        guard let email = account.email, let password = account.password else { throw ShelfError.signedOut(service) }
        let s = try await ShelfFirebase.signIn(http: http, key: Self.key, email: email, password: password, legacy: true)
        account.idToken = s.idToken; account.refreshToken = s.refreshToken; account.expiresAt = s.expiresAt
        save(account)
        return s.idToken
    }

    private func call(_ path: String, method: String = "GET", body: Any? = nil) async throws -> ShelfHTTP.Reply {
        let t = try await token()
        let r = try await http.send(URL(string: base + path)!, method: method,
                                    headers: ["Authorization": "JWT \(t)", "Accept": "application/json"], json: body)
        if r.code == 401 || r.code == 403 {
            account.expiresAt = 0
            throw ShelfError.signedOut(service)
        }
        return r
    }

    func search(_ query: String, isbn: Bool) async throws -> [ShelfFound] {
        let q = ShelfHTTP.escape(query)
        let r = try await call("/api/books/search/?auto=\(q)&include=out_of_catalog&type=book&limit=20&offset=0")
        guard r.ok else { throw ShelfError(message: "Fable search failed (HTTP \(r.code)).") }
        return r.json["response"]["books"].array.compactMap { b in
            guard let id = b["id"].string else { return nil }
            let authors = b["authors"].array.compactMap { $0["name"].string }.joined(separator: ", ")
            return ShelfFound(id: id, title: b["title"].string ?? "", author: authors,
                              extra: b["isbn"].string ?? b["display_isbn"].string)
        }
    }

    private static let systemType: [HCStatus: String] = [
        .wantToRead: "want_to_read", .reading: "current_reading", .read: "finished", .dnf: "did_not_finish",
    ]

    private func lists() async throws -> [String: String] {
        if let listIDs { return listIDs }
        guard let user = account.userID else { throw ShelfError.signedOut(service) }
        let r = try await call("/api/v2/users/\(user)/book_lists?limit=20&offset=0&media_type=book")
        guard r.ok else { throw ShelfError(message: "Couldn't read your Fable lists (HTTP \(r.code)).") }
        var ids: [String: String] = [:]
        for l in r.json["results"].array where l["type"].string == "system" {
            if let t = l["system_type"].string, let id = l["id"].string { ids[t] = id }
        }
        listIDs = ids
        return ids
    }

    func setStatus(_ status: HCStatus, link: inout ShelfLink) async throws {
        guard let id = link.id, let target = Self.systemType[status], let user = account.userID else { return }
        let current = try await call("/api/books/\(id)")
        if current.json["response"]["status"].string == target { return }
        let ids = try await lists()
        guard let list = ids[target] else { throw ShelfError(message: "Fable's \(status.label) list is missing.") }
        let others = Self.systemType.values.filter { $0 != target }.compactMap { ids[$0] }
        let r = try await call("/api/v2/users/\(user)/book_lists/book", method: "POST", body: [
            "type": "multiselect", "book_id": id, "book_list_ids": [list], "exclude_from": others,
        ] as [String: Any])
        guard r.ok || r.code == 409 else { throw ShelfError(message: "Fable didn't take the status (HTTP \(r.code)).") }
    }

    func setProgress(percent: Int, link: inout ShelfLink) async throws {
        guard let id = link.id else { return }
        let r = try await call("/api/books/\(id)/reading_progress", method: "POST", body: [
            "status": "reading", "social_accounts": [String](),
            "current_percentage": percent, "selected_mode": "percentage",
        ] as [String: Any])
        guard r.code == 200 || r.code == 201 else { throw ShelfError(message: "Fable didn't take the progress (HTTP \(r.code)).") }
    }
}

// MARK: Pagebound (its website's API, Firebase sign-in)

@MainActor
final class PageboundProvider: ShelfProvider {
    let service = ShelfService.pagebound
    private(set) var account: ShelfAccount
    private let http = ShelfHTTP()
    private let save: (ShelfAccount) -> Void
    static let key = "AIzaSyDCfBJ51pRZgHueBfBz0KNDiPNev1ClnGg"
    static let api = "https://prod-pagebound-api.onrender.com"
    private let typesense = "https://hztadco4ku1vqi6lp.a1.typesense.net"
    private let typesenseKey = "SgSrp2Vx4V4wjJAwnME6uWUufNdi9BxM"

    init(account: ShelfAccount, save: @escaping (ShelfAccount) -> Void) {
        self.account = account
        self.save = save
    }

    /// Trades a Firebase session for Pagebound's own API token. Pagebound's
    /// server can take a minute to wake up, hence the long timeout.
    private static func exchange(http: ShelfHTTP, idToken: String) async throws -> (token: String, user: String?, email: String?) {
        let r = try await http.send(URL(string: api + "/api/v1/auth/firebase_auth")!, method: "POST",
                                    headers: ["Authorization": "Bearer null", "Accept": "application/json"],
                                    json: ["id_token": idToken], timeout: 80)
        let j = r.json
        guard r.code == 200, let token = j["token"].string else {
            throw ShelfError(message: j["error"]["message"].string ?? j["message"].string ?? "Pagebound sign-in failed (HTTP \(r.code)).")
        }
        return (token, j["user"]["id"].string, j["user"]["email"].string)
    }

    static func signIn(email: String, password: String) async throws -> ShelfAccount {
        let http = ShelfHTTP()
        let s = try await ShelfFirebase.signIn(http: http, key: key, email: email, password: password, legacy: false)
        let p = try await exchange(http: http, idToken: s.idToken)
        return ShelfAccount(name: p.email ?? s.email ?? email, userID: p.user, email: email, password: password,
                            idToken: s.idToken, refreshToken: s.refreshToken, expiresAt: s.expiresAt, apiToken: p.token)
    }

    private func renew() async throws {
        var session: ShelfFirebase.Session?
        if let r = account.refreshToken { session = try await ShelfFirebase.refresh(http: http, key: Self.key, token: r) }
        if session == nil, let email = account.email, let password = account.password {
            session = try await ShelfFirebase.signIn(http: http, key: Self.key, email: email, password: password, legacy: false)
        }
        guard let s = session else { throw ShelfError.signedOut(service) }
        let p = try await Self.exchange(http: http, idToken: s.idToken)
        account.idToken = s.idToken; account.refreshToken = s.refreshToken; account.expiresAt = s.expiresAt
        account.apiToken = p.token
        save(account)
    }

    private func call(_ path: String, method: String = "GET", body: Any? = nil, retried: Bool = false) async throws -> ShelfHTTP.Reply {
        if account.apiToken == nil || (account.expiresAt ?? 0) < Date().timeIntervalSince1970 + 60 { try await renew() }
        let r = try await http.send(URL(string: Self.api + path)!, method: method, headers: [
            "Authorization": "Bearer \(account.apiToken ?? "")", "Accept": "application/json, text/plain, */*",
        ], json: body, timeout: 60)
        if r.code == 401 || r.code == 403 {
            if retried { throw ShelfError.signedOut(service) }
            account.apiToken = nil
            return try await call(path, method: method, body: body, retried: true)
        }
        return r
    }

    func search(_ query: String, isbn: Bool) async throws -> [ShelfFound] {
        // Pagebound's catalogue search covers titles and authors, not ISBNs.
        guard !isbn else { return [] }
        let q = ShelfHTTP.escape(query)
        let url = URL(string: "\(typesense)/collections/books/documents/search?q=\(q)&query_by=title%2Cauthor_name&limit=6&num_typos=2&split_join_tokens=always&typo_tokens_threshold=6")!
        let r = try await http.send(url, headers: ["X-TYPESENSE-API-KEY": typesenseKey, "Accept": "application/json"])
        guard r.ok else { throw ShelfError(message: "Pagebound search failed (HTTP \(r.code)).") }
        return r.json["hits"].array.compactMap { hit in
            let d = hit["document"]
            guard let id = d["id"].string else { return nil }
            return ShelfFound(id: id, title: d["title"].string ?? "", author: d["author_name"].string ?? d["author"].string ?? "",
                              extra: d["uuid"].string, pages: d["page_count"].int)
        }
    }

    private func book(_ link: ShelfLink) async throws -> JSON {
        guard let uuid = link.extra else { throw ShelfError(message: "Relink this book on Pagebound.") }
        let r = try await call("/api/v1/books/\(ShelfHTTP.escape(uuid))")
        guard r.code == 200 else { throw ShelfError(message: "Couldn't read the book on Pagebound (HTTP \(r.code)).") }
        return r.json["book"]
    }

    private static let systemStatus: [HCStatus: String] = [
        .wantToRead: "interested", .reading: "current", .read: "finished", .paused: "paused", .dnf: "dnf",
    ]

    private static func today() -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        return "\(c.month ?? 1)/\(c.day ?? 1)/\(c.year ?? 2026)"
    }

    private static func formDate(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        let parts = value.prefix(10).split(separator: "-")
        if parts.count == 3, let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]) { return "\(m)/\(d)/\(y)" }
        return value
    }

    func setStatus(_ status: HCStatus, link: inout ShelfLink) async throws {
        guard let id = link.id, let target = Self.systemStatus[status] else { return }
        let b = try await book(link)
        let ub = b["user_book"]
        if ub["status"].string == target { return }
        let today = Self.today()
        let reading = ub["current_reading_instance"]
        var started = Self.formDate(reading["started_reading_at_date"].string ?? reading["started_reading_at"].string ?? ub["started_reading_at"].string)
        var finished = Self.formDate(reading["finished_reading_at_date"].string ?? reading["finished_reading_at"].string ?? ub["finished_reading_at"].string)
        if started == nil || (status == .reading && ub["status"].string == "finished") { started = today }
        if status == .read || finished == nil { finished = today }
        let shelves: [Any] = ub["shelves"].array.map { s in (s["id"].isNull ? s : s["id"]).anyValue }
        var userBook: [String: Any] = ["owned": ub["owned"] == .bool(true), "muted": ub["muted"] == .bool(true)]
        var payload: [String: Any] = [
            "shelf_ids": shelves, "date": ub["date_added"].string ?? today,
            "started_reading_at": started ?? "", "finished_reading_at": finished ?? "",
            "challenge_year": ub["challenge_year"].isNull ? (NSNull() as Any) : ub["challenge_year"].anyValue,
            "format": ub["format"].string ?? "print", "tracking_mode": ub["tracking_mode"].string ?? "pages",
            "total_page_count": "",
        ]
        let r: ShelfHTTP.Reply
        if let uuid = ub["uuid"].string ?? ub["id"].string, !ub.isNull {
            payload["status"] = target
            payload["total_minutes"] = ub["total_minutes"].int ?? 0
            payload["user_book"] = userBook
            r = try await call("/api/v1/user_books/\(ShelfHTTP.escape(uuid))", method: "PUT", body: payload)
        } else {
            userBook["book_id"] = Int(id) ?? id
            userBook["status"] = target
            payload["user_book"] = userBook
            payload["total_minutes"] = NSNull()
            r = try await call("/api/v1/user_books", method: "POST", body: payload)
        }
        guard r.ok else { throw ShelfError(message: "Pagebound didn't take the status (HTTP \(r.code)).") }
    }

    func setProgress(percent: Int, link: inout ShelfLink) async throws {
        var b = try await book(link)
        var reading = b["user_book"]["current_reading_instance"]
        if reading["id"].isNull {
            try await setStatus(.reading, link: &link)
            link.status = HCStatus.reading.rawValue
            b = try await book(link)
            reading = b["user_book"]["current_reading_instance"]
        }
        let ub = b["user_book"]
        guard let readID = reading["id"].int,
              let userBookID = reading["user_book_id"].int ?? ub["id"].int else {
            throw ShelfError(message: "Pagebound has no reading session for this book.")
        }
        let total = ub["total_page_count"].int ?? reading["total_page_count"].int ?? b["page_count"].int ?? link.pages
        let page = total.map { Int((Double(percent) / 100 * Double($0)).rounded()) }
        let r = try await call("/api/v1/reading_updates", method: "POST", body: [
            "reading_update": [
                "user_book_id": userBookID, "date": Self.today(), "reading_instance_id": readID,
                "total_progress": percent, "total_pages_read": page.map { String($0) as Any } ?? (NSNull() as Any),
            ] as [String: Any],
            "user_book": [
                "current_page": page.map { String($0) as Any } ?? (NSNull() as Any),
                "total_page_count": total.map { $0 as Any } ?? (NSNull() as Any),
                "current_minute": NSNull(), "total_minutes": NSNull(),
            ] as [String: Any],
            "no_broadcast": false, "progress_method": "percent",
        ] as [String: Any])
        guard r.code == 200 || r.code == 201 else { throw ShelfError(message: "Pagebound didn't take the progress (HTTP \(r.code)).") }
    }
}

// MARK: StoryGraph (website, signed in through a web view)

@MainActor
final class StoryGraphProvider: ShelfProvider {
    let service = ShelfService.storygraph
    private(set) var account: ShelfAccount
    private let http: ShelfHTTP
    private let save: (ShelfAccount) -> Void
    private let base = "https://app.thestorygraph.com"

    init(account: ShelfAccount, save: @escaping (ShelfAccount) -> Void) {
        self.account = account
        self.save = save
        http = ShelfHTTP(cookies: account.cookies ?? [])
    }

    private var agent: String { account.userAgent ?? ShelfWeb.fallbackAgent }

    private func get(_ path: String) async throws -> ShelfHTTP.Reply {
        let r = try await http.send(URL(string: base + path)!, headers: ["User-Agent": agent, "Accept": "text/html,application/xhtml+xml"])
        try check(r)
        return r
    }

    private func check(_ r: ShelfHTTP.Reply) throws {
        if r.code == 401 || (r.url?.path.hasPrefix("/users/sign_in") ?? false) { throw ShelfError.signedOut(service) }
        if r.code == 403 { throw ShelfError(message: "StoryGraph blocked the request. Try again later, or sign in again.") }
        persist()
    }

    private func persist() {
        let fresh = http.cookies(matching: "thestorygraph.com")
        guard !fresh.isEmpty, Set(fresh) != Set(account.cookies ?? []) else { return }
        account.cookies = fresh
        save(account)
    }

    func search(_ query: String, isbn: Bool) async throws -> [ShelfFound] {
        let r = try await get("/browse?search_term=\(ShelfHTTP.escape(query))")
        guard r.code == 200 else { throw ShelfError(message: "StoryGraph search failed (HTTP \(r.code)).") }
        let html = r.text
        var found: [ShelfFound] = []
        var seen = Set<String>()
        for chunk in html.components(separatedBy: "book-title-author-and-series").dropFirst() {
            let block = String(chunk.prefix(4000))
            guard let id = ShelfHTML.first(#"href="/books/([^"/?#]+)""#, in: block), seen.insert(id).inserted else { continue }
            let title = ShelfHTML.text(ShelfHTML.first(#"href="/books/[^"]+"[^>]*>(.*?)</a>"#, in: block))
            let author = ShelfHTML.text(ShelfHTML.first(#"href="/authors/[^"]+"[^>]*>(.*?)</a>"#, in: block))
            let pages = ShelfHTML.first(#"(\d+)\s+pages"#, in: block).flatMap(Int.init)
            if ShelfHTML.first(#"Format:\s*</span>\s*([^<]*)"#, in: block)?.lowercased().contains("audio") == true { continue }
            found.append(ShelfFound(id: id, title: title, author: author, pages: pages))
        }
        return found
    }

    private func form(_ path: String, bookID: String, fields: [(String, String)]) async throws -> ShelfHTTP.Reply {
        let page = try await get("/books/\(bookID)")
        guard let csrf = ShelfHTML.csrf(page.text) else { throw ShelfError.signedOut(service) }
        let r = try await http.send(URL(string: base + path)!, method: "POST", headers: [
            "User-Agent": agent, "X-CSRF-Token": csrf, "X-Requested-With": "XMLHttpRequest",
            "Accept": "text/javascript, application/javascript, */*; q=0.01",
            "Referer": base + "/books/\(bookID)", "Origin": base,
        ], form: fields + [("authenticity_token", csrf)])
        try check(r)
        return r
    }

    private static let statusName: [HCStatus: String] = [
        .wantToRead: "to-read", .reading: "currently-reading", .read: "read", .paused: "paused", .dnf: "did-not-finish",
    ]

    func setStatus(_ status: HCStatus, link: inout ShelfLink) async throws {
        guard let id = link.id, let name = Self.statusName[status] else { return }
        var r = try await form("/update-status.js?book_id=\(id)&status=\(name)", bookID: id, fields: [])
        if status == .reading && r.code == 422 {
            r = try await form("/update-status.js?book_id=\(id)&status=rereading", bookID: id, fields: [])
        }
        guard r.ok else { throw ShelfError(message: "StoryGraph didn't take the status (HTTP \(r.code)).") }
    }

    func setProgress(percent: Int, link: inout ShelfLink) async throws {
        guard let id = link.id else { return }
        let page = try await get("/books/\(id)")
        let html = page.text
        guard let csrf = ShelfHTML.csrf(html) else { throw ShelfError.signedOut(service) }
        let pages = ShelfHTML.input("read_status[book_num_of_pages]", in: html) ?? String(link.pages ?? 0)
        let r = try await http.send(URL(string: base + "/update-progress")!, method: "POST", headers: [
            "User-Agent": agent, "X-CSRF-Token": csrf, "X-Requested-With": "XMLHttpRequest",
            "Accept": "text/javascript, application/javascript, */*; q=0.01",
            "Referer": base + "/books/\(id)", "Origin": base,
        ], form: [
            ("read_status[progress_number]", String(percent)), ("read_status[progress_type]", "percentage"),
            ("read_status[book_num_of_pages]", pages), ("book_id", id), ("on_book_page", "true"),
            ("authenticity_token", csrf),
        ])
        try check(r)
        guard r.ok else { throw ShelfError(message: "StoryGraph didn't take the progress (HTTP \(r.code)).") }
    }
}

// MARK: Goodreads (website, signed in through a web view)

@MainActor
final class GoodreadsShelfProvider: ShelfProvider {
    let service = ShelfService.goodreads
    private(set) var account: ShelfAccount
    private let http: ShelfHTTP
    private let save: (ShelfAccount) -> Void
    private let base = "https://www.goodreads.com"
    private var csrf: String?

    init(account: ShelfAccount, save: @escaping (ShelfAccount) -> Void) {
        self.account = account
        self.save = save
        http = ShelfHTTP(cookies: account.cookies ?? [])
    }

    private var agent: String { account.userAgent ?? ShelfWeb.fallbackAgent }

    private func check(_ r: ShelfHTTP.Reply) throws {
        let path = r.url?.path ?? ""
        if r.code == 401 || path.contains("/user/sign_in") || path.hasPrefix("/ap/") { throw ShelfError.signedOut(service) }
        if r.code == 202 || r.code == 405 { throw ShelfError(message: "Goodreads asked for a browser check. Sign in again to refresh it.") }
        let fresh = http.cookies(matching: "goodreads.com")
        if !fresh.isEmpty, Set(fresh) != Set(account.cookies ?? []) {
            account.cookies = fresh
            save(account)
        }
    }

    private func get(_ path: String) async throws -> ShelfHTTP.Reply {
        let r = try await http.send(URL(string: base + path)!, headers: ["User-Agent": agent, "Accept": "text/html,application/xhtml+xml"])
        try check(r)
        return r
    }

    private func token() async throws -> String {
        if let csrf { return csrf }
        let r = try await get("/")
        guard let t = ShelfHTML.csrf(r.text) else { throw ShelfError.signedOut(service) }
        csrf = t
        return t
    }

    func search(_ query: String, isbn: Bool) async throws -> [ShelfFound] {
        let r = try await get("/search?q=\(ShelfHTTP.escape(query))")
        guard r.code == 200 else { throw ShelfError(message: "Goodreads search failed (HTTP \(r.code)).") }
        let html = r.text
        // A single match (an ISBN, say) goes straight to the book's page.
        if let id = r.url?.path.split(separator: "/").last.flatMap({ ShelfHTML.first(#"^(\d+)"#, in: String($0)) }),
           r.url?.path.hasPrefix("/book/show/") == true {
            let title = ShelfHTML.first(#""name"\s*:\s*"([^"]+)""#, in: html) ?? ShelfHTML.text(ShelfHTML.first(#"<title>(.*?)</title>"#, in: html))
            let author = ShelfHTML.first(#""author"\s*:\s*\[\s*\{[^}]*"name"\s*:\s*"([^"]+)""#, in: html) ?? ""
            return [ShelfFound(id: id, title: ShelfHTML.decode(title), author: ShelfHTML.decode(author))]
        }
        var found: [ShelfFound] = []
        var seen = Set<String>()
        // Current (Next.js) results.
        for m in ShelfHTML.all(#"data-testid="book-item-title"><a href="/book/show/(\d+)[^"]*">(.*?)</a>(.{0,600})"#, in: html) {
            guard seen.insert(m[1]).inserted else { continue }
            let author = ShelfHTML.first(#"data-testid="name">([^<]+)</span>"#, in: m[3]) ?? ""
            found.append(ShelfFound(id: m[1], title: ShelfHTML.text(m[2]), author: ShelfHTML.decode(author)))
        }
        // Classic results table.
        for m in ShelfHTML.all(#"class="bookTitle"[^>]*href="/book/show/(\d+)[^"]*"[^>]*>(.*?)</a>(.{0,1200})"#, in: html) {
            guard seen.insert(m[1]).inserted else { continue }
            let author = ShelfHTML.first(#"class="authorName"[^>]*>\s*<span[^>]*>([^<]+)</span>"#, in: m[3]) ?? ""
            found.append(ShelfFound(id: m[1], title: ShelfHTML.text(m[2]), author: ShelfHTML.decode(author)))
        }
        return found
    }

    private func post(_ path: String, fields: [(String, String)]) async throws -> ShelfHTTP.Reply {
        let send: (String) async throws -> ShelfHTTP.Reply = { [self] t in
            try await http.send(URL(string: base + path)!, method: "POST", headers: [
                "User-Agent": agent, "X-CSRF-Token": t, "X-Requested-With": "XMLHttpRequest",
                "X-Prototype-Version": "1.7", "Accept": "text/javascript, text/html, application/xml, text/xml, */*",
                "Referer": base + "/", "Origin": base,
            ], form: fields)
        }
        var r = try await send(try await token())
        if r.code == 403 || r.code == 422 {
            csrf = nil
            r = try await send(try await token())
        }
        try check(r)
        return r
    }

    private static let shelf: [HCStatus: String] = [
        .wantToRead: "to-read", .reading: "currently-reading", .read: "read", .paused: "paused", .dnf: "did-not-finish",
    ]

    func setStatus(_ status: HCStatus, link: inout ShelfLink) async throws {
        guard let id = link.id, let name = Self.shelf[status] else { return }
        let r = try await post("/shelf/add_to_shelf", fields: [("book_id", id), ("name", name), ("a", "")])
        guard r.ok else { throw ShelfError(message: "Goodreads didn't take the shelf (HTTP \(r.code)).") }
    }

    /// Takes the book off every Goodreads shelf.
    func remove(bookID id: String, shelf: String) async throws {
        let r = try await post("/shelf/add_to_shelf", fields: [("book_id", id), ("name", shelf), ("a", "remove")])
        if r.ok { return }
        let d = try await post("/review/destroy/\(id)", fields: [("_method", "delete")])
        guard d.ok else { throw ShelfError(message: "Goodreads didn't remove the book (HTTP \(d.code)).") }
    }

    func setProgress(percent: Int, link: inout ShelfLink) async throws {
        guard let id = link.id else { return }
        let r = try await post("/user_status.json", fields: [
            ("user_status[book_id]", id), ("user_status[percent]", String(percent)), ("user_status[body]", ""),
        ])
        guard r.ok else { throw ShelfError(message: "Goodreads didn't take the progress (HTTP \(r.code)).") }
    }
}

// MARK: LibraryThing (website requests, signed in with the app's sign-in)

@MainActor
final class LibraryThingProvider: ShelfProvider {
    let service = ShelfService.librarything
    private(set) var account: ShelfAccount
    private let http: ShelfHTTP
    private let save: (ShelfAccount) -> Void
    private let base = "https://www.librarything.com"
    private let agent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

    // Every account's default collections.
    private enum LTCollection { static let library = 1, toRead = 3, readUnowned = 5, reading = 7 }

    init(account: ShelfAccount, save: @escaping (ShelfAccount) -> Void) {
        self.account = account
        self.save = save
        http = ShelfHTTP(cookies: account.cookies ?? [])
    }

    static func signIn(username: String, password: String) async throws -> ShelfAccount {
        let http = ShelfHTTP()
        let query = ShelfHTTP.form([
            ("v", "2"), ("app_token", "687aa7458d1ae63c50e1e32887e4d40b"),
            ("auth_username", username), ("auth_password", password),
            ("direct_signin", "e038a6205d72c98c68e0afa670d0199c"),
        ])
        let r = try await http.send(URL(string: "https://api4.librarything.com/app_authorize.php?\(query)")!, headers: [
            "Accept": "application/json",
            "User-Agent": "Dalvik/2.1.0 (Linux; U; Android 16; 23090RA98G Build/BP2A.250605.031.A3)",
        ])
        let d = r.json["data"]
        guard r.code == 200, let id = d["cookie_userid"].string, let num = d["cookie_usernum"].string,
              let sum = d["cookie_userchecksum"].string else {
            throw ShelfError(message: r.code == 200 ? "That username and password didn't work." : "LibraryThing sign-in failed (HTTP \(r.code)).")
        }
        let domain = ".librarything.com"
        return ShelfAccount(name: id, userID: num, password: password, cookies: [
            ShelfCookie(name: "cookie_userid", value: id, domain: domain),
            ShelfCookie(name: "cookie_usernum", value: num, domain: domain),
            ShelfCookie(name: "cookie_userchecksum", value: sum, domain: domain),
        ])
    }

    private func request(_ path: String, form: [(String, String)]? = nil, method: String? = nil) async throws -> ShelfHTTP.Reply {
        let r = try await http.send(URL(string: base + path)!, method: method ?? (form == nil ? "GET" : "POST"), headers: [
            "User-Agent": agent, "Accept": "*/*", "X-Requested-With": "XMLHttpRequest", "Accept-Language": "en",
        ], form: form)
        if r.code == 403 { throw ShelfError(message: "LibraryThing's browser check blocked the request. Try again later.") }
        if r.code == 401 || r.url?.path.contains("signup") == true || r.text.range(of: #"LibraryThing\.is_signed_in\s*=\s*0"#, options: .regularExpression) != nil {
            throw ShelfError.signedOut(service)
        }
        let fresh = http.cookies(matching: "librarything.com")
        if !fresh.isEmpty, Set(fresh) != Set(account.cookies ?? []) {
            account.cookies = fresh
            save(account)
        }
        return r
    }

    func search(_ query: String, isbn: Bool) async throws -> [ShelfFound] {
        let path = "/ajax_newsearch.php?search=\(ShelfHTTP.escape(query))&searchtype=newwork_titles&page=1&sortchoice=0&optionidpotential=0&optionidreal=0"
        var html = ""
        // The first search only sets the site's session cookie.
        for _ in 0..<2 {
            let r = try await request(path, method: "POST")
            guard r.code == 200 else { throw ShelfError(message: "LibraryThing search failed (HTTP \(r.code)).") }
            if let encoded = r.json["text"].string, let data = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters) {
                html = String(decoding: data, as: UTF8.self)
            }
            if !html.isEmpty, !html.contains("If this error persists") { break }
        }
        var found: [ShelfFound] = []
        var seen = Set<String>()
        for row in ShelfHTML.all(#"<tr[^>]*>(.*?)</tr>"#, in: html) {
            guard let work = ShelfHTML.first(#"data-workid="(\d+)""#, in: row[1]), seen.insert(work).inserted,
                  let item = ShelfHTML.first(#"<p class="item">(.*?)</p>"#, in: row[1]) else { continue }
            let title = ShelfHTML.text(ShelfHTML.first(#"<a[^>]*data-workid="\d+"[^>]*>(.*?)</a>"#, in: item))
            let author = ShelfHTML.text(ShelfHTML.first(#"<a[^>]*href="/a/[^"]*"[^>]*>(.*?)</a>"#, in: item))
            if !title.isEmpty { found.append(ShelfFound(id: work, title: title, author: author)) }
        }
        return found
    }

    private func copy(in text: String, work: String) -> String? {
        ShelfHTML.all(#"/work/(\d+)/book/(\d+)"#, in: text).first { $0[1] == work }?[2]
    }

    /// The account's own copy of the work, found by searching its catalogue.
    private func findCopy(work: String, title: String?) async throws -> String? {
        guard let user = account.name, let title, !title.isEmpty else { return nil }
        let r = try await request("/catalog_bottom.php?view=\(ShelfHTTP.escape(user))&collection=-1&deepsearch=\(ShelfHTTP.escape(title))")
        return r.code == 200 ? copy(in: r.text, work: work) : nil
    }

    /// Adds the work through the site's "express add", in the given collections.
    private func add(work: String, collections: [Int]) async throws -> String {
        let open = try await request("/ajax_lb_addbooks_express_open.php", form: [
            ("workcode", work), ("forceLT2", "1"), ("is_lightbox_request", "1"), ("is_ajax", "1"),
        ])
        guard let key = ShelfHTML.input("memcache_key", in: open.text), !key.isEmpty else {
            throw ShelfError(message: "LibraryThing's add form couldn't be read.")
        }
        let best = try await request("/ajax_addbooks_express_show_bestwork.php?memcache_key=\(ShelfHTTP.escape(key))&workcode=\(work)&show_media_source=0", form: [
            ("fancy_type[#abx_data_info]", "full"), ("forceLT2", "1"), ("is_ajax", "1"),
        ])
        let edition = best.text.replacingOccurrences(of: "\\/", with: "/").replacingOccurrences(of: "\\\"", with: "\"")
        let field = { (name: String) in ShelfHTML.input(name, in: edition) ?? "" }
        let query = ShelfHTTP.form([
            ("tags", ""), ("rating", "0"), ("collection", collections.map(String.init).joined(separator: ",")),
            ("record_id", field("record_id")), ("source_type", field("source_type")), ("source_id", field("source_id")),
            ("workcode", work), ("isbn", field("isbn")), ("idealbook", field("idealbook")),
        ])
        let added = try await request("/action_addbooks_express_add_book.php?\(query)", form: [("forceLT2", "1"), ("is_ajax", "1")])
        guard added.code == 200, ShelfHTML.text(added.text).hasPrefix("Added") else {
            throw ShelfError(message: "LibraryThing couldn't add the book to your library.")
        }
        let recent = try await request("/response_list_lt2.php", form: [("fragment", "1"), ("limit", "5"), ("forceLT2", "1"), ("is_ajax", "1")])
        guard let copy = copy(in: recent.text, work: work) else {
            throw ShelfError(message: "The book was added, but LibraryThing didn't list it yet.")
        }
        return copy
    }

    private func toggle(copy: String, collection: Int, add: Bool) async throws {
        let r = try await request("/ajax_collectionsToggleBook.php", form: [
            ("bookid", copy), ("c_id", String(collection)), ("addRemove", add ? "1" : "0"), ("returnUI", "1"),
            ("containerID", "collections\(copy)"), ("excludeContainer", "1"), ("is_catalogB", "0"),
        ])
        guard r.code == 200 else { throw ShelfError(message: "LibraryThing didn't update the collection (HTTP \(r.code)).") }
    }

    func setStatus(_ status: HCStatus, link: inout ShelfLink) async throws {
        guard let work = link.id else { return }
        let target: Int
        switch status {
        case .wantToRead: target = LTCollection.toRead
        case .reading: target = LTCollection.reading
        case .read: target = LTCollection.library
        default: return
        }
        if link.extra == nil { link.extra = try await findCopy(work: work, title: link.title) }
        guard let copy = link.extra else {
            link.extra = try await add(work: work, collections: status == .wantToRead ? [target] : [LTCollection.library, target].uniqued())
            return
        }
        // Add first: LibraryThing won't take a copy out of its last collection.
        try await toggle(copy: copy, collection: target, add: true)
        for other in [LTCollection.reading, LTCollection.toRead] where other != target {
            try? await toggle(copy: copy, collection: other, add: false)
        }
    }

    func setProgress(percent: Int, link: inout ShelfLink) async throws {}
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] { var seen = Set<Element>(); return filter { seen.insert($0).inserted } }
}

enum ShelfWeb {
    static let fallbackAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
}
