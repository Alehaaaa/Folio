# Folio

Native macOS and iOS reading application with a local library, EPUB reader,
book tracking, and configurable source extensions.

## Project layout

- `app/Sources/Folio/` — shared Swift application and reader sources.
- `app/iOS/` — iOS app, Xcode project generator, resources and build scripts.
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

## Repository status

This repository is intended to hold source code, fixtures and test scripts only.
Do not commit reader libraries, commercial EPUBs, signing keys, API tokens or
user-specific files.
