# Folio application structure and reading journey

This document maps the live application entry points and the data transitions that
must remain reliable as Folio grows.

**One set of screens on both platforms.** The code lives in three folders:

- `Core/`: models, stores, Hardcover and Open Library clients, sources and the
  download queue, EPUB, Folio Sync. Every file here is compiled by the iOS app,
  the Mac app and (for `WidgetShared.swift`) the widget. It holds no screens.
- `iOS/Sources/`: the SwiftUI screens, in feature folders (`App`, `Home`,
  `Library`, `Book`, `Discover`, `Authors`, `Downloads`, `Settings`, `Sync`,
  `Reader`, `Theme`). The Mac compiles all of them except `excludedFromMac` in
  `Package.swift` (the iOS reader, update checker, Downloads, Find Source and
  system integration), so the Mac shows the same Home, nook, Library,
  Discover, book, author and Settings screens, as a sidebar window.
- `Mac/`: the Mac-only pieces: the app entry and window root, the Downloads
  page and Find Source picker (`DownloadingView`, `FindSourceFlow`), the
  reader window, and `UIKitCompat.swift`, which maps the UIKit and iOS-only
  SwiftUI names the shared screens use onto AppKit. Prefer a shim over
  `#if os(iOS)` in a shared file.

`iOS/generate_project.py` builds the Xcode project from whatever is in `Core/`
and `iOS/Sources/`, so new files need no list, only a regenerate. A new file in
`iOS/Sources` builds for the Mac too, so check the macOS build
(`.github/workflows/macos-app.yml`) after adding one. Keep file names unique
across all three folders.

## Primary user journey

| Stage | User-facing entry | Underlying owner | Next step |
| --- | --- | --- | --- |
| Discover | Home nook and rows, Discover, author and series pages | `Home/HomeView.swift`, `Library/LibraryView.swift`, `Discover/DiscoverView.swift`, `Authors/` | Open book details |
| Evaluate | Book page | `Book/BookDetail.swift` (both platforms) | Read if local; Find Source if absent |
| Find a copy | Find Source in book details | `Mac/FindSourceFlow.swift`, `Downloads/FindSourceView.swift` and `DownloadQueue` | Background search and import; no forced navigation |
| Track retrieval | Downloads, in-app notices | `DownloadingView` (macOS), `Downloads/DownloadsView.swift` (iOS), `DownloadQueue` | Read or open book details after verification |
| Read | Reader window (macOS) or mobile reader | `Mac/ReaderWindow.swift`, `Reader/ReaderView.swift` | Automatic reading position and duration updates |
| Organize and review | Book page and My Shelves | `Library/Shelves.swift`, book page, `LibraryStore` | Change reading status, rating, position, collection |

The primary button on **every book detail** follows the availability of an actual
local file: **Start Reading / Continue Reading** when present, **Find Source**
otherwise. A downloaded book belongs to Library immediately after verification;
starting to read moves an unstarted/wishlisted local book to Reading Now.

## Sources of truth and background behavior

- `LibraryStore.swift` owns imported file metadata, local reading position,
  status, shelves, collections and reading activity. Never derive the ability to
  read from a remote service status alone.
- `DownloadQueue.swift` owns persistent jobs and their stages. Background work
  must survive navigation changes and relaunch. It emits `folioDownloadReady`
  and `folioDownloadFailed` once a job reaches its terminal stage, so the main
  window can show non-disruptive actions. A verified copy is imported before a
  **Ready to Read** action appears.
- `Core/AutomaticEPUBChoice.swift` owns conservative edition ranking.
  Downloads are checked against the requested title, author and language before
  being accepted as library files. `checks/test-automatic-epub-ranking.swift` exercises
  this actual selector.
- `Hardcover.swift` and `Goodreads.swift` own remote books/shelves. The unified
  My Shelves UI combines local and remote records but must preserve each source's
  independent status and give local copies priority for reading.
- The native reader saves local position as the person turns pages. Closing a
  linked macOS reader uses the **last saved local position** to synchronize
  Hardcover pages, and records the synced-page marker only after a successful
  request. Progress editors must update reader position as well as percentage,
  or reopening the reader will overwrite the displayed value.

## Directory boundaries

| Location | Responsibility |
| --- | --- |
| `Core/` | Shared models, stores, services, sources, sync |
| `iOS/Sources/App/` | Tab root, app entry, onboarding, updates, logs, caches |
| `iOS/Sources/Theme/` | Palette, radius tokens, page headers, rows, glass |
| `iOS/Sources/Home/` | Home, the nook (bookshelf, spines, drag and drop), activity |
| `iOS/Sources/Book/` | Book page, edit details, reviews, ratings, covers |
| `iOS/Sources/Sync/` | Folio Sync screen, shelf services, Hardcover progress sync |
| `Mac/FolioMacRootView.swift` | Mac window: sidebar tabs, `folio-reader://` links and global notices |
| `Mac/DownloadingView.swift`, `Mac/ReaderWindow.swift` | Mac queue page and reading window |

Prefer a small feature file for a new subview over adding another large section
to a root view. Keep shared models and persistence separate from native
platform-specific views. New shared dependencies must build on both platforms.

## Validation without changing a user's library

From `app/`:

```sh
swift build -c release
swiftc -swift-version 5 Core/BookAutoMatch.swift Core/EditionTitle.swift Core/AutomaticEPUBChoice.swift ../checks/test-automatic-epub-ranking.swift -o /tmp/ranking && /tmp/ranking
"$HOME/.cargo/bin/cargo" build
codesign --verify --deep --strict Folio.app
```

On iOS run `iOS/build-simulator.sh` or an equivalent isolated `xcodebuild` using
`CODE_SIGNING_ALLOWED=NO`. To inspect UI flows without touching real library
data, launch a signed preview copy with `FOLIO_DATA_DIR=shots/testdata`
(`--screenshot <file.png>` saves the main window and quits).

CI: `.github/workflows/macos-app.yml` only compile-checks the Mac app on each
push. Folio.app is never published; build it locally with `cargo build` in `app/`.
