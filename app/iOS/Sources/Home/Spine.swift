import SwiftUI
import UniformTypeIdentifiers
import os

/// One spine, colored from the book's cover. Its width follows the page
/// count, its height and binding vary from book to book, and a ribbon and
/// the last progress mark a book being read.
struct FolioMobileSpine: View {
    let item: FolioNookItem
    let shelfHeight: CGFloat

    private var binding: FolioSpineBinding { FolioSpineMetrics.binding(for: item) }
    private var width: CGFloat { FolioSpineMetrics.width(for: item) }
    private var height: CGFloat { shelfHeight * FolioSpineMetrics.heightFactor(for: item) }

    private static let gilt = Color(hex: "#DCC07A")
    private static let ribbon = Color(hex: "#9E3A2F")

    var body: some View {
        let palette = FolioSpinePalettes.shared.palette(for: item)
        let art = FolioSpinePalettes.shared.strip(for: item)
        let ink = art == nil && binding == .leather ? Self.gilt : palette.textColor
        let shape = UnevenRoundedRectangle(topLeadingRadius: binding == .paperback ? 1.5 : 3, bottomLeadingRadius: 1,
                                           bottomTrailingRadius: 1, topTrailingRadius: binding == .paperback ? 1.5 : 3)
        ZStack {
            palette.baseColor
            if let art {
                // The cover's own left edge wraps onto the spine, toned a little
                // toward its main color so the title stays readable.
                Image(uiImage: art)
                    .resizable()
                    .scaledToFill()
                    .frame(width: width, height: height)
                    .clipped()
                palette.baseColor.opacity(0.38)
            } else if binding == .leather {
                Color.black.opacity(0.28)
            }
            content(palette: palette, ink: ink, art: art != nil)
            // Light catches the rounded spine on the left and falls off to the right.
            LinearGradient(stops: [
                .init(color: .white.opacity(0.18), location: 0),
                .init(color: .white.opacity(0.05), location: 0.22),
                .init(color: .clear, location: 0.5),
                .init(color: .black.opacity(0.10), location: 0.8),
                .init(color: .black.opacity(0.24), location: 1)
            ], startPoint: .leading, endPoint: .trailing)
            .allowsHitTesting(false)
        }
        .frame(width: width, height: height)
        .clipShape(shape)
        .overlay { shape.stroke(.black.opacity(0.16), lineWidth: 0.6) }
        .overlay(alignment: .topTrailing) {
            if item.reading {
                // It comes out of the top of the pages and hangs down over the
                // spine, its notched end at the bottom.
                FolioRibbon()
                    .fill(LinearGradient(colors: [Self.ribbon.opacity(0.85), Self.ribbon],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(width: 8, height: 22)
                    .shadow(color: .black.opacity(0.25), radius: 0.8, x: 0.5, y: 0.8)
                    .offset(x: -max(4, width * 0.16), y: -3)
            }
        }
        .shadow(color: .black.opacity(0.18), radius: 2, x: 1, y: 1)
        .contentShape(Rectangle())
    }

    // MARK: Parts

    private var top: CGFloat {
        switch binding {
        case .cloth: 18
        case .paperback: max(16, height * 0.13) + 6
        case .leather: 24
        case .jacket: 30
        }
    }

    private var bottom: CGFloat {
        item.progressLabel != nil ? 26 : (binding == .leather ? 26 : 22)
    }

    @ViewBuilder
    private func content(palette: FolioSpinePalette, ink: Color, art: Bool) -> some View {
        VStack(spacing: 0) {
            Group {
                if art {
                    Color.clear
                } else {
                    header(palette: palette, ink: ink)
                }
            }
            .frame(height: top, alignment: .top)
            title(ink: ink)
            Group {
                if art && item.progressLabel == nil {
                    Color.clear
                } else {
                    footer(palette: palette, ink: ink)
                }
            }
            .frame(height: bottom, alignment: .bottom)
        }
        .foregroundStyle(ink)
        .shadow(color: art ? (palette.lightText ? Color.black : Color.white).opacity(0.45) : .clear, radius: 1.2)
    }

    @ViewBuilder
    private func header(palette: FolioSpinePalette, ink: Color) -> some View {
        switch binding {
        case .cloth:
            VStack(spacing: 2) {
                rule(ink)
                rule(ink)
            }
            .padding(.top, 9)
        case .paperback:
            palette.accentColor
                .frame(height: max(16, height * 0.13))
                .overlay(alignment: .bottom) { Rectangle().fill(.black.opacity(0.12)).frame(height: 0.6) }
        case .leather:
            VStack(spacing: 5) {
                band
                band
            }
            .padding(.top, 8)
        case .jacket:
            palette.accentColor
                .frame(height: 9)
                .padding(.top, 14)
        }
    }

    @ViewBuilder
    private func footer(palette: FolioSpinePalette, ink: Color) -> some View {
        VStack(spacing: 4) {
            if let label = item.progressLabel {
                Text(label)
                    .font(.system(size: width < 32 ? 7 : 8, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .padding(.horizontal, 2)
            } else {
                switch binding {
                case .cloth:
                    Image(systemName: "leaf")
                        .font(.system(size: 8))
                        .opacity(0.75)
                case .paperback:
                    Circle()
                        .fill(palette.accentColor)
                        .overlay { Circle().stroke(ink.opacity(0.35), lineWidth: 0.6) }
                        .frame(width: 9, height: 9)
                case .leather:
                    Image(systemName: "diamond.fill")
                        .font(.system(size: 5))
                        .opacity(0.8)
                case .jacket:
                    palette.accentColor.frame(height: 5)
                }
            }
            switch binding {
            case .cloth: rule(ink).padding(.bottom, 8)
            case .leather: band.padding(.bottom, 8)
            case .paperback, .jacket: Color.clear.frame(height: 6)
            }
        }
    }

    /// The title and author run up the spine, as on English-language books
    /// shelved in Europe. Thin spines show only the surname.
    private func title(ink: Color) -> some View {
        let length = max(30, height - top - bottom)
        let thickness = max(8, width - 6)
        let size = min(16, max(7, width * 0.36))
        return HStack(spacing: 6) {
            Text(binding == .paperback ? item.title.uppercased() : item.title)
                .font(titleFont(size))
                .tracking(binding == .paperback ? 0.4 : 0)
                .lineLimit(width >= 52 ? 2 : 1)
                .minimumScaleFactor(0.55)
            if width >= 33, !item.author.isEmpty {
                Spacer(minLength: 2)
                Text(byline)
                    .font(authorFont)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .opacity(0.78)
                    .layoutPriority(-1)
            }
        }
        .frame(width: length, height: thickness)
        .rotationEffect(.degrees(-90))
        .frame(width: thickness, height: length)
    }

    private var byline: String {
        let name = item.author.split(separator: ",").first.map(String.init) ?? item.author
        let text = width < 46 ? (name.split(separator: " ").last.map(String.init) ?? name) : name
        return binding == .paperback || binding == .jacket ? text.uppercased() : text
    }

    private func titleFont(_ size: CGFloat) -> Font {
        switch binding {
        case .cloth: .system(size: size, weight: .regular, design: .serif)
        case .paperback: .system(size: size * 0.92, weight: .heavy).width(.condensed)
        case .leather: .system(size: size * 0.95, weight: .semibold, design: .serif).smallCaps()
        case .jacket: .system(size: size, weight: .medium, design: .serif).italic()
        }
    }

    private var authorFont: Font {
        switch binding {
        case .cloth, .leather: .system(size: 8.5, weight: .regular, design: .serif)
        case .paperback: .system(size: 7.5, weight: .semibold).width(.condensed)
        case .jacket: .system(size: 7.5, weight: .medium)
        }
    }

    private func rule(_ ink: Color) -> some View {
        Rectangle().fill(ink.opacity(0.55)).frame(height: 0.8)
    }

    /// A raised band across a leather spine.
    private var band: some View {
        LinearGradient(colors: [.white.opacity(0.22), .black.opacity(0.35)], startPoint: .top, endPoint: .bottom)
            .frame(height: 3)
            .overlay { Self.gilt.opacity(0.35).frame(height: 0.6) }
    }
}

/// A ribbon marker hanging from the top of a book, notched at its free end.
struct FolioRibbon: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let notch = rect.width * 0.7
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + 1))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + 1), control: CGPoint(x: rect.midX, y: rect.minY - 1))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY - notch))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// A small metal bookend holding up the last book on the shelf.
struct FolioBookend: View {
    let height: CGFloat
    /// Dark pewter on the light shelf, lighter pewter on the dark one so it stays visible.
    private let metal = FolioTheme.dynamic(light: 0x3D463B, dark: 0x9AA391)

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            UnevenRoundedRectangle(topLeadingRadius: 2, bottomLeadingRadius: 0,
                                   bottomTrailingRadius: 0, topTrailingRadius: 6)
                .fill(LinearGradient(colors: [metal.opacity(0.85), metal], startPoint: .leading, endPoint: .trailing))
                .frame(width: 7, height: height)
            RoundedRectangle(cornerRadius: 1)
                .fill(metal)
                .frame(width: 24, height: 3)
        }
        .frame(width: 24, height: height, alignment: .bottomLeading)
        .shadow(color: .black.opacity(0.18), radius: 1.5, x: 1, y: 1)
        .accessibilityHidden(true)
    }
}

/// Spines lift slightly when pressed, like pulling a book off the shelf.
struct FolioSpineButtonStyle: ButtonStyle {
    static let raise: CGFloat = 8

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .offset(y: configuration.isPressed ? -Self.raise : 0)
            .animation(.spring(response: 0.28, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// How a book stands: tipped by an angle, with the room it tips into.
struct FolioSpineLean {
    var angle: Double = 0
    var before: CGFloat = 0
    var after: CGFloat = 0
    /// Leaning books pivot on the bottom corner they tip toward.
    var anchor: UnitPoint = .bottom
}
