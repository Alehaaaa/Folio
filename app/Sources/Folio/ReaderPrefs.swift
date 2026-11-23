import SwiftUI
import Observation

/// Books' six reading themes (identifiers found in Books.app at 0x1007da058).
enum ReaderTheme: String, CaseIterable, Codable, Identifiable {
    case original, quiet, paper, bold, calm, focus
    var id: String { rawValue }

    var label: String { rawValue.capitalized }

    struct Palette { var bg: String; var fg: String; var accent: String }

    func palette(dark: Bool) -> Palette {
        switch (self, dark) {
        case (.original, false): Palette(bg: "#FFFFFF", fg: "#1C1C1E", accent: "#0A64D6")
        case (.original, true): Palette(bg: "#121212", fg: "#E3E3E5", accent: "#5AA2FF")
        case (.quiet, false): Palette(bg: "#E9EAEE", fg: "#31333A", accent: "#355FA8")
        case (.quiet, true): Palette(bg: "#4A4A4E", fg: "#D4D4D6", accent: "#A9C7FF")
        case (.paper, false): Palette(bg: "#EDE0C6", fg: "#2D342C", accent: "#566447")
        case (.paper, true): Palette(bg: "#1E211C", fg: "#E2DCCB", accent: "#B4C39C")
        case (.bold, false): Palette(bg: "#FFFFFF", fg: "#000000", accent: "#0050C8")
        case (.bold, true): Palette(bg: "#000000", fg: "#FFFFFF", accent: "#6FB0FF")
        case (.calm, false): Palette(bg: "#F4E8D3", fg: "#4A3B2A", accent: "#8A5A20")
        case (.calm, true): Palette(bg: "#3A3127", fg: "#E8D9C0", accent: "#E0B070")
        case (.focus, false): Palette(bg: "#FFFAE9", fg: "#2D2A1F", accent: "#8C6D12")
        case (.focus, true): Palette(bg: "#27251C", fg: "#EDE5C8", accent: "#E5C55A")
        }
    }

    /// Each theme's own typeface, as in Books' theme picker (estimated pairings).
    var defaultFont: ReaderFont {
        switch self {
        case .original, .quiet: .original
        case .paper: .charter
        case .bold: .sanFrancisco
        case .calm: .iowan
        case .focus: .newYork
        }
    }

    var isBold: Bool { self == .bold }
}

enum ReaderFont: String, CaseIterable, Codable, Identifiable {
    case original, athelas, charter, georgia, iowan, palatino, newYork, sanFrancisco, seravek, times
    var id: String { rawValue }

    var label: String {
        switch self {
        case .original: "Original"
        case .athelas: "Athelas"
        case .charter: "Charter"
        case .georgia: "Georgia"
        case .iowan: "Iowan"
        case .palatino: "Palatino"
        case .newYork: "New York"
        case .sanFrancisco: "San Francisco"
        case .seravek: "Seravek"
        case .times: "Times New Roman"
        }
    }

    /// CSS font-family; nil keeps the publisher's font.
    var css: String? {
        switch self {
        case .original: nil
        case .athelas: "Athelas, serif"
        case .charter: "Charter, serif"
        case .georgia: "Georgia, serif"
        case .iowan: "'Iowan Old Style', serif"
        case .palatino: "Palatino, serif"
        case .newYork: "ui-serif, 'New York', serif"
        case .sanFrancisco: "-apple-system, system-ui, sans-serif"
        case .seravek: "Seravek, sans-serif"
        case .times: "'Times New Roman', serif"
        }
    }

    var swiftUIFont: Font {
        switch self {
        case .original, .newYork: .system(size: 15, design: .serif)
        case .sanFrancisco: .system(size: 15)
        case .athelas: .custom("Athelas", size: 15)
        case .charter: .custom("Charter", size: 15)
        case .georgia: .custom("Georgia", size: 15)
        case .iowan: .custom("Iowan Old Style", size: 15)
        case .palatino: .custom("Palatino", size: 15)
        case .seravek: .custom("Seravek", size: 15)
        case .times: .custom("Times New Roman", size: 15)
        }
    }
}

enum PageNavigation: String, CaseIterable, Codable, Identifiable {
    case pages, scroll
    var id: String { rawValue }
    var label: String { self == .pages ? "Pages" : "Scroll" }
}

enum ReaderAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: "Automatic"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
    var symbol: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max.fill"
        case .dark: "moon.fill"
        }
    }
    func isDark(systemDark: Bool) -> Bool {
        switch self {
        case .system: systemDark
        case .light: false
        case .dark: true
        }
    }
}

struct ReaderPrefs: Codable, Equatable {
    static let fontSizes: [Int] = [12, 14, 15, 16, 17, 18, 20, 22, 24, 26, 28, 32, 36, 42, 48]

    var theme: ReaderTheme = .paper
    var font: ReaderFont = .original
    var fontSizeIndex = 6
    var boldText = false
    var customLineSpacing = false
    var lineSpacing = 1.5
    var customCharacterSpacing = false
    var characterSpacing = 0.03
    var customWordSpacing = false
    var wordSpacing = 0.1
    var customMargins = false
    var margins = 56.0
    var justify = false
    var multipleColumns = true
    var navigation: PageNavigation = .pages

    var fontSize: Int { Self.fontSizes[max(0, min(Self.fontSizes.count - 1, fontSizeIndex))] }
}

@Observable
@MainActor
final class ReaderPrefsStore {
    static let shared = ReaderPrefsStore()
    var appearance: ReaderAppearance {
        didSet { UserDefaults.standard.set(appearance.rawValue, forKey: "readerAppearance") }
    }
    var prefs: ReaderPrefs {
        didSet { save() }
    }

    private init() {
        appearance = ReaderAppearance(rawValue: UserDefaults.standard.string(forKey: "readerAppearance") ?? "") ?? .system
        if let d = UserDefaults.standard.data(forKey: "readerPrefs"), let p = try? JSONDecoder().decode(ReaderPrefs.self, from: d) {
            prefs = p
        } else {
            prefs = ReaderPrefs()
        }
    }

    private func save() {
        if let d = try? JSONEncoder().encode(prefs) { UserDefaults.standard.set(d, forKey: "readerPrefs") }
    }

    func pickTheme(_ t: ReaderTheme) {
        // Theme swatches change the paper and ink palette only. Readers choose
        // typography independently, and changing colors must not repaginate
        // the chapter or override a chosen font / boldness.
        prefs.theme = t
    }
}

extension Color {
    init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        let v = UInt64(s, radix: 16) ?? 0
        self.init(.sRGB, red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}
