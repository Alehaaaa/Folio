import SwiftUI

/// Apply to any SwiftUI Button: .buttonStyle(FolioPillButtonStyle(prominent: true)).
/// The primitive wrapper lets SwiftUI's native glass material style the actual
/// button on iOS 26, with a tactile capsule fallback on earlier iOS releases.
struct FolioPillButtonStyle: PrimitiveButtonStyle {
    var prominent: Bool = false

    @ViewBuilder
    func makeBody(configuration: Configuration) -> some View {
        if #available(iOS 26, *) {
            if prominent {
                Button(action: { configuration.trigger() }) { configuration.label }
                    .buttonStyle(.glassProminent)
                    .buttonBorderShape(.capsule)
            } else {
                Button(action: { configuration.trigger() }) { configuration.label }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.capsule)
            }
        } else {
            if prominent {
                Button(action: { configuration.trigger() }) { configuration.label }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
            } else {
                Button(action: { configuration.trigger() }) { configuration.label }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
            }
        }
    }
}

extension View {
    /// Applies native Liquid Glass to buttons on iOS 26 and a capsule style on iOS 18+.
    @ViewBuilder
    func folioGlassPill(prominent: Bool = false) -> some View {
        if #available(iOS 26, *) {
            if prominent {
                self.buttonStyle(.glassProminent).buttonBorderShape(.capsule)
            } else {
                self.buttonStyle(.glass).buttonBorderShape(.capsule)
            }
        } else {
            if prominent {
                self.buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
            } else {
                self.buttonStyle(.bordered).buttonBorderShape(.capsule)
            }
        }
    }
}

struct FolioGlassPill<Label: View>: View {
    var prominent: Bool = false
    let action: () -> Void
    @ViewBuilder let label: Label

    var body: some View {
        Button(action: action) { label }
            .folioGlassPill(prominent: prominent)
    }
}

struct FolioGlassButton: View {
    let title: String
    var systemImage: String? = nil
    var prominent = false
    var fullWidth = false
    let action: () -> Void

    var body: some View {
        FolioGlassPill(prominent: prominent, action: action) {
            Group {
                if let systemImage {
                    Label(title, systemImage: systemImage)
                } else {
                    Text(title)
                }
            }
            .font(.headline)
            .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: fullWidth ? 44 : 0)
        }
    }
}

extension View {
    /// A Liquid Glass panel background on iOS 26, regular material before.
    /// The glass takes the given shape; a bare `glassEffect()` defaults to a
    /// capsule, which tall panels overflow.
    @ViewBuilder
    func folioGlassBackground<S: Shape>(in shape: S) -> some View {
        if #available(iOS 26, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self.background(.regularMaterial, in: shape)
        }
    }

    /// The app's cream-tinted glass for floating notices. The reader keeps
    /// the neutral `folioGlassBackground`, since its themes are its own.
    @ViewBuilder
    func folioCreamGlass<S: Shape>(in shape: S) -> some View {
        if #available(iOS 26, *) {
            self.glassEffect(.regular.tint(FolioTheme.cream.opacity(0.55)), in: shape)
        } else {
            self.background(.regularMaterial, in: shape)
                .background(FolioTheme.cream.opacity(0.5), in: shape)
        }
    }
}

/// A full-width action in a Form or List row, drawn like a system Settings row:
/// an olive icon in the row's icon column and an ink title. Glass capsules
/// inside list rows dropped their icons and left an empty gap before the title.
struct FolioFormLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        FolioFormLabel(configuration: configuration)
    }

    private struct FolioFormLabel: View {
        let configuration: LabelStyleConfiguration
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            HStack(spacing: 15) {
                configuration.icon
                    .font(.body)
                    .imageScale(.large)
                    .foregroundStyle(FolioTheme.olive)
                    .frame(width: 28)
                configuration.title
                    .foregroundStyle(FolioTheme.ink)
            }
            .opacity(enabled ? 1 : 0.4)
        }
    }
}

extension View {
    /// The row action style for buttons that fill a Form or List row.
    func folioFormButton() -> some View {
        buttonStyle(.borderless).labelStyle(FolioFormLabelStyle())
    }
}
