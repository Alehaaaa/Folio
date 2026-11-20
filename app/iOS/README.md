# Folio for iOS

Open **FolioiOS.xcodeproj** in Xcode 27.2 or later, select the **Folio** scheme
and an iPhone simulator, and build. A command-line simulator build is also
available:

```bash
cd /books/app/iOS
./build-simulator.sh
```

The native iOS target includes the existing `../Sources/Folio/*.swift`
business logic by direct Xcode file references. The selected shared source
list lives in `generate_project.py`. No copies of shared Swift source files
are made. Swift files added to `iOS/Sources` are picked up automatically
whenever the generator is run.

The iOS UI in `iOS/Sources` provides a book library with file import,
document and chapter reading, and source-extension search/download. It reuses
the same library storage, EPUB metadata, matching, Goodreads, Hardcover,
reading preferences and JavaScript extension engine as the desktop app.
macOS-specific AppKit views and entry points are excluded.

**Downloading and Find Source:** The native Downloading tab uses the shared
`DownloadQueue.swift`, persists in-flight and completed jobs, resumes pending
searches on launch, streams extension status/error messages into activity logs,
and only downloads an EPUB unattended when its full title and author match.
Failed jobs support Retry, Cancel/Dismiss, and **Choose Source** to select a
specific edition or format manually. All download tasks run independently of
the active navigation tab and reading view. Reader appearance supports both
horizontal paginated EPUB pages and vertical Scroll mode.

Every `../../extensions/*.js` file is copied into the app bundle and installed
through the shared `ExtensionStore` on launch. Gutenberg and Calibre are
embedded by the shared `DefaultSources.swift` implementation.
The ZIPFoundation Swift package provides archive functions on iOS.

**WidgetKit:** The generated Xcode project also has a `FolioWidgets` extension
target (book lists, reading goals and open-library control). It embeds
`FolioWidgets.appex` under `Payload/Folio.app/PlugIns` and shares the
`WidgetShared.swift` snapshot model without copying any macOS UI code.
The app and widget extension both request the Application Group
`group.app.folio.reader.ios`, configured in
`Resources/Folio.entitlements` and
`WidgetExtension/FolioWidgets.entitlements` respectively. For widgets to read
the shared snapshot on a physical iPhone, configure a real Apple Developer
Team with that App Group enabled on **both** bundle identifiers:
`app.folio.reader.ios` and `app.folio.reader.ios.widgets`.
Unsigned simulator/IPA builds can compile and package the widget, but the
shared group container may not be accessible until provisioning is installed.

The iOS deployment target is **iOS 18**. The simulator build disables code
signing. The generated target is restricted to arm64 to match both current
Apple Silicon simulators and physical iOS devices.
The application bundle identifier is `app.folio.reader.ios`.

To create an unsigned device IPA in `iOS/dist/Folio.ipa`:

```bash
cd /books/app/iOS
./build-ipa.sh
```

The unsigned IPA is useful for CI, binary inspection and subsequent signing,
but a normal iPhone installation requires a distribution certificate and
provisioning profile. With valid Xcode signing configured, set
`EXPORT_OPTIONS_PLIST=/absolute/path/ExportOptions.plist` to archive and
export a signed IPA using Xcode instead. The IPA script validates the app and
widget executables, embedded widget `Info.plist`, every bundled external JS
extension, and the archive's ZIP integrity before reporting success.

To regenerate the project after adding iOS-only files:

```bash
python3 generate_project.py
```

**App icon:** The iOS asset retains the same orange gradient and white book
mark as the macOS Folio.icns, but is regenerated as an opaque, full-bleed
1024x1024 image. The macOS original has transparent padding and a
pre-rounded square, which creates a dark border when iOS masks it again.
After changing the macOS artwork, regenerate the iOS asset by running:

    cd /books/app/iOS
    swift make_app_icon.swift

The script updates Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png.
