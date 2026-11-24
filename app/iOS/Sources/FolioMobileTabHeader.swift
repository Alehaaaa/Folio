#if os(iOS)
import UIKit
#endif
import SwiftUI

/// The top of each tab, as on Home: one serif title and plain icon buttons on the same
/// line, at the same height and margins on every tab.
struct FolioTabHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            Text(title)
                .font(.system(size: 46, weight: .regular, design: .serif))
                .tracking(-1.5)
                .foregroundStyle(FolioTheme.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            trailing()
        }
        .frame(minHeight: 56)
    }
}

/// A plain icon button for tab headers, the same as Home's +.
struct FolioHeaderIcon: View {
    let symbol: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) { FolioHeaderIconLabel(symbol: symbol) }
            .buttonStyle(.plain)
            .foregroundStyle(FolioTheme.ink)
            .accessibilityLabel(label)
    }
}

struct FolioHeaderIconLabel: View {
    let symbol: String

    var body: some View {
        Image(systemName: symbol)
            .font(.title2.weight(.light))
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
    }
}

/// The search field for tabs whose header replaces the navigation bar: the
/// system's own field on the Mac, a Liquid Glass capsule like the system's
/// search bar on iPhone and iPad.
struct FolioSearchField: View {
    @Binding var text: String
    let prompt: String
    /// Return in the field, for pages that search on demand.
    var onSubmit: (() -> Void)? = nil

    var body: some View {
        #if os(macOS)
        FolioNativeSearchField(text: $text, prompt: prompt, onSubmit: onSubmit)
            .frame(height: 30)
        #else
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.body.weight(.medium))
                .foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .onSubmit { onSubmit?() }
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .font(.body)
        .padding(.horizontal, 14)
        .frame(minHeight: 44)
        .modifier(FolioSearchGlass())
        #endif
    }
}

#if os(macOS)
import AppKit

/// AppKit's search field: the native look, clear button and focus ring.
struct FolioNativeSearchField: NSViewRepresentable {
    @Binding var text: String
    let prompt: String
    var onSubmit: (() -> Void)?

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = prompt
        field.controlSize = .large
        field.font = .systemFont(ofSize: NSFont.systemFontSize(for: .large))
        field.sendsSearchStringImmediately = true
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.changed(_:))
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.onSubmit = onSubmit
        if field.stringValue != text { field.stringValue = text }
        field.placeholderString = prompt
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text, onSubmit: onSubmit) }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>
        var onSubmit: (() -> Void)?
        init(text: Binding<String>, onSubmit: (() -> Void)?) {
            self.text = text
            self.onSubmit = onSubmit
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.insertNewline(_:)), let onSubmit else { return false }
            onSubmit()
            return true
        }

        @objc func changed(_ sender: NSSearchField) { text.wrappedValue = sender.stringValue }
        func controlTextDidChange(_ note: Notification) {
            if let field = note.object as? NSSearchField { text.wrappedValue = field.stringValue }
        }
    }
}
#else
/// Liquid Glass where the system has it, a soft fill before that.
private struct FolioSearchGlass: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: Capsule())
        } else {
            content.background(.regularMaterial, in: Capsule())
        }
    }
}
#endif

// MARK: - Pushed pages

/// The header of a pushed page: the back chevron and the title on one row, at the same
/// height and size as the tab titles, instead of a large title dropping below the back button.
extension EnvironmentValues {
    /// True for the first page of a tab, which has nothing to go back to
    /// (the Mac reports such pages as presented).
    @Entry var folioTabRoot = false
}

struct FolioPageHeaderBar<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: () -> Trailing
    @Environment(\.dismiss) private var dismiss
    @Environment(\.isPresented) private var isPresented
    @Environment(\.folioTabRoot) private var tabRoot

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            #if os(iOS)
            if isPresented && !tabRoot {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left")
                        .font(.title2.weight(.regular))
                        .frame(width: 40, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(FolioTheme.ink)
                .accessibilityLabel("Back")
            }
            #endif
            Text(title)
                .font(.system(size: 46, weight: .regular, design: .serif))
                .tracking(-1.5)
                .foregroundStyle(FolioTheme.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            trailing()
        }
        .frame(minHeight: 56)
        .padding(.leading, {
            #if os(iOS)
            return isPresented && !tabRoot ? 8 : 20
            #else
            return 20
            #endif
        }())
        .padding(.trailing, 20)
        .padding(.top, 12)
        .padding(.bottom, 4)
        .background(FolioTheme.paper)
    }
}

extension View {
    /// Replaces the navigation bar with `FolioPageHeaderBar`.
    func folioPageHeader(_ title: String) -> some View {
        folioPageHeader(title) { EmptyView() }
    }

    /// The same header with plain icon buttons after the title, in place of toolbar buttons.
    func folioPageHeader<Trailing: View>(_ title: String, @ViewBuilder trailing: @escaping () -> Trailing) -> some View {
        toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .top, spacing: 0) { FolioPageHeaderBar(title: title, trailing: trailing) }
    }
}

#if os(iOS)
/// Keeps the swipe-from-the-edge back gesture working on pages that hide the navigation bar.
extension UINavigationController: @retroactive UIGestureRecognizerDelegate {
    override open func viewDidLoad() {
        super.viewDidLoad()
        interactivePopGestureRecognizer?.delegate = self
    }

    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        viewControllers.count > 1
    }
}
#endif
