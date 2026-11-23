import SwiftUI
import UIKit

/// Folio's "reading nook" design language: warm paper backgrounds, deep
/// forest ink, olive accents, New York serif display type and soft cream
/// cards. Every color adapts to Dark Mode with a
/// low-light forest palette rather than the stock grey system colors.
enum FolioTheme {
    // MARK: Palette

    /// Warm paper page background.
    static let paper = dynamic(light: 0xF5F2E9, dark: 0x151A15)
    /// Cream card surface that sits on paper.
    static let surface = dynamic(light: 0xFDFBF4, dark: 0x1E241E)
    /// Soft sage panel, for featured or grouped blocks.
    static let sage = dynamic(light: 0xE6EADC, dark: 0x232B22)
    /// Primary ink for headings and prominent controls.
    static let ink = dynamic(light: 0x29352B, dark: 0xE9E6D9)
    /// App tint: deep forest ink in light mode, a brighter fern in dark mode
    /// so white labels on prominent buttons keep their contrast.
    static let accent = dynamic(light: 0x29352B, dark: 0x6F8660)
    /// Olive accent: links and tinted icons.
    static let olive = dynamic(light: 0x566447, dark: 0xB4C39C)
    /// Secondary text.
    static let muted = dynamic(light: 0x596356, dark: 0xA0A897)
    /// Hairline separators and card borders.
    static let line = dynamic(light: 0xD7D9CC, dark: 0x343C32)
    /// Cream glass tint for floating notices.
    static let cream = dynamic(light: 0xFBF3DE, dark: 0x2A3128)
    /// Warm wood used by shelf frames.
    static let wood = dynamic(light: 0xA9825C, dark: 0x6E5640)
    /// The back panel inside a bookcase.
    static let shelfBack = dynamic(light: 0xD5CDBA, dark: 0x2B2822)

    /// Status colors, softened to sit with the paper palette.
    static let progress = olive
    static let success = dynamic(light: 0x4F6E3E, dark: 0x9CC08A)
    static let danger = dynamic(light: 0xA2513E, dark: 0xE39A84)
    static let caution = dynamic(light: 0xA9772F, dark: 0xE2B56E)

    /// Muted cloth colors used for placeholder covers and book spines.
    static let spines: [Color] = [
        Color(hex: "#40563F"), Color(hex: "#8A7A66"), Color(hex: "#4C6676"),
        Color(hex: "#8C5F5D"), Color(hex: "#A97B47"), Color(hex: "#5F7558"),
        Color(hex: "#6E8091"), Color(hex: "#34483A")
    ]

    /// A stable cloth color for a title, so a book keeps its color.
    static func spine(for title: String) -> Color {
        var hash: UInt64 = 5381
        for byte in title.utf8 { hash = (hash &* 33) &+ UInt64(byte) }
        return spines[Int(hash % UInt64(spines.count))]
    }

    // MARK: Shape

    static let cardRadius: CGFloat = 24

    // MARK: UIKit chrome

    /// Serif navigation titles and olive tint for UIKit-backed controls.
    /// Called once at launch, before the first window is created.
    @MainActor
    static func applyAppearance() {
        let inkUI = UIColor.folioInk
        let nav = UINavigationBar.appearance()
        nav.largeTitleTextAttributes = [
            .font: serifFont(style: .largeTitle, weight: .regular),
            .foregroundColor: inkUI
        ]
        nav.titleTextAttributes = [
            .font: serifFont(style: .headline, weight: .semibold),
            .foregroundColor: inkUI
        ]
        nav.tintColor = UIColor.folioOlive
        UIView.appearance(whenContainedInInstancesOf: [UIAlertController.self]).tintColor = UIColor.folioOlive

        UITextField.appearance().tintColor = UIColor.folioOlive
        UITextView.appearance().tintColor = UIColor.folioOlive

        let segmented = UISegmentedControl.appearance()
        segmented.selectedSegmentTintColor = UIColor.folioSurface
        segmented.setTitleTextAttributes([.foregroundColor: UIColor.folioMuted], for: .normal)
        segmented.setTitleTextAttributes([.foregroundColor: inkUI], for: .selected)

        UIPageControl.appearance().currentPageIndicatorTintColor = inkUI
        UIPageControl.appearance().pageIndicatorTintColor = UIColor.folioLine
    }

