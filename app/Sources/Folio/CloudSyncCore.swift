import Foundation
import CryptoKit

// Folio Sync: keeps reading progress and library state in step between the
// Mac and iPhone apps through a free public text store over plain HTTPS
// (textdb.dev). No account, key or server of our own: devices that share a
// sync code share one document, where each device keeps its own entry. The
// sync code picks the document and is the encryption key, so the store only
// ever sees ciphertext. Every book entry carries the time it last changed,
// and the newest wins.

// MARK: - Wire format

struct CloudSyncRecord: Codable, Equatable {
    /// Ways to recognise the same book on another device, best first:
    /// "hc:<Hardcover id>", "isbn:<isbn>", "t:<author+title key>".
    var keys: [String]
    var title: String
    var author: String
    var progress: Double
    var chapter: Int
    var fraction: Double
    var pdfPage: Int
    var status: String
    var finishedAt: Date?
    var lastOpenedAt: Date?
    var collections: [String]
    var updatedAt: Date

    /// What a change is measured by: rounded, so a value that went through
    /// JSON and back still compares equal.
    var fingerprint: String {
        [
            String(format: "%.4f", progress),
            String(chapter),
            String(format: "%.4f", fraction),
            String(pdfPage),
            status,
            finishedAt.map { String(Int($0.timeIntervalSince1970)) } ?? "-",
            collections.sorted().joined(separator: "\u{1F}"),
        ].joined(separator: "|")
    }
}

struct CloudSyncDeviceDoc: Codable, Equatable {
    var deviceName: String
    var platform: String
    var savedAt: Date
    var books: [CloudSyncRecord]

    /// Equal apart from when it was saved.
    func sameContent(as other: CloudSyncDeviceDoc) -> Bool {
        deviceName == other.deviceName && platform == other.platform && books == other.books
    }
}

/// What the server holds for one sync code.
struct CloudSyncChannel: Codable {
    var devices: [String: CloudSyncDeviceDoc] = [:]
}

/// Seals a channel for the public store: JSON, zlib, then AES-GCM with a key
/// derived from the sync code. The slot name is a hash of the code, so
/// neither the code nor the library can be read from the store.
enum CloudSyncBox {
    static let prefix = "folio1:"

    static func slot(for code: String) -> String {
        let digest = SHA256.hash(data: Data("folio-sync-slot|\(code)".utf8))
        return "folio-" + digest.map { String(format: "%02x", $0) }.joined()
    }

    static func key(for code: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: Data(code.utf8)),
            salt: Data("folio-sync".utf8),
            info: Data("folio-sync-key-v1".utf8),
            outputByteCount: 32
        )
    }

    static func seal(_ channel: CloudSyncChannel, code: String) throws -> String {
        let json = try JSONEncoder.folioSync.encode(channel)
        let packed = try (json as NSData).compressed(using: .zlib) as Data
        guard let box = try AES.GCM.seal(packed, using: key(for: code)).combined else {
            throw CocoaError(.coderInvalidValue)
        }
        return prefix + box.base64EncodedString()
    }

    /// An empty slot is an empty channel.
    static func open(_ text: String, code: String) throws -> CloudSyncChannel {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return CloudSyncChannel() }
        guard text.hasPrefix(prefix), let raw = Data(base64Encoded: String(text.dropFirst(prefix.count))) else {
            throw CocoaError(.coderReadCorrupt)
        }
        let packed = try AES.GCM.open(AES.GCM.SealedBox(combined: raw), using: key(for: code))
        let json = try (packed as NSData).decompressed(using: .zlib) as Data
        return try JSONDecoder.folioSync.decode(CloudSyncChannel.self, from: json)
    }
}

/// What this device remembers between syncs.
struct CloudSyncState: Codable {
    struct Stamp: Codable, Equatable {
        var fingerprint: String
        var updatedAt: Date
    }

    var deviceID = UUID().uuidString
    var stamps: [UUID: Stamp] = [:]
}

