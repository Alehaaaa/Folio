import SwiftUI

/// Primitive styles keep the actual Button in charge of rendering its glass.
/// Applying a glass material to a custom capsule loses native interactions,
/// hover response and the system's material blending.
struct BookPrimaryActionStyle: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button(action: { configuration.trigger() }) {
            configuration.label
                .foregroundStyle(.white)
                .padding(.horizontal, 7)
        }
        .buttonStyle(.glassProminent)
        .buttonBorderShape(.capsule)
        .tint(.indigo)
        .foregroundStyle(.white)
    }
}

struct BookSecondaryActionStyle: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button(action: { configuration.trigger() }) {
            configuration.label
                .foregroundStyle(Color(nsColor: .labelColor))
                .padding(.horizontal, 6)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.capsule)
        .foregroundStyle(Color(nsColor: .labelColor))
    }
}

struct BookShelfStatusStyle: PrimitiveButtonStyle {
    let selected: Bool

    @ViewBuilder
    func makeBody(configuration: Configuration) -> some View {
        if selected {
            Button(action: { configuration.trigger() }) {
                configuration.label
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.capsule)
            .tint(.indigo)
            .foregroundStyle(.white)
        } else {
            Button(action: { configuration.trigger() }) {
                configuration.label
                    .foregroundStyle(Color(nsColor: .labelColor))
                    .padding(.horizontal, 6)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.capsule)
            .foregroundStyle(Color(nsColor: .labelColor))
        }
    }
}
