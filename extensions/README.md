# Folio book source extensions

## Open sources: Wikisource, Internet Archive and OAPEN

These three are bundled with iOS builds and switched on by default. All three serve books that are free to download, need no account, and go through Folio's encrypted DNS like every other source.

- **Wikisource** (`wikisource.js`) searches the Wikisource edition in the language the book is wanted in (29 languages, from `en.wikisource.org` to `hu.wikisource.org`) and reads each work's title, author and year from the page header. The EPUB comes from Wikisource's own export tool at `ws-export.wmcloud.org`, the same one behind its OPDS feeds and Download links. A language with no Wikisource edition is skipped without a request.
- **Internet Archive** (`internet-archive.js`) searches texts by title and author surname, only among items with an open EPUB or text PDF. Borrow-only (lending library) items and LCP/ACS-encrypted files are never offered. The item's file list decides the file, and an EPUB the uploader supplied wins over one the archive generated from page scans. Results in another known language are dropped before Folio's own language check.
- **OAPEN** (`oapen.js`) searches the OAPEN Library's open-access academic books through its public REST API and offers each item's EPUB and PDF files from `library.oapen.org`.

`node checks/test-open-sources-extensions.cjs` checks the three parsers, requests and download links without network access.

## Library Genesis

`libgen.js` is bundled but switched off until the person turns it on. On Folio 1.0.114 and later its first search asks every official mirror (`libgen.li`, `.gl`, `.vg`, `.la`, `.bz`) at once, keeps the first that answers within 12 seconds and uses it for the rest of the job; older Folio versions try them in order. A mirror that answers 403 or a challenge page is skipped. When every mirror is blocked, the search fails with one clear message that names each mirror's answer, and the other sources carry on. `node checks/test-libgen-extension.cjs` covers parsing, link validation and mirror failover.

## Lectulandia (Spanish)

`lectulandia.js` is an optional Spanish-language (`es`) source for the Lectulandia catalogue. Install it from **Settings → Sources → Add Extension from File…**. iOS builds also bundle it automatically.

The source searches titles and authors, includes covers, and reads the site's published EPUB and PDF links. It uses the two currently verified matching Lectulandia catalogues at `ww3.lectulandia.com` and `ww3.lectulandia.co` in failover order, publishing both download URLs as alternatives so Folio can retry the transfer through the second mirror. Older Lectulandia-looking domains were deliberately excluded because they do not currently provide the same verified catalogue. No account or credentials are required.

The EPUB/PDF links lead first to HTML download pages. Folio follows the site's normal background countdown to the published Antupload download page, then resolves the visible **DOWNLOAD NOW** link. The importer still checks the actual EPUB/PDF file signature. A public-domain *Don Quijote* sample confirmed that the final Antupload file endpoint can serve an EPUB; a working response is not guaranteed for every record or network.

Source extensions declare their supported language codes (`languages: ["es"]` for Lectulandia, `languages: ["*"]` for multilingual sources). Folio shows the language in the source picker and installed extension settings, and skips single-language sources during automatic searches for other languages. Individual EPUB languages are still independently verified at import.

`node checks/test-lectulandia-extension.cjs` checks the HTML parser, language filtering, recognized download links, approved final link and automatic mirror fallback without external network requests or downloading a book.

## Anna's Archive (Free)

Install **`annas-archive.js`** in Folio with **Settings → Sources → Add Extension from File…**. The script is an independent JavaScript source; it does not bundle Calibre/Python code, Anna's Archive source, credentials, paid API calls, or third-party book providers.

After using **Find Source**, open the **Downloading** sidebar section to see the current stage, mirror checks, free-partner wait estimates, and the Activity log with any server errors. You can navigate elsewhere while Folio searches/downloads. Folio saves the queue on disk and retries interrupted jobs after the next launch. When a free partner supplies a countdown page, Folio now waits on the background browser page for its published final file link rather than immediately importing the HTML landing page as an EPUB.

Folio's new offscreen WebKit engine (see [`BROWSER_API.md`](BROWSER_API.md)) lets a source navigate ordinary browser challenges automatically, inspect rendered HTML, and run page JavaScript. It shows **no** browser window. WebKit's built-in content rule lists block common advertising and tracking requests. This is **not** the uBlock Origin extension: WKWebView cannot load browser extensions.

The extension uses GitHub's `guillem-gelabert/annas-mcp` `OFFICIAL_MIRRORS` declaration (cached) and a restrictive local fallback allowlist `.gl`, `.pk`, `.gd`. It first tries Folio's normal network request, then retries blocked pages in its private browser. It parses both Anna's Archive's current search-table layout and its older card layout, then discovers **published free Slow Partner links** on record pages.

## Confirmed live results on November 20, 2026

- **Search works in the background browser.** A real query for *Pride and Prejudice* by Jane Austen returned EPUB rows and resolved 12 published free-partner options after passing the normal JavaScript browser check. `.gl` and `.pk` served rendered search pages; `.gd` was unreachable on this Mac.
- **A genuine anonymous free EPUB transfer was verified for a public-domain sample.** From the official `.gl` mirror's *Pride and Prejudice* record (file MD5 `dba7a9943ea918a5afd2b170527fca13`), normal offscreen WebKit navigation opened `/slow_download/<md5>/0/0`, waited for the published countdown, and allowed the site's own JavaScript to reload the page. The resulting page contained a real **Download now** link on `b4mcx2ml.net`, a partner download server linked by the official page. A real anonymous GET to that exact published link returned HTTP 200, **278,472 bytes**, EPUB ZIP signature and the exact expected MD5. No key, account, paid API or second catalogue was used. This is a live result for one public-domain edition, **not** a guarantee that every book or server will work.
- **Folio now distinguishes landing pages from real files.** Version 1.3.2 implements `source.prepareDownload(url)`, waits inside the already-running WebKit session, extracts the final published HTTPS file link and returns it to Folio. The partner host is explicitly allowlisted; other external hosts remain blocked. Folio's downloader verifies the file signature and EPUB metadata before importing. Site-controlled waits may be extended, reset or fail, which the Downloading page reports as a source error.
- **Full signed Folio.app download and import passed at 00:52 local time on November 20, 2026.** An isolated Downloading queue used the genuine official free-partner URL for the public-domain Austen file and the unmodified Anna `prepareDownload` hook. It waited through the live countdown, received the published `b4mcx2ml.net` file URL, fetched the EPUB with Folio's own URLSession, imported it, verified title and author, and marked the job Completed. The imported file was **278,472 bytes**, with **MD5 `dba7a9943ea918a5afd2b170527fca13`**. The test pins the already verified public-domain book record to avoid spending time searching unrelated editions; search and record rendering were tested separately on the live site. No account or fast API was involved.
- **No CAPTCHA bypass, keys, payment, membership, third-party catalog, or fraudulent mirrors.** Restrictions and waiting mechanisms imposed by the source remain in place. If a free EPUB can be downloaded by hand, it can still be imported into Folio normally.

## Regression checks

`node checks/test-source-failures-sandbox.cjs` replays the source failures from a real phone log (stalled mirrors, 403 refusals, TLS and DNS failures) against every bundled source on a simulated network and prints how long each takes before and after mirror racing.


From the project root, run `node checks/test-anna-folio-extension.cjs`, `swift checks/test-anna-jscore.swift`, and `swift build -c debug` in `app/`. The browser probe uses the Swift source at `app/Core/ExtensionBrowser.swift` and a local HTTP fixture. The live integration probe `checks/test-anna-runtime.swift` can compile against Folio's exact `SourceRuntime`, but requires external Anna's Archive availability and is not an offline pass/fail indicator for a real EPUB.