// MARK: - Merging (pure, so checks can run it without the app)

enum CloudSyncMerge {
    /// Dates go over the wire as whole milliseconds.
    static func wire(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 * 1000).rounded() / 1000)
    }

    /// Gives each book the time it last changed: the time a change is first
    /// noticed, or, for a book never seen before, when it was last opened.
    static func stamp(
        _ current: [(id: UUID, record: CloudSyncRecord)],
        state: inout CloudSyncState,
        now: Date
    ) -> [UUID: CloudSyncRecord] {
        var out: [UUID: CloudSyncRecord] = [:]
        for (id, var record) in current {
            let fp = record.fingerprint
            if let s = state.stamps[id], s.fingerprint == fp {
                record.updatedAt = s.updatedAt
            } else {
                let when: Date
                if state.stamps[id] == nil {
                    // First sight: as old as the last time it was read, so a
                    // device that read it more recently wins.
                    when = record.lastOpenedAt ?? Date(timeIntervalSince1970: 0)
                } else {
                    when = now
                }
                record.updatedAt = wire(when)
                state.stamps[id] = .init(fingerprint: fp, updatedAt: record.updatedAt)
            }
            out[id] = record
        }
        let live = Set(current.map(\.id))
        state.stamps = state.stamps.filter { live.contains($0.key) }
        return out
    }

    struct Incoming: Equatable {
        /// A newer state of the book from another device, to apply.
        var record: CloudSyncRecord?
        /// A later "last opened" time, for Continue Reading order.
        var lastOpenedAt: Date?
    }

    /// For each local book, the newest entry other devices have for it.
    static func incoming(
        local: [UUID: CloudSyncRecord],
        peers: [CloudSyncDeviceDoc],
        skipping: Set<UUID> = []
    ) -> [UUID: Incoming] {
        var byKey: [String: CloudSyncRecord] = [:]
        for doc in peers {
            for record in doc.books {
                for key in record.keys where (byKey[key]?.updatedAt ?? .distantPast) < record.updatedAt {
                    byKey[key] = record
                }
            }
        }
        var out: [UUID: Incoming] = [:]
        for (id, mine) in local where !skipping.contains(id) {
            // A book's first key that another device knows decides the match.
            guard let theirs = mine.keys.lazy.compactMap({ byKey[$0] }).first else { continue }
            var result = Incoming()
            if theirs.updatedAt > mine.updatedAt, theirs.fingerprint != mine.fingerprint {
                result.record = theirs
            }
            if let opened = theirs.lastOpenedAt, opened > (mine.lastOpenedAt ?? .distantPast).addingTimeInterval(1) {
                result.lastOpenedAt = opened
            }
            if result != Incoming() { out[id] = result }
        }
        return out
    }

    /// Sync codes: 16 letters and digits, shown in groups of four.
    static let codeAlphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")

    static func newCode() -> String {
        var g = SystemRandomNumberGenerator()
        return String((0..<16).map { _ in codeAlphabet.randomElement(using: &g)! })
    }

    /// Accepts a typed or pasted code in any case, with or without dashes and spaces.
    static func normalizedCode(_ raw: String) -> String? {
        let code = String(raw.uppercased().filter { $0.isLetter || $0.isNumber })
        guard (12...64).contains(code.count), code.allSatisfy({ $0.isASCII }) else { return nil }
        return code
    }

    static func display(_ code: String) -> String {
        stride(from: 0, to: code.count, by: 4).map { i in
            let start = code.index(code.startIndex, offsetBy: i)
            let end = code.index(start, offsetBy: 4, limitedBy: code.endIndex) ?? code.endIndex
            return String(code[start..<end])
        }.joined(separator: "-")
    }
}

extension JSONEncoder {
    static var folioSync: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .millisecondsSince1970
        e.outputFormatting = [.sortedKeys]
        return e
    }
}

extension JSONDecoder {
    static var folioSync: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .millisecondsSince1970
        return d
    }
}
