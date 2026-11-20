# Folio — mechanics sheet

Values found while studying Apple Books (`/System/Applications/Books.app/Contents/MacOS/Books`, arm64),
the Hardcover app and the PirateReads Goodreads API. Ghidra's decompiler isn't built on this Mac, so
addresses come from string references in the built-in engine; "estimated" means it was looked for and
not found.

## Library (Books' BKLibrary collection identifiers, strings at 0x10081e670–0x100815c20)
- Built-in collections: All, Want to Read, Finished, Books, Audiobooks, PDFs, My Samples, Downloaded,
  plus user collections (`LibraryUserCollectionIdentifier` 0x10081df90).
- Folio keeps All, Want to Read, Reading Now, Finished, Books (EPUB), PDFs, Documents & Comics and user
  collections. Audiobooks, samples and downloads belong to Apple's store and are left out.

## Reading goals (ReadingActivityService, strings 0x100896f60 / 0x100897240, refs in sub_1001a679c, sub_1005ef33c)
- Tracks `dailyGoal` (minutes per day), `isDailyGoalCompleted`, `booksPerYear`, `dailyGoalReached`,
  `yearlyGoalReached`, and a PDF inclusion setting (`BKReadingGoalsIncludePDFsUserDefaultsKey`).
- Daily goal default: 5 minutes — estimated (the default lives in code Ghidra couldn't decompile here).
- Books-per-year default: 3 — estimated.
- Reading time counts while a book window is open and the app is in front, in 15-second ticks, capped
  at 30 s per tick.
- Streak: consecutive days meeting the daily goal, ending today (or yesterday if today isn't met yet).

## Reader (BookSettings AppEntity intents, strings 0x100806970–0x100806ac0)
- Settings: font, fontSize, theme, pageNavigationSetting (pages / scroll), isTextJustified,
  isAllowMultipleColumns; customise toggles for bold text, line, character and word spacing
  (`_shouldVoiceOverFocus…SpacingToggle` 0x10095d420–0x10095d480) and margins.
- Themes (0x1007da058): original, quiet, paper, bold, calm, focus. Colours are estimated.
- Fonts: Original, Athelas, Charter, Georgia, Iowan, Palatino, New York, San Francisco, Seravek,
  Times New Roman — estimated list (font names live in Books' frameworks, not the main program).
- Font sizes (px): 12, 14, 15, 16, 17, 18, 20, 22, 24, 26, 28, 32, 36, 42, 48; default 20 — estimated.
- Pages mode: CSS columns one window wide; two columns when the window is ≥ 1000 pt and multiple
  columns are allowed; gap = 2 × margin; default margin 56 pt (estimated).
- Page turns: arrow keys, space, clicks in the outer 12 % of the page, trackpad swipes (70 px of
  scroll), left/right page-turn buttons (`didPressLeft/RightPageTurnButton`).
- Progress = (bytes of chapters before + this chapter × (page+1)/pages) ÷ total bytes.
- "Mark as Finished" appears on the last page (`MarkAsFinishedActionItem` 0x1007fa330).

## Hardcover (api.hardcover.app/v1/graphql; Hardcover.app is a Capacitor wrapper of hardcover.app)
- Requests need `Authorization: Bearer <token>` (observed: "No Authorization header" without it).
- Status ids: 1 Want to Read, 2 Currently Reading, 3 Read, 4 Paused, 5 Did Not Finish — 4 is estimated.
- Progress sent on closing a linked book: pages = round(progress × Hardcover page count).
- Writes are spaced 1.1 s apart when copying Goodreads shelves (Hardcover limit ≈ 60 requests/min).

## Goodreads
- Read: PirateReads `GET https://api.piratereads.com/{user_id}/{currently-reading|read|want-to-read|dnf}`
  with `per_page` (1–30) and `page`; `count` is the size of the returned page.
- Write: Goodreads has no public API since 2020, so Folio exports a Goodreads-format CSV (Title, Author,
  ISBN, ISBN13, My Rating, …, Exclusive Shelf) and imports Goodreads' own export CSV.

## Book source extensions (default: demeter, github.com/gnur/demeter)
- Each source is a JavaScript file defining `var source = { id, name, settings, search, recent, sync }`,
  run in its own JavaScriptCore virtual machine on its own queue. It gets only `folio.fetchText`,
  `folio.fetchJSON`, `folio.log` and a read-only `folio.config`; no file access.
- Network: http(s) only, and only to the hosts listed in that extension's own settings; 30 s timeout,
  20 MB answer limit. Downloads are checked against the same list.
- Built-in Calibre source follows demeter: `/ajax/search?num&offset` for ids (500 per page on a full
  check), `/ajax/books?ids=` in chunks of 50 (demeter's default step size), downloads `main_format`,
  EPUB preferred (demeter's default extension), full check at most every 12 hours per source,
  ids seen earlier are skipped, and books already in the library are matched by author's last name +
  simplified title (demeter's hashBook). First check lists at most 200 books.
- Sources may declare fixed servers with `allowedHosts` (shown under "Can reach" in Settings); the
  person's server list is added to them. Every request an extension causes, including downloads, goes
  through its own cookie-less session that refuses redirects to servers outside that list.
- Built-in sources: Calibre Libraries (demeter) and Project Gutenberg (Gutendex API, gutenberg.org
  downloads; Calibre ships a Gutenberg store too). Calibre's Python store plugins aren't run, and the
  Anna's Archive plugin isn't supported because it serves books without the rights holders' permission.