    /// The system New York face at a Dynamic Type size.
    static func serifFont(style: UIFont.TextStyle, weight: UIFont.Weight) -> UIFont {
        let base = UIFont.preferredFont(forTextStyle: style)
        let weighted = base.fontDescriptor.addingAttributes([
            .traits: [UIFontDescriptor.TraitKey.weight: weight.rawValue]
        ])
        let descriptor = weighted.withDesign(.serif) ?? weighted
        return UIFont(descriptor: descriptor, size: base.pointSize)
    }

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: dynamicUI(light: light, dark: dark))
    }

    static func dynamicUI(light: UInt32, dark: UInt32) -> UIColor {
        UIColor { traits in
            uiColor(traits.userInterfaceStyle == .dark ? dark : light)
        }
    }

    private static func uiColor(_ hex: UInt32) -> UIColor {
        UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1)
    }
}

extension UIColor {
    static let folioPaper = FolioTheme.dynamicUI(light: 0xF5F2E9, dark: 0x151A15)
    static let folioSurface = FolioTheme.dynamicUI(light: 0xFDFBF4, dark: 0x1E241E)
    static let folioInk = FolioTheme.dynamicUI(light: 0x29352B, dark: 0xE9E6D9)
    static let folioOlive = FolioTheme.dynamicUI(light: 0x566447, dark: 0xB4C39C)
    static let folioMuted = FolioTheme.dynamicUI(light: 0x596356, dark: 0xA0A897)
    static let folioLine = FolioTheme.dynamicUI(light: 0xD7D9CC, dark: 0x343C32)
}

extension Font {
    /// Serif display type for headings: New York, regular weight, as in a
    /// printed book's chapter title.
    static func folioDisplay(_ style: Font.TextStyle, weight: Font.Weight = .regular) -> Font {
        .system(style, design: .serif).weight(weight)
    }
}

extension View {
    /// Paper background behind a whole screen, including List and Form.
    func folioScreen() -> some View {
        self
            .scrollContentBackground(.hidden)
            .background(FolioTheme.paper.ignoresSafeArea())
    }

    /// A cream card with a hairline border and a soft, low shadow.
    func folioCard(cornerRadius: CGFloat = FolioTheme.cardRadius, fill: Color = FolioTheme.surface) -> some View {
        self
            .background(fill, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(FolioTheme.line.opacity(0.75), lineWidth: 0.8)
            }
            .shadow(color: Color(red: 0.14, green: 0.2, blue: 0.13).opacity(0.06), radius: 14, y: 6)
    }

    /// Cream-tinted row background for List and Form rows.
    func folioRow() -> some View {
        listRowBackground(FolioTheme.surface)
    }
}

/// A placeholder cover drawn as a cloth-bound book: muted spine color,
/// thin gilt rules and a serif title, like the Nook shelf.
struct FolioClothCover: View {
    let title: String
    var subtitle: String? = nil
    var systemImage: String = "book.closed"
    var compact = false

    var body: some View {
        ZStack {
            FolioTheme.spine(for: title)
            LinearGradient(colors: [.white.opacity(0.10), .clear, .black.opacity(0.12)],
                           startPoint: .leading, endPoint: .trailing)
            VStack(spacing: compact ? 6 : 10) {
                Rectangle().fill(.white.opacity(0.35)).frame(height: 0.7)
                Spacer(minLength: 0)
                Text(title)
                    .font(.system(size: compact ? 11 : 15, weight: .regular, design: .serif))
                    .multilineTextAlignment(.center)
                    .lineLimit(compact ? 3 : 4)
                    .minimumScaleFactor(0.7)
                if let subtitle, !compact {
                    Text(subtitle)
                        .font(.system(size: 9, weight: .medium, design: .serif))
                        .textCase(.uppercase)
                        .tracking(0.8)
                        .lineLimit(2)
                        .opacity(0.8)
                }
                Spacer(minLength: 0)
                Image(systemName: systemImage)
                    .font(.system(size: compact ? 10 : 13))
                    .opacity(0.7)
                Rectangle().fill(.white.opacity(0.35)).frame(height: 0.7)
            }
            .foregroundStyle(Color(hex: "#F3EBD8"))
            .padding(.horizontal, compact ? 6 : 12)
            .padding(.vertical, compact ? 8 : 12)
        }
    }
}
