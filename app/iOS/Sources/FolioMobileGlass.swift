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
    /// A cream-tinted Liquid Glass panel on iOS 26, warm material before.
    /// The glass takes the given shape; a bare `glassEffect()` defaults to a
    /// capsule, which tall panels overflow.
    @ViewBuilder
    func folioGlassBackground<S: Shape>(in shape: S) -> some View {
        if #available(iOS 26, *) {
            self.glassEffect(.regular.tint(FolioTheme.cream.opacity(0.55)), in: shape)
        } else {
            self.background(.regularMaterial, in: shape)
                .background(FolioTheme.cream.opacity(0.5), in: shape)
        }
    }
}
