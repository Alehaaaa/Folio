// This script runs in Goodreads' own WKWebView page. It uses the signed-in
// browser's cookies and CSRF token; no cookies or credentials leave the view.
// The script is intentionally separate from Folio and has no background jobs.
return await (async () => {
  "use strict";
  const base = "https://www.goodreads.com";
  const input = payload || {};
  const allowedShelves = new Set(["to-read", "currently-reading", "read", "did-not-finish"]);
  if (location.origin !== base) {
    throw new Error("Open www.goodreads.com in the browser before using the lab.");
  }

  const numericID = (value, name) => {
    const original = String(value || "").trim();
    // Goodreads profile links retain a slug after the numeric user ID.
    const fromLink = original.match(/^https:\/\/(?:www\.)?goodreads\.com\/(?:review\/list|user\/show)\/(\d+)(?:[-/?#]|$)/i);
    const id = fromLink?.[1] || original;
    if (!/^\d{1,20}$/.test(id)) throw new Error(`${name} must contain digits only.`);
    return id;
  };
  const safeShelf = value => {
    if (!allowedShelves.has(value)) throw new Error("Unknown Goodreads shelf.");
    return value;
  };
  const clean = value => String(value || "").replace(/\s+/g, " ").trim();
  const absolute = path => {
    const url = new URL(path, base);
    if (url.origin !== base) throw new Error("Refusing a request outside Goodreads.");
    return url;
  };
  const timeoutMS = 20000;

  async function request(path, options = {}) {
    const url = absolute(path);
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), timeoutMS);
    try {
      const response = await fetch(url.href, {
        credentials: "same-origin",
        redirect: "follow",
        signal: controller.signal,
        ...options,
      });
      const finalURL = new URL(response.url);
      if (finalURL.origin !== base) throw new Error("Goodreads redirected outside its website. Sign in again.");
      if (/\/(user\/sign_in|ap\/|user\/sign_up)/.test(finalURL.pathname)) {
        throw new Error("Goodreads requires a signed-in browser session.");
      }
      if (response.status === 202 || response.status === 405) {
        throw new Error(`Goodreads requested a browser verification (HTTP ${response.status}).`);
      }
      if (response.status === 401 || response.status === 403) {
        throw new Error(`Goodreads rejected the session or CSRF token (HTTP ${response.status}).`);
      }
      const body = await response.text();
      if (/name=["']password["']/.test(body) && /sign.in/i.test(body.slice(0, 2500))) {
        throw new Error("Goodreads returned its sign-in page. Please sign in.");
      }
      return {code: response.status, ok: response.ok, text: body, url: finalURL.href,
        contentType: response.headers.get("content-type") || ""};
    } finally {
      clearTimeout(timer);
    }
  }

  function parseHTML(html) { return new DOMParser().parseFromString(html, "text/html"); }
  function csrfFrom(doc) {
    return doc.querySelector('meta[name="csrf-token"]')?.getAttribute("content") ||
      doc.querySelector('input[name="authenticity_token"]')?.getAttribute("value") || null;
  }
  async function csrfToken() {
    const here = csrfFrom(document);
    if (here) return here;
    const home = await request("/");
    const fresh = csrfFrom(parseHTML(home.text));
    if (!fresh) throw new Error("No Goodreads CSRF token found in the signed-in page.");
    return fresh;
  }
  async function sendForm(path, values) {
    const token = await csrfToken();
    const form = new URLSearchParams(values);
    // Goodreads' classic Rails pages expect this token either as a meta header
    // or a form field. Sending both is harmless for the same-origin request.
    form.set("authenticity_token", token);
    const response = await request(path, {
      method: "POST",
      headers: {
        "Content-Type": "application/x-www-form-urlencoded; charset=UTF-8",
        "X-CSRF-Token": token,
        "X-Requested-With": "XMLHttpRequest",
        "X-Prototype-Version": "1.7",
        "Accept": "application/json, text/javascript, text/html, */*",
      },
      body: form.toString(),
    });
    if (!response.ok) throw new Error(`Goodreads rejected ${path} (HTTP ${response.code}).`);
    if (/^\s*<!DOCTYPE html/i.test(response.text) &&
        /<title[^>]*>\s*(sign in|error)/i.test(response.text)) {
      throw new Error(`Goodreads returned an error page for ${path}.`);
    }
    let json = null;
    if (response.contentType.includes("json") || response.text.trim().startsWith("{")) {
      try { json = JSON.parse(response.text); } catch { /* Some classic responses are JavaScript or HTML. */ }
    }
    return {code: response.code, contentType: response.contentType, json};
  }

  const bookIDFrom = link => {
    const match = (link || "").match(/\/book\/show\/(\d+)/);
    return match?.[1] || null;
  };
  function parseShelf(html, shelf) {
    const doc = parseHTML(html);
    const rows = Array.from(doc.querySelectorAll('tr[id^="review_"], tr.bookalike, tr[id^="book_review_"]'));
    const seen = new Set();
    const books = [];
    for (const row of rows) {
      const link = row.querySelector('td.field.title a[href*="/book/show/"], a.bookTitle[href*="/book/show/"], a[href*="/book/show/"]');
      const id = bookIDFrom(link?.getAttribute("href"));
      if (!id || seen.has(id)) continue;
      seen.add(id);
      const title = clean(link?.getAttribute("title") || link?.textContent || row.querySelector(".field.title")?.textContent);
      const author = clean(row.querySelector('td.field.author, td.field.author a, .authorName')?.textContent);
      const pagesText = row.querySelector('td.field.num_pages, td.field.num-pages')?.textContent || "";
      const ratingText = row.querySelector('td.field.rating .staticStars, td.field.rating')?.textContent || "";
      // An HTML shelf often omits progress entirely. Never invent a percentage.
      const progressElement = row.querySelector('[data-testid="reading-progress"], .readingProgress, [data-progress-percent]');
      const value = progressElement?.getAttribute("data-progress-percent") || progressElement?.textContent || "";
      const match = value.match(/(\d{1,3})\s*%/);
      const percent = match && Number(match[1]) <= 100 ? Number(match[1]) : null;
      const shelvesText = clean(row.querySelector('td.field.shelves, td.field.shelf')?.textContent || "").toLowerCase();
      const primaryShelf = shelf === "all"
        ? (["currently-reading", "to-read", "read", "did-not-finish"].find(name =>
            shelvesText.split(/[\s,]+/).includes(name)) || "")
        : shelf;
      books.push({id, title, author, shelf: primaryShelf, pages: Number.parseInt(pagesText, 10) || null,
        rating: clean(ratingText).slice(0, 30), percent});
    }
    const next = doc.querySelector('a.next_page[href], a[rel="next"][href]')?.getAttribute("href") || null;
    return {books, next};
  }

  async function shelfBooks(uid, shelf, maxPages = 6) {
    let path = `/review/list/${uid}?shelf=${encodeURIComponent(shelf)}&per_page=100&sort=date_added&order=d`;
    const seenPaths = new Set();
    const byID = new Map();
    let pages = 0;
    let truncated = false;
    while (path && pages < maxPages) {
      if (seenPaths.has(path)) break;
      seenPaths.add(path);
      const response = await request(path);
      if (!response.ok) throw new Error(`Could not read the ${shelf} shelf (HTTP ${response.code}).`);
      const parsed = parseShelf(response.text, shelf);
      for (const book of parsed.books) byID.set(book.id, book);
      pages++;
      if (parsed.next) {
        const nextURL = absolute(parsed.next);
        if (!nextURL.pathname.startsWith(`/review/list/${uid}`)) break;
        path = nextURL.pathname + nextURL.search;
      } else path = null;
      if (path && pages === maxPages) truncated = true;
    }
    return {books: Array.from(byID.values()), pages, truncated};
  }

  async function readShelves(uid, maxPages = 6) {
    // Goodreads' All shelf contains both exclusive and user-created shelves.
    // Fetching it once gives a complete, deduplicated book dropdown.
    const all = await shelfBooks(uid, "all", maxPages);
    if (all.books.length) {
      return {books: all.books, counts: {all: all.books.length},
        truncated: all.truncated ? ["all"] : []};
    }
    // Some legacy profiles hide or transform the All view. Fall back to the
    // four exclusive shelves while still deduplicating book IDs.
    const byID = new Map();
    const counts = {};
    const truncated = [];
    for (const name of allowedShelves) {
      const result = await shelfBooks(uid, name, maxPages);
      for (const book of result.books) if (!byID.has(book.id)) byID.set(book.id, book);
      counts[name] = result.books.length;
      if (result.truncated) truncated.push(name);
    }
    return {books: Array.from(byID.values()), counts, truncated};
  }

  async function bookDetails(id) {
    const response = await request(`/book/show/${id}`);
    if (!response.ok) throw new Error(`Could not read the book (HTTP ${response.code}).`);
    const doc = parseHTML(response.text);
    const title = clean(doc.querySelector('meta[property="og:title"]')?.content ||
      doc.querySelector('h1[data-testid="bookTitle"], h1#bookTitle, h1')?.textContent || doc.title);
    const author = clean(doc.querySelector('[data-testid="name"], a.authorName, .ContributorLink__name')?.textContent);
    const progressNode = doc.querySelector('[data-testid="reading-progress"], [data-progress-percent], .readingProgress');
    const match = (progressNode?.getAttribute("data-progress-percent") || progressNode?.textContent || "")
      .match(/(\d{1,3})\s*%/);
    const graphID = response.text.match(/kca:\/\/book\/[A-Za-z0-9._:-]+/)?.[0] || null;
    return {id, title, author, graphID, percent: match && Number(match[1]) <= 100 ? Number(match[1]) : null,
      url: `${base}/book/show/${id}`};
  }

  async function readingSessions() {
    const response = await request("/home/load_reading_sessions", {
      headers: {"Accept": "application/json, text/javascript, */*", "X-Requested-With": "XMLHttpRequest"},
    });
    if (!response.ok) throw new Error(`Reading sessions unavailable (HTTP ${response.code}).`);
    let json;
    try { json = JSON.parse(response.text); }
    catch { throw new Error("Goodreads did not return JSON reading sessions."); }
    const sessions = [];
    const seen = new Set();
    let visited = 0;
    function walk(value, depth = 0) {
      if (!value || typeof value !== "object" || depth > 8 || ++visited > 2500) return;
      if (Array.isArray(value)) { for (const item of value.slice(0, 500)) walk(item, depth + 1); return; }
      const book = value.book && typeof value.book === "object" ? value.book : null;
      const current = value.currentPosition ?? value.current_position ?? value.progress?.currentPosition ??
        value.progress?.current_position ?? value.page ?? value.pagesRead;
      const total = value.finalPosition ?? value.final_position ?? value.progress?.finalPosition ??
        value.progress?.final_position ?? value.totalPages;
      const percent = value.percent ?? value.percentage ?? value.progressPercent ?? value.progress?.percent ??
        (Number(total) > 0 ? Math.round(100 * Number(current) / Number(total)) : null);
      const id = String(book?.legacyId ?? book?.legacy_id ?? book?.id ?? value.bookId ?? value.book_id ?? "");
      const title = clean(book?.title ?? value.bookTitle ?? value.book_title ?? value.title);
      const position = Number(current);
      const numericPercent = Number(percent);
      if ((book || title) && (current != null || percent != null) &&
          (title || id) && sessions.length < 100) {
        const key = `${id}:${position}:${numericPercent}`;
        if (!seen.has(key)) {
          seen.add(key);
          sessions.push({bookID: id, title, currentPosition: Number.isFinite(position) ? position : null,
            finalPosition: Number.isFinite(Number(total)) && Number(total) > 0 ? Number(total) : null,
            percent: Number.isFinite(numericPercent) && numericPercent >= 0 && numericPercent <= 100
              ? numericPercent : null});
        }
      }
      for (const child of Object.values(value).slice(0, 90)) walk(child, depth + 1);
    }
    walk(json);
    return {sessions, topLevelKeys: json && typeof json === "object" ? Object.keys(json).slice(0, 20) : []};
  }

  function inspectHome() {
    if (location.pathname !== "/" && location.pathname !== "/home") {
      throw new Error("Navigate to Goodreads Home in the embedded browser before inspecting its progress cards.");
    }
    const page = document;
    const cards = [];
    // Goodreads Home's currently-reading card is an older React component,
    // not the book-link structure used on its newer book pages. The actual
    // button has the React key of the legacy book ID in data-reactid.
    const buttons = Array.from(page.querySelectorAll("button,a"))
      .filter(node => /^update progress$/i.test(clean(node.textContent)));
    for (const button of buttons.slice(0, 100)) {
      let container = button;
      for (let i = 0; i < 7 && container?.parentElement; i++) {
        container = container.parentElement;
        const text = clean(container.textContent);
        if (/\b\d{1,3}\s*%/.test(text) &&
            (container.querySelector('a[href*="/book/show/"]') ||
             container.querySelector('img[alt]') || i >= 3)) break;
      }
      const link = container?.querySelector('a[href*="/book/show/"]');
      const react = button.getAttribute("data-reactid") || "";
      const id = bookIDFrom(link?.getAttribute("href")) ||
        react.match(/\$=1\$(\d{4,})/)?.[1] || null;
      if (!id || cards.some(book => book.id === id)) continue;
      const text = clean(container?.textContent);
      const progressText = text.match(/\b(\d{1,3})\s*%/);
      const percent = progressText && Number(progressText[1]) <= 100 ? Number(progressText[1]) : null;
      const image = container?.querySelector("img[alt]");
      const title = clean(link?.getAttribute("title") || link?.textContent || image?.getAttribute("alt") || "");
      cards.push({id, title, percent, hasUpdateButton: true});
    }
    return {cards, totalCards: cards.length, page: location.pathname,
      updateButtons: buttons.length};
  }

  function inspectProgressEditor() {
    // Evidence from the native recorder: Goodreads' Home editor is built
    // from divs and inputs rather than a form or role=dialog element.
    const input = document.querySelector("input.updateReadingProgress__headerInput");
    if (input) {
      const wrapper = input.closest('[class*="updateReadingProgress"]') || input.parentElement?.parentElement;
      const buttons = Array.from(document.querySelectorAll("button.longTextPopupForm__submitButton"));
      return {page: location.pathname, formAction: "/user_status.json (XHR)", controls: [
        {tag: "input", type: input.type, name: input.name || "percent", id: input.id || null,
          label: input.getAttribute("aria-label") || "Reading percentage", percent:
            /^\d{1,3}$/.test(input.value || input.placeholder || "") ? Number(input.value || input.placeholder) : null},
        ...buttons.map(button => ({tag: "button", type: button.type, name: button.name || null,
          id: button.id || null, label: clean(button.textContent), percent: null})),
      ], editorClass: wrapper?.className || null};
    }
    const candidates = Array.from(document.querySelectorAll('form, [role="dialog"], [class*="updateProgress"], [id*="updateProgress"]'))
      .filter(node => /update progress|% done|i.m finished/i.test(node.textContent || ""));
    const editor = candidates.sort((a, b) => a.querySelectorAll("input").length - b.querySelectorAll("input").length)[0];
    if (!editor) throw new Error("Open a Goodreads 'Update progress' popup in the browser first.");
    return {page: location.pathname, formAction: editor.closest("form")?.getAttribute("action") ||
        editor.querySelector("form")?.getAttribute("action") || null,
      controls: Array.from(editor.querySelectorAll("input,textarea,select,button")).slice(0, 30).map(node => ({
        tag: node.tagName.toLowerCase(), type: node.getAttribute("type"),
        name: node.getAttribute("name"), id: node.getAttribute("id"),
        label: clean(node.getAttribute("aria-label") || node.textContent).slice(0, 65),
        // Only reading percentage fields, never password, token, or free-text values.
        percent: /percent|progress/i.test(node.getAttribute("name") || "") &&
          /^\d{1,3}$/.test(node.value || "") ? Number(node.value) : null,
      }))};
  }

  async function graphQLShelf(bookID, shelf) {
    if (shelf === "did-not-finish") {
      throw new Error("The tested Goodreads GraphQL client supports only Want to Read, Currently Reading, and Read.");
    }
    const book = await bookDetails(bookID);
    if (!book.graphID) throw new Error("The book page did not expose a Goodreads GraphQL book ID.");
    const auth = await request("/authenticate", {headers: {"Accept": "application/json, text/plain, */*"}});
    if (!auth.ok) throw new Error(`Goodreads could not authenticate the GraphQL session (HTTP ${auth.code}).`);
    let token = auth.text.trim();
    try { if (token.startsWith('"')) token = JSON.parse(token); } catch { /* plain JWT expected */ }
    if (typeof token !== "string" || token.length < 50 || token === "null" || /[<>\s]/.test(token)) {
      throw new Error("Goodreads /authenticate did not return a usable session token.");
    }
    // Exact AppSync host used by Goodreads' web client and a documented third-party
    // GraphQL prototype. No token is returned to the native app or written to disk.
    const endpoint = "https://kxbwmqov6jgg3daaamb744ycu4.appsync-api.us-east-1.amazonaws.com/graphql";
    const body = {
      operationName: "ShelveBook",
      query: "mutation ShelveBook($input: ShelveBookInput!) { shelveBook(input: $input) { shelving { id legacyId shelf { name displayName } } } }",
      variables: {input: {id: book.graphID, shelfName: shelf}},
    };
    let response;
    try {
      response = await fetch(endpoint, {
        method: "POST", mode: "cors", credentials: "omit",
        headers: {"Content-Type": "application/json", "Accept": "application/json", "authorization": token},
        body: JSON.stringify(body),
      });
    } catch {
      throw new Error("Goodreads GraphQL request failed. Check the browser session or CORS restrictions.");
    }
    if (!response.ok) throw new Error(`Goodreads GraphQL rejected the write (HTTP ${response.status}).`);
    let result;
    try { result = await response.json(); } catch { throw new Error("Goodreads GraphQL returned invalid JSON."); }
    if (result.errors?.length) throw new Error("Goodreads GraphQL: " + clean(result.errors.map(error => error.message).join("; ")));
    const saved = result.data?.shelveBook?.shelving?.shelf?.name || null;
    if (saved !== shelf) throw new Error("Goodreads GraphQL did not confirm the requested shelf.");
    return {ok: true, endpoint: "Goodreads AppSync GraphQL / ShelveBook", httpStatus: response.status,
      verified: true, verification: `GraphQL confirmed the ${saved} shelf.`, bookID, shelf};
  }

  const accountID = () => {
    const navSelectors = [
      '.siteHeader__personal a[href*="/user/show/"]',
      'nav a[href*="/user/show/"]',
      '[data-testid="header-personal-nav"] a[href*="/user/show/"]',
    ];
    for (const selector of navSelectors) {
      const id = document.querySelector(selector)?.getAttribute("href")?.match(/\/user\/show\/(\d+)/)?.[1];
      if (id) return id;
    }
    return null;
  };

  switch (action) {
    case "session":
      return {ok: true, page: location.href, userID: accountID(),
        message: "The Goodreads browser is ready. Sign in, then enter your profile ID if it was not detected."};
    case "readBook":
      return {ok: true, book: await bookDetails(numericID(input.bookID, "Book ID"))};
    case "readProgress":
      return {ok: true, ...(await readingSessions())};
    case "inspectHome":
      return {ok: true, ...inspectHome()};
    case "inspectProgressEditor":
      return {ok: true, ...inspectProgressEditor()};
    case "readShelves":
      return {ok: true, ...(await readShelves(numericID(input.userID, "Profile ID"), 6))};
    case "setStatusGraphQL":
      return await graphQLShelf(numericID(input.bookID, "Book ID"), safeShelf(input.shelf));
    case "setStatus": {
      const bookID = numericID(input.bookID, "Book ID");
      const shelf = safeShelf(input.shelf);
      const write = await sendForm("/shelf/add_to_shelf", {book_id: bookID, name: shelf, a: ""});
      let verified = false;
      let verification = "No profile ID supplied, so automatic shelf verification was skipped.";
      if (input.userID) {
        const current = await shelfBooks(numericID(input.userID, "Profile ID"), shelf, 6);
        verified = current.books.some(book => book.id === bookID);
        verification = verified ? `Book found on ${shelf} after the write.` :
          "The write returned HTTP success, but the book was not found on the checked shelf pages. Verify in Goodreads.";
        if (current.truncated) verification += " The shelf was truncated.";
      }
      return {ok: true, endpoint: "/shelf/add_to_shelf", httpStatus: write.code,
        verified, verification, bookID, shelf};
    }
    case "setProgress": {
      const bookID = numericID(input.bookID, "Book ID");
      const unit = input.unit == null ? "percent" : input.unit;
      if (unit !== "percent" && unit !== "page") throw new Error("Progress unit must be percent or page.");
      const amount = Number(input.value ?? (unit === "page" ? input.page : input.percent));
      if (!Number.isSafeInteger(amount) || amount < 0 || (unit === "percent" && amount > 100)) {
        throw new Error(unit === "page" ? "Page number must be a non-negative integer." :
          "Reading progress must be an integer from 0 to 100.");
      }
      const write = await sendForm("/user_status.json", {
        "user_status[book_id]": bookID,
        [`user_status[${unit}]`]: String(amount),
        "user_status[body]": "",
      });
      // The contemporary response may itself confirm the saved percentage:
      // {updatedAt, finalPosition: 100, currentPosition: 37, ...}.
      const saved = write.json;
      const savedPosition = Number(saved?.currentPosition);
      const finalPosition = Number(saved?.finalPosition);
      const confirmedPercent = Number.isFinite(savedPosition) && finalPosition > 0
        ? Math.round(100 * savedPosition / finalPosition) : null;
      let observed = unit === "percent" ? confirmedPercent : null;
      if (unit === "page") {
        // Goodreads may return the page in either a user_status payload or
        // its newer reading-session shape. A successful HTTP status alone
        // is not proof the requested page was saved.
        const savedPage = saved?.user_status?.page ?? saved?.userStatus?.page ??
          saved?.page ?? saved?.currentPage ?? saved?.current_page;
        if (savedPage != null && Number.isSafeInteger(Number(savedPage))) observed = Number(savedPage);
      }
      if (unit === "percent" && observed == null) {
        try { observed = (await bookDetails(bookID)).percent; }
        catch { /* A successful write can coexist with unavailable book HTML. */ }
      }
      const verified = observed === amount;
      return {ok: true, endpoint: "/user_status.json", httpStatus: write.code,
        bookID, unit, value: amount,
        ...(unit === "percent" ? {percent: amount, observedPercent: observed} : {page: amount, observedPage: observed}),
        verified,
        verification: verified ? `Goodreads confirmed ${amount} ${unit === "page" ? "pages" : "percent"} in its response.` :
          `Goodreads accepted the ${unit === "page" ? "page" : "percentage"} request, but the response did not independently confirm the saved value. Verify on Goodreads.`};
    }
    default:
      throw new Error("Unknown lab action.");
  }
})();
