#if os(macOS)
import AppKit
import SwiftUI
import CoreGraphics

// The macOS app runs the same SwiftUI screens as the iPhone and iPad app
// (app/iOS/Sources). This file maps the handful of UIKit and iOS-only SwiftUI
// names those screens use onto their AppKit and macOS equivalents, so the
// shared screens compile here without forking them.

// MARK: - Images

typealias UIImage = NSImage

extension NSImage {
    convenience init(cgImage: CGImage) {
        self.init(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    var cgImage: CGImage? {
        var rect = NSRect(origin: .zero, size: size)
        return cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    /// AppKit images are measured in points that match their pixels here.
    var scale: CGFloat { 1 }

    func jpegData(compressionQuality: CGFloat) -> Data? {
        guard let cg = cgImage else { return nil }
        return NSBitmapImageRep(cgImage: cg).representation(using: .jpeg, properties: [.compressionFactor: compressionQuality])
    }

    func pngData() -> Data? {
        guard let cg = cgImage else { return nil }
        return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
    }
}

extension Image {
    init(uiImage: NSImage) { self.init(nsImage: uiImage) }
}

/// A small stand-in for UIGraphicsImageRenderer: a top-left-origin bitmap
/// context, like UIKit's, rendered into an NSImage.
final class UIGraphicsImageRendererFormat {
    var scale: CGFloat = 1
    var opaque = false
}

final class UIGraphicsImageRendererContext {
    let cgContext: CGContext
    init(cgContext: CGContext) { self.cgContext = cgContext }
}

final class UIGraphicsImageRenderer {
    private let size: CGSize
    private let format: UIGraphicsImageRendererFormat

    init(size: CGSize, format: UIGraphicsImageRendererFormat = UIGraphicsImageRendererFormat()) {
        self.size = size
        self.format = format
    }

    func image(actions: (UIGraphicsImageRendererContext) -> Void) -> NSImage {
        let scale = max(1, format.scale)
        let width = max(1, Int(size.width * scale))
        let height = max(1, Int(size.height * scale))
        let alpha: CGImageAlphaInfo = format.opaque ? .noneSkipLast : .premultipliedLast
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: alpha.rawValue) else {
            return NSImage(size: size)
        }
        // UIKit renderers draw with the origin at the top left.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        actions(UIGraphicsImageRendererContext(cgContext: context))
        guard let image = context.makeImage() else { return NSImage(size: size) }
        return NSImage(cgImage: image, size: size)
    }
}

// MARK: - Colors

typealias UIColor = NSColor

enum UIUserInterfaceStyle { case unspecified, light, dark }

struct UITraitCollection {
    var userInterfaceStyle: UIUserInterfaceStyle
}

extension NSColor {
    /// UIColor's dynamic initializer, resolved against the light or dark appearance.
    convenience init(dynamicProvider: @escaping (UITraitCollection) -> NSColor) {
        self.init(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return dynamicProvider(UITraitCollection(userInterfaceStyle: dark ? .dark : .light))
        }
    }
}

extension Color {
    init(uiColor: NSColor) { self.init(nsColor: uiColor) }
}

// MARK: - Pasteboard and haptics

final class UIPasteboard {
    static let general = UIPasteboard()
    var string: String? {
        get { NSPasteboard.general.string(forType: .string) }
        set {
            NSPasteboard.general.clearContents()
            if let newValue { NSPasteboard.general.setString(newValue, forType: .string) }
        }
    }
}

final class UIImpactFeedbackGenerator {
    enum FeedbackStyle { case light, medium, heavy, soft, rigid }
    init(style: FeedbackStyle = .medium) {}
    func prepare() {}
    func impactOccurred() {}
    func impactOccurred(intensity: CGFloat) {}
}

final class UINotificationFeedbackGenerator {
    enum FeedbackType { case success, warning, error }
    init() {}
    func prepare() {}
    func notificationOccurred(_ type: FeedbackType) {}
}

final class UISelectionFeedbackGenerator {
    init() {}
    func prepare() {}
    func selectionChanged() {}
}

// MARK: - iOS-only SwiftUI modifiers

enum NavigationBarItem {
    enum TitleDisplayMode { case automatic, inline, large }
}

enum UIKeyboardType { case `default`, asciiCapable, numbersAndPunctuation, URL, numberPad, phonePad, namePhonePad, emailAddress, decimalPad, twitter, webSearch, asciiCapableNumberPad }

struct TextInputAutocapitalization {
    static let never = TextInputAutocapitalization()
    static let words = TextInputAutocapitalization()
    static let sentences = TextInputAutocapitalization()
    static let characters = TextInputAutocapitalization()
}

enum EditMode { case inactive, transient, active
    var isEditing: Bool { self != .inactive }
}

private struct FolioEditModeKey: EnvironmentKey {
    static let defaultValue: Binding<EditMode>? = nil
}

extension EnvironmentValues {
    /// macOS lists are always editable by drag; this is only here so shared
    /// screens can set it.
    var editMode: Binding<EditMode>? {
        get { self[FolioEditModeKey.self] }
        set { self[FolioEditModeKey.self] = newValue }
    }
}

extension View {
    func navigationBarTitleDisplayMode(_ mode: NavigationBarItem.TitleDisplayMode) -> some View { self }
    func keyboardType(_ type: UIKeyboardType) -> some View { self }
    func textInputAutocapitalization(_ autocapitalization: TextInputAutocapitalization?) -> some View { self }
    func statusBarHidden(_ hidden: Bool = true) -> some View { self }
}

extension ToolbarItemPlacement {
    static var topBarTrailing: ToolbarItemPlacement { .primaryAction }
    static var topBarLeading: ToolbarItemPlacement { .navigation }
    static var bottomBar: ToolbarItemPlacement { .automatic }
}

extension ToolbarPlacement {
    /// The shared screens hide the iOS navigation bar to draw their own title
    /// rows; on the Mac that is the window toolbar.
    static var navigationBar: ToolbarPlacement { .windowToolbar }
}

enum UserInterfaceSizeClass { case compact, regular }

extension EnvironmentValues {
    /// A Mac window lays the shared screens out as on an iPad in full screen.
    var horizontalSizeClass: UserInterfaceSizeClass? { .regular }
    var verticalSizeClass: UserInterfaceSizeClass? { .regular }
}

/// UIViewRepresentable written against WebKit views works unchanged on the
/// Mac, where WKWebView is an NSView.
@MainActor @preconcurrency
protocol UIViewRepresentable: NSViewRepresentable {
    associatedtype UIViewType: NSView
    func makeUIView(context: Context) -> UIViewType
    func updateUIView(_ uiView: UIViewType, context: Context)
}

extension UIViewRepresentable {
    func makeNSView(context: Context) -> UIViewType { makeUIView(context: context) }
    func updateNSView(_ nsView: UIViewType, context: Context) { updateUIView(nsView, context: context) }
}

extension ListStyle where Self == InsetListStyle {
    static var insetGrouped: InsetListStyle { .inset }
}
#endif
