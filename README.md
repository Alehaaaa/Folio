# Folio

Native macOS and iOS reading application with a local library, EPUB reader,
book tracking, and configurable source extensions.

## Project layout

- `app/Core/` — models, stores, services, sources and sync, shared by the iOS
  app, the Mac app and the widget.
- `app/iOS/Sources/` — the SwiftUI screens, in feature folders (App, Home,
  Library, Book, Discover, Authors, Downloads, Settings, Sync, Reader, Theme).
  The Mac app shows the same screens.
- `app/Mac/` — Mac-only pieces: the app entry, reader window, Downloads and
  Find Source, and the UIKit shims.
- `app/iOS/` — Xcode project generator, resources and build scripts.
- `app/WidgetExtension/` — macOS WidgetKit extension.
- `app/Support/` — macOS app resources and entitlements.
- `extensions/` — documented JavaScript source extension integration.
- `checks/` and `app/checks/` — validation and regression tests.

See `app/ARCHITECTURE.md`, `app/MECHANICS.md`, and
`extensions/BROWSER_API.md` for implementation details.

## Development

The Swift package lives in `app/` (`Package.swift`), and the iOS build scripts
are under `app/iOS/`. Use the platform-specific build instructions in
`app/iOS/README.md` for iPhone builds.

Build output, packaged apps, downloaded books, screenshots, local logs,
credentials and personal workspace data are deliberately excluded from Git.

## Releases

Every push to `main` that touches `app/` or `extensions/` builds the unsigned
IPA. When the version in `app/iOS/generate_project.py` (`APP_VERSION`,
`BUILD_VERSION`) isn't published yet, CI uploads it as a GitHub Release
(`ios-<version>-<build>`) and adds it to the AltStore feed in `altstore.json`.
So bump both numbers and run `python3 app/iOS/generate_project.py` before
pushing a release. The Mac app is built locally with
`app/build/build-macos.command` and never published.

## Repository status

This repository is intended to hold source code, fixtures and test scripts only.
Do not commit reader libraries, commercial EPUBs, signing keys, API tokens or
user-specific files.
