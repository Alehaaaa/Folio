import SwiftUI

/// One-tap reading profiles. These only update the existing persisted reader
/// preferences, so books keep their chosen reading position and navigation mode.
struct FolioMobileReadabilitySettings: View {
    @Environment(ReaderPrefsStore.self) private var preferences
    @Environment(\.colorScheme) private var colorScheme
    @ScaledMetric(relativeTo: .body) private var textSizeScale: CGFloat = 1
    /// Row background; Settings passes the app's warm surface, the reader keeps its own.
    var rowBackground: Color? = nil

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                Text("Preview")
                    .font(.subheadline.weight(.semibold))
                Text("A good book deserves room to breathe. Adjust the type and spacing until each page feels effortless to read.")
                    .font(.system(size: CGFloat(preferences.prefs.fontSize) * textSizeScale, design: previewDesign))
                    .fontWeight(preferences.prefs.boldText ? .semibold : .regular)
                    .lineSpacing(preferences.prefs.customLineSpacing ? CGFloat(max(0, preferences.prefs.lineSpacing - 1) * 12) : 5)
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(Color(hex: previewPalette.fg))
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(hex: previewPalette.bg), in: RoundedRectangle(cornerRadius: 16))
                    .accessibilityLabel("Reading preview. A good book deserves room to breathe.")

                Text("Choose a starting point, then fine-tune your font and spacing below.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 4)

            Button {
                applyComfortable()
            } label: {
                readabilityRow("Comfortable", symbol: "textformat.size")
            }
            .folioGlassPill()
            .accessibilityHint("Applies larger serif text, wider margins and line spacing")

            Button {
                applyHighContrast()
            } label: {
                readabilityRow("High Contrast", symbol: "circle.lefthalf.filled")
            }
            .folioGlassPill()
            .accessibilityHint("Applies high-contrast colors and bold sans serif text")

            Button {
                applyFocus()
            } label: {
                readabilityRow("Quiet Focus", symbol: "leaf")
            }
            .folioGlassPill()
            .accessibilityHint("Applies warm paper colors and calm typography")
        } header: {
            Text("Easy Reading")
        } footer: {
            Text("These profiles change only the reading appearance; they don't change your book progress, notes, or bookmarks.")
        }
        .listRowBackground(rowBackground)
    }

    private var previewDesign: Font.Design {
        switch preferences.prefs.font {
        case .sanFrancisco, .seravek: .default
        default: .serif
        }
    }

    private var previewPalette: ReaderTheme.Palette {
        preferences.prefs.theme.palette(dark: preferences.appearance.isDark(systemDark: colorScheme == .dark))
    }

    private func readabilityRow(_ title: String, symbol: String) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .frame(width: 27)
                .accessibilityHidden(true)
            Text(title)
                .font(.body.weight(.semibold))
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func applyComfortable() {
        var settings = preferences.prefs
        settings.theme = .paper
        settings.font = .charter
        settings.fontSizeIndex = 8 // 24 pt
        settings.boldText = false
        settings.customLineSpacing = true
        settings.lineSpacing = 1.65
        settings.customMargins = true
        settings.margins = 44
        settings.justify = false
        preferences.prefs = settings
    }

    private func applyHighContrast() {
        var settings = preferences.prefs
        settings.theme = .bold
        settings.font = .sanFrancisco
        settings.fontSizeIndex = 8 // 24 pt
        settings.boldText = true
        settings.customLineSpacing = true
        settings.lineSpacing = 1.65
        settings.customMargins = true
        settings.margins = 48
        settings.justify = false
        preferences.prefs = settings
    }

    private func applyFocus() {
        var settings = preferences.prefs
        settings.theme = .focus
        settings.font = .newYork
        settings.fontSizeIndex = 7 // 22 pt
        settings.boldText = false
        settings.customLineSpacing = true
        settings.lineSpacing = 1.6
        settings.customMargins = true
        settings.margins = 52
        settings.justify = false
        preferences.prefs = settings
    }
}
