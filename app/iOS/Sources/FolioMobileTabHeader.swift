import UIKit
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

/// A rounded search field for tabs whose header replaces the navigation bar.
struct FolioSearchField: View {
    @Binding var text: String
    let prompt: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(FolioTheme.muted)
            TextField(prompt, text: $text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(FolioTheme.muted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(FolioTheme.surface, in: Capsule())
        .overlay { Capsule().strokeBorder(FolioTheme.line, lineWidth: 0.8) }
    }
}

// MARK: - Pushed pages

/// The header of a pushed page: the back chevron and the title on one row, at the same
/// height and size as the tab titles, instead of a large title dropping below the back button.
struct FolioPageHeaderBar<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: () -> Trailing
    @Environment(\.dismiss) private var dismiss
    @Environment(\.isPresented) private var isPresented

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            if isPresented {
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
        .padding(.leading, isPresented ? 8 : 20)
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
