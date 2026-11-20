# Folio background browser for source extensions

Folio provides an offscreen, per-extension `WKWebView` backed by macOS WebKit. It runs page JavaScript, waits for automatic navigation to settle, and exposes a small synchronous API through the isolated JavaScriptCore extension runtime. **No browser window is shown.** No Selenium, Playwright, Chromium, external browser process, permanent browser profile, or user-supplied extension code is bundled.

Extensions can use `folio.browser.open(url)` to navigate and return rendered HTML; `folio.browser.html()` to read the current document; `folio.browser.evaluate(script)` to execute document JavaScript and receive a text result; `folio.browser.url()` to inspect the current address; `folio.browser.waitFor(cssSelector)` to wait up to 15 seconds for an element (returns the string `"true"` or `"false"`); and `folio.browser.close()` to destroy the private browser session. A source may use `.evaluate()` for ordinary DOM interactions such as filling a search field or clicking a link. All operations run off the extension's worker queue and return bounded errors, without a visible browser UI.

The browser has an **ephemeral, per-extension session**. Top-level navigation and redirects stay on the extension's declared `allowedHosts`, never arbitrary file URLs, browser pop-ups or new tabs. WebKit content rules block undeclared third-party network resources and common advertising/tracker domains, and hide conventional ad widgets. The rules are native WebKit privacy filtering; **uBlock Origin itself cannot be loaded in WKWebView**. Some sites may fail when they require subresources hosted outside the extension's allowed servers.

Example extension function:

```javascript
var source = {
  id: "example-source",
  name: "Example",
  version: "1",
  description: "Example background browser source",
  allowedHosts: ["https://example.org"],
  settings: [],
  search: function (query, page) {
    var url = "https://example.org/search?q=" + encodeURIComponent(query);
    var html = folio.browser.open(url);
    // The extension parses HTML and returns Folio SourceResult records.
    return [];
  },
  recent: function () { return []; }
};
```

The browser is available to source search and sync methods, including methods that future in-app automations can invoke. It is **not** a standalone automation scheduler or a promise to solve interactive CAPTCHAs, bypass access controls, or obtain files from arbitrary partner hosts. The extension contract still permits downloads only from its approved origins. A WebKit-rendered download landing page is not itself an EPUB file.

### Optional delayed free-download hook

When `source.search()` returns a `downloads: [{format:"epub", url:"..."}]` entry that points to an **HTML landing page** rather than a file, an extension may define `source.prepareDownload(landingPageURL)`. Folio calls this function on the extension's isolated worker only when that candidate is selected. The function can use the existing WebKit session, wait on the published page, inspect its final download link, and return the actual HTTPS file URL as a string. Folio independently checks the returned URL against the extension's approved hosts, transfers the verified browser cookies only to that approved host, enforces redirect restrictions and confirms the downloaded bytes are an EPUB ZIP signature rather than HTML. The extension must not invent a file URL or return the landing page as if it were an EPUB.

The Anna's Archive extension uses this hook for its published free-partner countdown and page-generated file link. A server may extend the waiting period or decline to issue a file; in that case the job reports the source's limitation rather than a false successful import.

## Source status and diagnostics

The extension runtime also supplies two callbacks. Use `folio.status("Searching mirror…")` for a concise line to display in Folio's Downloading queue, and `folio.log("mirror.example: detailed error reason")` for an entry in the selected book's expandable activity log. Both callbacks are safe to call during `source.search`, `source.recent`, or `source.sync`; the queue records status messages only during a queued operation and stores the latest 120 log entries per book.

When multiple editions are returned, the background queue first requires an exact normalized title and author match and prefers EPUB. Optionally include `downloadCount: 245` in an individual source result if the source provides an actual provider-reported count; Folio compares these counts only between results from the same source. The number of alternative URLs in `downloads` is **not** a popularity metric. Folio tries matching candidates in order, verifies the imported EPUB's own metadata, and records errors if a link is blocked or serves HTML instead of a real book.

## Background Downloading queue

The queue is stored at `<Folio data directory>/download-queue.json`. Find Source adds a job without blocking navigation, and the Downloading sidebar shows queued/searching/selecting/downloading/importing/completed/failed/cancelled states. The user can inspect detailed errors, cancel, retry, dismiss or read a completed file. Queued and in-progress jobs are requeued after relaunch; the app must remain running for downloads to progress (there is no privileged background agent after quitting Folio).
