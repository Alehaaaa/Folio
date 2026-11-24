# Goodreads Lab

An independent macOS test app for Goodreads account read/write exploration.
It does not import or change Folio's library, credentials, or integration.

## Build and launch

From `checks/goodreads-lab`:

```sh
./build.sh
open .build/GoodreadsLab.app
```

Requires Xcode with Swift 6 and macOS 13 or newer. The built app is excluded
from source control. Run `node test-bridge.mjs` and `node test-recorder.mjs`
for offline request and recorder tests.

## Record a reproducible Goodreads interaction

The lab now has a persistent **Start Recording** / **Stop & Save Recording**
control at the top of the sidebar. Sign in before starting, then:

1. Click **Start Recording**.
2. Open Goodreads **Home**, click the actual **Update progress** button and
   interact with the page as usual. You can navigate to My Books and back.
3. Click **Stop & Save Recording**. A JSON file is written to
   `checks/goodreads-lab/.build/recordings/goodreads-<timestamp>-<id>.json`,
   and Finder opens with that file selected. This folder is within the shared
   repository workspace and excluded from Git, so the coding agent can read it.
4. Share that file for inspection. It identifies clicked HTML elements,
   form controls, DOM changes including dialogs, JavaScript errors, dynamic
   JavaScript execution markers, script/resource URLs, navigation, fetch/XHR
   requests, response status codes and response times. It also records safe
   fields such as the book ID and numerical reading percentage when present.

Recording does not collect passwords, authentication tokens, cookies, entered
review text, HTTP headers or full request/response bodies. Executed JavaScript
is represented by script URLs, dynamic-execution markers and runtime errors;
WebKit cannot reliably provide a full instruction-by-instruction trace from
page JavaScript. The recorder carries events into the native app as they occur
so ordinary page navigation does not discard the session.

## Manual account test

1. Click **Sign In** and log into your own Goodreads account in the embedded
   browser. This app has a separate WebKit session from Folio. Return to the
   Goodreads homepage using **Home** when signed in.
2. **Refresh** loads the Goodreads **All Books** shelf (including titles on
   custom shelves) into a single Book dropdown, automatically selecting the
   first available book. The dropdown shows titles and authors; the selected
   book's underlying Goodreads ID is displayed for diagnostics. Goodreads
   sign-in landing on Home triggers an initial refresh automatically. If the
   All shelf is not available, the lab falls back to the four exclusive
   shelves. The number of books can be capped by the six-page fetch limit.
   You can change the profile ID in **Diagnostics & account**.
3. Choose the desired title from **Book**, then select a shelf and click the
   **Update** button beside Shelf status.
   Confirm the write. The **GraphQL (current site)** mode authenticates through
   `GET /authenticate`, then uses the website's `ShelveBook` mutation on the
   Goodreads AppSync backend, requiring the response to echo the requested
   shelf. It supports Want to Read, Currently Reading, and Read. The **Classic
   form** mode tests `POST /shelf/add_to_shelf` and checks the shelf HTML; use
   this mode to experiment with Did Not Finish. For status tests, prefer a test
   book that you can safely move among shelves.
4. To test reading progress, set that book to **Currently Reading**, choose
   **%** or **Pages**, enter the number, then click **Update** and confirm.
   The app sends `POST /user_status.json` with `user_status[percent]` for
   percentages or `user_status[page]` for page numbers. Both forms are supported
   by captured authenticated Goodreads interactions. HTTP 200 indicates the
   server accepted the update; the app reports whether the response also
   confirms the saved value. If it does not, verify on the Goodreads website.

## Investigating the Home progress popup

Goodreads Home has its own "Currently Reading" panel with progress bars and
an **Update progress** popup. Expand **Diagnostics & account** and click
**Inspect Home** to enumerate the book cards and any visible percentages. Click
**Update progress** in the embedded website (do not submit yet), then click
**Inspect Progress Popup** to list its form control names and action
without exporting any entered notes, password, cookies or CSRF values. The
**Inspect Traffic** button displays the methods, paths,
status codes and field names recorded from the embedded web page. It excludes
headers, cookies, CSRF tokens and entered note values. Recorded signed-in
Goodreads interactions confirmed `/user_status.json` for both page and percent
updates.

The log reports HTTP statuses and verification outcomes without printing
session cookies or CSRF tokens. A 2xx response by itself does not prove that
Goodreads persisted a write. For a first live test, compare the affected book
in the normal Goodreads website after each change.

## Request contract being evaluated

| Operation | Website route | Details |
| --- | --- | --- |
| Read shelves | `GET /review/list/{userID}?shelf=all` | Builds the book dropdown from all shelved titles; fallback to individual exclusive shelves |
| Read book | `GET /book/show/{bookID}` | Reads public metadata and any visible progress |
| Read active progress | `GET /home/load_reading_sessions` | Parses authenticated reading-session JSON, exposing recognizable positions and percentages |
| Set shelf (current) | `GET /authenticate`, `POST Goodreads AppSync /graphql` | Authenticated `ShelveBook` mutation; must confirm returned shelf |
| Set shelf (classic) | `POST /shelf/add_to_shelf` | Form fields `book_id`, `name`, `a`, CSRF token |
| Set progress | `POST /user_status.json` | Form fields `user_status[book_id]`, either `[percent]` or `[page]`, `[body]`, CSRF token |

These website endpoints are unofficial and may change without notice.
Goodreads' published legacy API no longer issues new developer keys. The
application relies on the website's own authenticated cookies and CSRF token,
which remain inside the embedded WebKit browser. For GraphQL operations, an
in-memory JWT from Goodreads `/authenticate` is sent only to Goodreads' own
AppSync GraphQL host and is never returned to Swift or written to disk.

## Scope and limits

This is a manual test app, not a production sync. It never silently modifies
books. A bookshelf that exceeds six 100-item pages is flagged as truncated.
Some bookshelf and progress data require an authenticated session, and some
progress details may be loaded by client-side JavaScript and absent from the
raw HTML response. The application reports those limits rather than inventing
book statuses or percentages. Do not commit credentials, captured headers, or
account-specific HTML fixtures.
