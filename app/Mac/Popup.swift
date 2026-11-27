import SwiftUI
import Observation

/// Window-wide floating panel for book details. Unlike a sheet, clicking anywhere outside it closes it.
@Observable
@MainActor
final class PopupCenter {
    static let shared = PopupCenter()
    private(set) var content: AnyView?
    private(set) var token = UUID()
    private var onClose: (() -> Void)?

    func show(_ view: AnyView, onClose: @escaping () -> Void) {
        let previous = self.onClose
        self.onClose = nil
        previous?()
        token = UUID()
        withAnimation(.spring(duration: 0.28)) { content = view }
        self.onClose = onClose
    }

    func close() {
        let c = onClose
        onClose = nil
        withAnimation(.easeOut(duration: 0.18)) { content = nil }
        c?()
    }
}

/// Draws the open panel over the whole window: a dimmed backdrop that closes it when clicked,
/// and the panel with a round close button in its top-right corner.
struct PopupHost: View {
    @Environment(PopupCenter.self) private var center

    var body: some View {
        ZStack {
            if let content = center.content {
                Color.black.opacity(0.32)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { center.close() }
                    .transition(.opacity)
                content
                    .background(.background, in: .rect(cornerRadius: 22, style: .continuous))
                    .clipShape(.rect(cornerRadius: 22, style: .continuous))
                    .overlay { RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.separator.opacity(0.6), lineWidth: 0.5) }
                    .overlay(alignment: .topTrailing) {
                        Button { center.close() } label: {
                            Image(systemName: "xmark").font(.system(size: 13, weight: .bold)).frame(width: 30, height: 30)
                        }
                        .buttonStyle(.glass)
                        .buttonBorderShape(.circle)
                        .keyboardShortcut(.cancelAction)
                        .help("Close")
                        .padding(14)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxHeight: 700)
                    .shadow(color: .black.opacity(0.35), radius: 40, y: 18)
                    .padding(30)
                    .id(center.token)
                    .transition(.scale(scale: 0.96).combined(with: .opacity))
                    .onExitCommand { center.close() }
            }
        }
    }
}

private struct BookPopupModifier<Item: Identifiable & Hashable, Panel: View>: ViewModifier {
    @Binding var item: Item?
    let panel: (Item) -> Panel

    func body(content: Content) -> some View {
        content.onChange(of: item) { _, new in
            guard let new else { return }
            PopupCenter.shared.show(AnyView(panel(new))) { item = nil }
        }
    }
}

extension View {
    /// Shows `panel` in the window's floating popup while `item` is set.
    func bookPopup<Item: Identifiable & Hashable, Panel: View>(item: Binding<Item?>, @ViewBuilder panel: @escaping (Item) -> Panel) -> some View {
        modifier(BookPopupModifier(item: item, panel: panel))
    }
}
