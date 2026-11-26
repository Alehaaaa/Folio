// Folio source extension. Independent of Folio's application code and of Calibre.
// Free-only Anna's Archive search and published Slow Partner landing-page links.
// Official mirror list: https://github.com/guillem-gelabert/annas-mcp/blob/main/src/config.ts
// The extension makes no member API requests, uses no accounts and downloads no private code.

var source = {
  id: "annas-archive-free",
  name: "Anna's Archive",
  description: "Free EPUB search and published Slow Partner file delivery after a normal background countdown. No paid API or keys.",
  version: "1.4.1",
  languages: ["*"],
  allowedHosts: [
    "https://raw.githubusercontent.com",
    "https://annas-archive.gl",
    "https://annas-archive.pk",
    "https://annas-archive.gd",
    // Confirmed 2026-11-20 from a genuine official .gl Slow Partner #1 page.
    // Download host only: not an additional catalogue/search provider.
    "https://b4mcx2ml.net"
  ],
  settings: [],

  // Explicit host boundary, independent of anything downloaded from GitHub.
  trustedHosts: ["annas-archive.gl", "annas-archive.pk", "annas-archive.gd"],
  githubList: "https://raw.githubusercontent.com/guillem-gelabert/annas-mcp/main/src/config.ts",
  mirrorCache: null,
  preferredMirror: "",
  failedDetailHosts: {},
  // Short-lived, runtime-local transport failures. Not a permanent judgement
  // about any official mirror, and never persisted across independent jobs.
  mirrorCooldowns: {},
  maxResults: 12,
  // The first search page is asked of every official mirror at once; one
  // that has not answered within this many seconds is treated as down.
  probeSeconds: 15,

  // Folio displays status immediately and retains log entries for diagnostics.
  // Older Folio versions only have folio.log, so status is deliberately optional.
  progress: function (message, detail) {
    if (typeof folio.status === "function") folio.status(message);
    if (typeof folio.log === "function") folio.log(detail || message);
  },

  diagnostic: function (message) {
    if (typeof folio.log === "function") folio.log(message);
  },

  // Attempt the existing network request first; if denied, load the page in
  // Folio's isolated, offscreen WebKit browser. No browser window is displayed.
  fetchPage: function (url) {
    try { return folio.fetchText(url); }
    catch (error) {
      // iOS can briefly return cannotFindHost/networkConnectionLost while its
      // resolver or interface is changing, even though the same host works a
      // moment later. Give that transport request one fresh chance before
      // involving WebKit or condemning the mirror for this source session.
      // Retry only potentially transient DNS/connection failures. Repeating a
      // timeout or a certificate/TLS failure delays the whole search and
      // usually cannot succeed without a change to the network or server.
      // HTTP errors and browser challenges still use normal WebKit fallback.
      var problem = this.transportFailure(error);
      if (problem === "DNS resolution" || problem === "network connection") {
        this.diagnostic("Transient connection failure; retrying direct request once for " + url + ": " + error);
        try { return folio.fetchText(url); }
        catch (retryError) {
          this.diagnostic("Direct retry unavailable for " + url + ": " + retryError);
          error = retryError;
        }
      }
      // WebKit does not solve a failed transport handshake/timeout. Avoid a
      // third blocking attempt per host and move to the next official mirror.
      // Preserve WebKit for HTTP denials and anti-bot pages, which may render.
      if (this.transportFailure(error)) {
        this.diagnostic("Network transport unavailable; skipping redundant browser attempt for " + url + ": " + error);
        throw error;
      }
      if (!folio.browser || typeof folio.browser.open !== "function") {
        this.diagnostic("Direct request unavailable, with no background browser: " + url + ": " + error);
        throw error;
      }
      this.progress("Checking mirror in background browser…",
        "Direct request unavailable; trying regular browser rendering for " + url + ": " + error);
      try {
        return folio.browser.open(url);
      } catch (browserError) {
        this.diagnostic("Background browser could not load " + url + ": " + browserError);
        throw browserError;
      }
    }
  },

  mirrors: function () {
    var now = Date.now();
    if (!this.mirrorCache) {
      var kept = this.recall("mirrors");
      if (kept && kept.hosts && kept.hosts.length) this.mirrorCache = kept;
    }
    if (this.mirrorCache && now - this.mirrorCache.checkedAt < 86400000)
      return this.mirrorCache.hosts.slice();

    this.progress("Refreshing official mirrors…", "Checking the published official mirror declaration.");
    var hosts = this.trustedHosts.slice();
    try {
      var definition = folio.fetchText(this.githubList);
      // Parse just the OFFICIAL_MIRRORS constant, never arbitrary URLs from README text.
      var match = definition.match(/\bOFFICIAL_MIRRORS\s*=\s*\[([^\]]+)\]/);
      if (!match) throw new Error("Official mirror declaration missing");
      var names = match[1].match(/["']annas-archive\.[a-z]{2,}["']/gi) || [];
      var verified = [];
      for (var i = 0; i < names.length; i++) {
        var host = names[i].slice(1, -1).toLowerCase();
        if (this.trustedHosts.indexOf(host) >= 0 && verified.indexOf(host) < 0)
          verified.push(host);
      }
      if (!verified.length) throw new Error("No supported official mirrors in declaration");
      hosts = verified;
      this.diagnostic("Accepted " + hosts.length + " official hosts from the mirror declaration.");
    } catch (error) {
      this.diagnostic("Mirror refresh unavailable; using previously verified official hosts: " + error);
    }
    this.mirrorCache = {checkedAt: now, hosts: hosts};
    this.keep("mirrors", this.mirrorCache, 86400);
    return hosts.slice();
  },

  // Notes kept across download jobs (each job gets a fresh runtime) while
  // Folio runs. Older Folio versions have no folio.recall: nothing is kept.
  recall: function (key) {
    try {
      var text = typeof folio.recall === "function" ? folio.recall(key) : null;
      return text ? JSON.parse(text) : null;
    } catch (e) { return null; }
  },

  keep: function (key, value, seconds) {
    if (typeof folio.remember === "function") folio.remember(key, JSON.stringify(value), seconds);
  },

  // A mirror that just timed out from this network is skipped by the next
  // jobs too (a retry used to wait out the same three timeouts again).
  coolDown: function (host, kind) {
    var seconds = kind === "connection timeout" ? 180 : 60;
    this.mirrorCooldowns[host] = {until: Date.now() + seconds * 1000, kind: kind};
    var shared = this.recall("cooldowns") || {};
    shared[host] = this.mirrorCooldowns[host];
    this.keep("cooldowns", shared, seconds);
  },

  transportFailure: function (error) {
    var message = String(error || "");
    if (/hostname .*could not be found|host(?:name)? .*not found|could not (?:find|resolve) (?:the )?(?:server|host)|name or service not known|dns|nsurlerrordomain.*-1003|\b-1003\b/i.test(message))
      return "DNS resolution";
    if (/secure connection|ssl|tls|certificate|\b-120[0-9]\b|connection reset by peer/i.test(message))
      return "TLS or connection security";
    if (/timed? out|timeout|\b-1001\b/i.test(message))
      return "connection timeout";
    if (/network connection was lost|connection (?:was )?(?:lost|closed|refused|reset)|\b-1005\b|\b-1004\b|\b-1009\b|network is unreachable/i.test(message))
      return "network connection";
    return null;
  },

  // "annas-archive.gl: The request timed out." ×3 reads as
  // "gl, pk, gd: timed out" in the activity log.
  failureSummary: function (failures) {
    var groups = {}, order = [];
    for (var i = 0; i < failures.length; i++) {
      var text = String(failures[i]).replace(/(?:Error: )+/g, "");
      var cut = text.indexOf(": ");
      var host = cut > 0 ? text.slice(0, cut).replace(/^annas-archive\./, "") : "";
      var reason = cut > 0 ? text.slice(cut + 2) : text;
      var kind = this.transportFailure(reason);
      reason = kind === "connection timeout" ? "timed out"
        : kind === "TLS or connection security" ? "secure connection failed"
        : kind === "DNS resolution" ? "address not found" : reason.replace(/\.$/, "");
      if (!groups[reason]) { groups[reason] = []; order.push(reason); }
      groups[reason].push(host);
    }
    return order.map(function (reason) { return groups[reason].join(", ") + ": " + reason; }).join("; ");
  },

  rememberTransportFailure: function (host, error) {
    var kind = this.transportFailure(error);
    if (kind && this.trustedHosts.indexOf(host) >= 0) {
      // A short pause avoids retry storms, across jobs too, while allowing
      // quick recovery once the network changes.
      this.coolDown(host, kind);
      this.diagnostic(host + ": " + kind + " failed; skipping it for a few minutes.");
    }
    return kind;
  },

  orderedMirrors: function () {
    var hosts = this.mirrors();
    if (this.preferredMirror && hosts.indexOf(this.preferredMirror) > 0) {
      hosts.splice(hosts.indexOf(this.preferredMirror), 1);
      hosts.unshift(this.preferredMirror);
    }
    var available = [], now = Date.now();
    var shared = this.recall("cooldowns") || {};
    for (var i = 0; i < hosts.length; i++) {
      var own = this.mirrorCooldowns[hosts[i]], kept = shared[hosts[i]];
      var state = own && kept ? (kept.until > own.until ? kept : own) : (own || kept);
      if (state && state.until > now) {
        this.diagnostic("Skipping " + hosts[i] + " for " + state.kind +
          " (recent connection failure; temporary, not a mirror-list change).");
      } else {
        available.push(hosts[i]);
      }
    }
    return available;
  },

  unescape: function (value) {
    var named = {amp: "&", lt: "<", gt: ">", quot: '"', apos: "'", nbsp: " "};
    return String(value || "").replace(/&(#x[0-9a-f]+|#[0-9]+|[a-z]+);/gi, function (entire, key) {
      key = key.toLowerCase();
      if (key.charAt(0) === "#") {
        var code = key.charAt(1) === "x" ? parseInt(key.slice(2), 16) : parseInt(key.slice(1), 10);
        return code > 31 && code < 65536 ? String.fromCharCode(code) : " ";
      }
      return named[key] || entire;
    });
  },

  plainText: function (html) {
    return this.unescape(String(html || "")
      .replace(/<script\b[^>]*>[\s\S]*?<\/script>/gi, "")
      .replace(/<style\b[^>]*>[\s\S]*?<\/style>/gi, "")
      .replace(/<[^>]+>/g, " ")
      .replace(/\s+/g, " ").trim());
  },

  // The modern Anna table has a dedicated language column. Preserve an
  // explicit, recognizable language only: a title, query, or author's name
  // must never be used as a fallback for an unlabelled edition.
  normalizedLanguage: function (value) {
    var raw = String(value || "").trim().toLowerCase();
    if (!raw || /^(?:unknown|undefined|none|null|n\/a|not specified|unspecified|[-–\u2014?])$/.test(raw))
      return null;
    // Recognize only explicit, unambiguous language names/codes. For example,
    // "French" is not an unknown-language fallback when English was requested.
    var names = {english: "en", german: "de", deutsch: "de", englisch: "en",
      french: "fr", français: "fr", spanish: "es", español: "es",
      italian: "it", italiano: "it", portuguese: "pt", português: "pt",
      russian: "ru", japanese: "ja", korean: "ko", chinese: "zh",
      dutch: "nl", polish: "pl", ukrainian: "uk", turkish: "tr",
      eng: "en", deu: "de", ger: "de", fra: "fr", fre: "fr", spa: "es"};
    if (names[raw]) return names[raw];
    var bracketed = raw.match(/\[([a-z]{2})\]$/);
    if (bracketed) raw = bracketed[1];
    // Anna currently reports ISO-639-1 strings (e.g. en/de); two-letter
    // language subtags from clear regional tags are useful for matching too.
    var code = raw.match(/^([a-z]{2})(?:-[a-z]{2})?$/);
    return code ? code[1] : null;
  },

  // Folio's automatic lookup currently sends "short book title + author surname".
  // Infer that structure only when the search table itself corroborates it:
  // one row must have the trailing query word as a WHOLE author word and start
  // with the preceding title words. Generic free-text searches stay unchanged.
  titleWords: function (value) {
    var folded = String(value || "").toLowerCase();
    if (typeof folded.normalize === "function")
      folded = folded.normalize("NFKD").replace(/[\u0300-\u036f]/g, "");
    return folded.match(/[a-z0-9]+/g) || [];
  },

  lookupIdentity: function (query, cards) {
    var parts = String(query || "").trim().split(/\s+/);
    if (parts.length < 3) return null;
    var surname = parts[parts.length - 1];
    // This is how the native lookup supplies the surname. A mixed-case or
    // unrecognized query is not silently interpreted as title + surname.
    if (!/^[a-z]{3,}$/.test(surname)) return null;
    var title = parts.slice(0, -1).join(" ");
    var titleTokens = this.titleWords(title);
    if (titleTokens.length < 2) return null;
    var self = this;
    var known = cards.some(function (card) {
      return self.titleBeginsWith(card.title, titleTokens) && self.authorHasSurname(card.author, surname);
    });
    return known ? {title: title, words: titleTokens, surname: surname} : null;
  },

  // Native Folio now supplies the *requested* title and author independently
  // of the source query. Trust this explicit intent even if the search returns
  // zero rows (Red God) or the title has only one word (Dune). Never infer an
  // identity from an empty/partial pair; manual searches remain unrestricted.
  expectedIdentity: function (expectedTitle, expectedAuthor) {
    if (typeof expectedTitle !== "string" || typeof expectedAuthor !== "string") return null;
    var title = expectedTitle.trim();
    var author = expectedAuthor.trim();
    if (!title || !author || title.length > 250 || author.length > 180 ||
        /[\u0000-\u001f\u007f]/.test(title + author)) return null;
    var words = this.titleWords(title);
    var authorWords = this.titleWords(author);
    if (!words.length || !authorWords.length) return null;
    // "Brown, Pierce" and "Pierce Brown" must both resolve to Brown. Do not
    // try to infer a surname from ambiguous multi-creator strings.
    var surname = author.indexOf(",") >= 0 ? this.titleWords(author.split(",")[0]).slice(-1)[0]
      : authorWords[authorWords.length - 1];
    if (!surname) return null;
    return {title: title, words: words, surname: surname, authorWords: authorWords};
  },

  titleBeginsWith: function (title, prefixWords) {
    var words = this.titleWords(title);
    if (!prefixWords.length || words.length < prefixWords.length) return false;
    for (var i = 0; i < prefixWords.length; i++) {
      if (words[i] !== prefixWords[i]) return false;
    }
    return true;
  },

  authorHasSurname: function (author, surname) {
    return this.titleWords(author).indexOf(surname) >= 0;
  },

  authorMatchesIdentity: function (author, identity) {
    if (!identity.authorWords) return this.authorHasSurname(author, identity.surname);
    var actual = this.titleWords(author);
    var wanted = identity.authorWords;
    if (!actual.length || !wanted.length || !this.authorHasSurname(author, identity.surname)) return false;
    // Accept a full name in either order, including duplicated creator
    // metadata: "Brown, Pierce Pierce Brown". A surname alone is insufficient.
    function hasSequence(sequence) {
      for (var i = 0; i <= actual.length - sequence.length; i++) {
        var same = true;
        for (var j = 0; j < sequence.length; j++) {
          if (actual[i + j] !== sequence[j]) { same = false; break; }
        }
        if (same) return true;
      }
      return false;
    }
    return hasSequence(wanted) || (wanted.length > 1 && hasSequence(wanted.slice().reverse()));
  },

  // A series subtitle is not the same thing as an abridged, annotated, or
  // adapted edition. Keep its original name so Folio can apply independent
  // identity and embedded-EPUB checks before any automatic read/import.
  // Catalogues keep or drop a leading article: "Camino de los reyes" is
  // "El camino de los reyes". Compare both without it when they differ.
  leadingArticles: ["the", "a", "an", "el", "la", "los", "las", "lo", "le", "les", "l",
    "il", "gli", "der", "die", "das", "o", "os", "as"],

  withoutArticle: function (words, other) {
    if (words.length > 1 && words[0] !== other[0] && this.leadingArticles.indexOf(words[0]) >= 0)
      return words.slice(1);
    return words;
  },

  identityRank: function (card, identity) {
    if (!this.authorMatchesIdentity(card.author, identity)) return -1;
    var titleWords = this.titleWords(card.title);
    var wantedWords = identity.words;
    var bareArticle = false;
    if (titleWords[0] !== wantedWords[0]) {
      bareArticle = true;
      var cardBare = this.withoutArticle(titleWords, wantedWords);
      wantedWords = this.withoutArticle(wantedWords, titleWords);
      titleWords = cardBare;
    }
    if (titleWords.length < wantedWords.length) return -1;
    for (var w = 0; w < wantedWords.length; w++) {
      if (titleWords[w] !== wantedWords[w]) return -1;
    }
    identity = {title: identity.title, words: wantedWords, surname: identity.surname,
      authorWords: identity.authorWords, bareArticle: bareArticle};
    if (titleWords.length === identity.words.length) return 0;
    var remainderWords = titleWords.slice(identity.words.length);
    var remainder = remainderWords.join(" ");
    if (/\b(?:annotated|abridged|adapted|adaptation|summary|sampler|excerpt|companion|study guide|workbook|analysis)\b/i.test(remainder))
      return -1;
    // Aggregated Anna metadata sometimes concatenates multiple aliases in the
    // same title (e.g. two different series numbers or repeated "Iron Gold").
    // That is NOT one clean, trustworthy series label.
    if (remainderWords.length > 8 ||
        remainderWords.some(function (_, at) {
          return identity.words.every(function (word, i) { return remainderWords[at + i] === word; });
        })) return 2;
    // Verified catalogue variants of Gillian Anderson's Want have a published
    // subtitle rather than just "Want". Require BOTH the exact requested
    // author and ONE unmerged subtitle; never trust other Want* books or
    // concatenated aliases from multiple providers.
    if (identity.words.length === 1 && identity.words[0] === "want" &&
        identity.authorWords && identity.authorWords.slice().sort().join(" ") === "anderson gillian" &&
        (remainder === "sexual fantasies by anonymous" || remainder === "submitted by anonymous"))
      return 1;
    // Single unambiguous series label. Avoid treating concatenated alternative
    // titles, collections, or multiple different books as a clean single book.
    if (/^(?:[a-z0-9 ]+ )?(?:series|saga) (?:(?:book|vol|volume) )?(?:[0-9]+|iv|v|vi)$/i.test(remainder) ||
        /^(?:book|vol|volume) (?:[0-9]+|iv|v|vi) of the [a-z0-9 ]+ (?:series|saga)$/i.test(remainder) ||
        /^[a-z0-9 ]+ (?:series |saga )?(?:book|vol|volume) (?:[0-9]+|iv|v|vi)$/i.test(remainder))
      return 1;
    // A numbered series label set apart in brackets or after a colon, as
    // Spanish catalogues write it: "(El Archivo de las Tormentas 1)".
    if (remainderWords.length <= 8 &&
        /^(?:[0-9]+|i{1,3}|iv|v|vi{0,3}|ix|x)$/.test(remainderWords[remainderWords.length - 1]) &&
        /(?:[\(\[][^\(\)\[\]]*[\)\]]|[:#][^:#]*)\s*$/.test(String(card.title || "")))
      return 1;
    // Only an exact title or a clear label may differ by its article: "The
    // Iron Gold Collection" is not "Iron Gold".
    if (identity.bareArticle) return -1;
    return 2; // Ambiguous nearby alias: never make a detail request automatically.
  },

  authorClarity: function (card, identity) {
    // Anna merges provider creators on some cards: e.g. "Brown, Pierce Pierce
    // Brown". Prefer the unambiguous two-word "Pierce Brown" entry first.
    // Do NOT rewrite creator metadata to make a native exact match succeed.
    var tokens = this.titleWords(card.author);
    return tokens.length === 2 && tokens.indexOf(identity.surname) >= 0 ? 0 : 1;
  },

  languageEligible: function (cards, requestedLanguage) {
    if (!requestedLanguage) return cards.slice();
    var matching = [], unknown = [], rejected = 0;
    for (var n = 0; n < cards.length; n++) {
      var listed = this.normalizedLanguage(cards[n].language);
      if (listed === requestedLanguage) matching.push(cards[n]);
      else if (listed === null) unknown.push(cards[n]);
      else rejected++;
    }
    this.diagnostic("Preferred EPUB language " + requestedLanguage + ": " +
      matching.length + " explicit matches first, " + unknown.length +
      " unknown-language fallback(s), " + rejected + " explicit mismatch(es) skipped before detail lookups.");
    return matching.concat(unknown);
  },

  verifyPage: function (html, pageType) {
    if (/\.well-known\/ddos-guard\/js-challenge\/|data-ddg-origin|<title>\s*DDoS-Guard\s*<\/title>|checking your browser|just a moment|attention required|cf-challenge-running/i.test(html))
      throw new Error("The mirror requires verification in a web browser");
    if (/this domain may be for sale|forsale\.min\.js/i.test(html))
      throw new Error("This domain is parked and is not an Anna's Archive mirror");
    if (pageType === "search" && !/(\/md5\/[0-9a-f]{32}|no files found|no results found|no results)/i.test(html))
      throw new Error("Unrecognized search page; possibly a browser check");
    if (pageType === "detail" && !/js-download-link|\/slow_download\//i.test(html))
      throw new Error("The record contains no published free partner links");
  },

  // Parse archive search cards from the older /md5/<hash> layout. The original
  // Calibre plugin depends on an HTML table; cards also work without Python/lxml.
  searchCards: function (html) {
    this.verifyPage(html, "search");
    // Modern search results (Nov 2026) use one row per book and individual
    // columns: cover, title, author, publisher, year, filename, origins,
    // language, type, FORMAT, size. Ignore the unrelated 'recent downloads'
    // marquee preceding the actual results table.
    // CSS class order is not stable across site builds; recognize the same
    // results table regardless of the order of its three class tokens.
    var modernTable = null;
    var tables = /<table\b[^>]*>/gi, opening;
    while ((opening = tables.exec(html)) !== null) {
      var classAttr = opening[0].match(/\bclass\s*=\s*["']([^"']*)["']/i);
      if (!classAttr) continue;
      var classes = " " + classAttr[1].replace(/\s+/g, " ") + " ";
      if (classes.indexOf(" text-sm ") >= 0 && classes.indexOf(" w-full ") >= 0 &&
          classes.indexOf(" h-fit ") >= 0) {
        modernTable = opening;
        break;
      }
    }
    if (modernTable) {
      var begin = html.indexOf(modernTable[0]) + modernTable[0].length;
      var end = html.indexOf("</table>", begin);
      var table = html.slice(begin, end < 0 ? html.length : end);
      var result = [];
      var rows = /<tr\b[^>]*>([\s\S]*?)<\/tr>/gi;
      var row;
      while ((row = rows.exec(table)) !== null) {
        var link = row[1].match(/href=["']\/md5\/([0-9a-f]{32})["']/i);
        if (!link) continue;
        var cells = [];
        var columns = /<td\b[^>]*>([\s\S]*?)<\/td>/gi;
        var cell;
        while ((cell = columns.exec(row[1])) !== null) cells.push(this.plainText(cell[1]));
        if (cells.length < 10 || cells[9].toLowerCase() !== "epub") continue;
        var title = cells[1];
        if (!title || title.length > 250) continue;
        var year = cells[4].match(/\b(?:18|19|20)[0-9]{2}\b/);
        result.push({
          hash: link[1].toLowerCase(), title: title, author: cells[2] || "",
          year: year ? parseInt(year[0], 10) : null,
          language: this.normalizedLanguage(cells[7])
        });
      }
      // A recognized modern results table is authoritative. Falling back to
      // legacy page-wide anchors can include unrelated marquee/sidebar books
      // when none of the actual result rows is an EPUB.
      return result;
    }
    var links = [];
    var pattern = /<a\b[^>]*href\s*=\s*["'](?:https?:\/\/[^\/"']+)?\/md5\/([0-9a-f]{32})["'][^>]*>/gi;
    var match;
    while ((match = pattern.exec(html)) !== null) {
      links.push({hash: match[1].toLowerCase(), at: match.index});
    }
    // Resolve each link's next distinct record in one backward pass, rather
    // than scanning all later anchors for every duplicate hash (quadratic on
    // large result pages with repeated title/cover/download anchors).
    var nextDistinct = new Array(links.length);
    for (var k = links.length - 1; k >= 0; k--) {
      nextDistinct[k] = k + 1 >= links.length ? html.length :
        (links[k + 1].hash !== links[k].hash ? links[k + 1].at : nextDistinct[k + 1]);
    }
    var records = [];
    var seen = {};
    for (var i = 0; i < links.length; i++) {
      var id = links[i].hash;
      if (seen[id]) continue;
      seen[id] = true;
      var next = nextDistinct[i];
      var block = html.slice(links[i].at, Math.min(next, links[i].at + 20000));
      var title = "";
      var anchorPattern = /<a\b([^>]*)>([\s\S]*?)<\/a>/gi;
      var anchor;
      while ((anchor = anchorPattern.exec(block)) !== null) {
        if (anchor[1].toLowerCase().indexOf("/md5/" + id) < 0) continue;
        var proposed = this.plainText(anchor[2]);
        if (proposed && proposed.length > title.length && proposed.length < 250) title = proposed;
      }
      if (!title) continue;
      var author = "";
      var authorTag = block.match(/<a\b[^>]*href=["'][^"']*\/search[^"']*["'][^>]*>[\s\S]*?mdi--user-edit[\s\S]*?<\/a>/i);
      if (authorTag) author = this.plainText(authorTag[0]);
      var meta = block.match(/<div\b[^>]*class=["'][^"']*text-gray-800[^"']*["'][^>]*>([\s\S]*?)<\/div>/i);
      var info = meta ? this.plainText(meta[1]) : "";
      var format = info.match(/\b(epub|pdf|mobi|azw3|cbz|txt)\b/i);
      if (!format || format[1].toLowerCase() !== "epub") continue;
      var year = info.match(/\b(?:18|19|20)[0-9]{2}\b/);
      records.push({
        hash: id, title: title, author: author,
        year: year ? parseInt(year[0], 10) : null,
        language: null // Older cards have no reliable dedicated language cell.
      });
    }
    if (!records.length && !/no files found|no results found|no results/i.test(html))
      throw new Error("The site changed its search layout or returned a verification page");
    return records;
  },

  // Extract published free landing-page links, never generate guessed paths.
  // These URLs can return verification or countdown HTML instead of EPUB bytes.
  slowLinks: function (html, hash, baseURL) {
    this.verifyPage(html, "detail");
    var links = [];
    var anchors = /<a\b[^>]*>/gi;
    var tag;
    while ((tag = anchors.exec(html)) !== null) {
      if (!/\bjs-download-link\b/i.test(tag[0])) continue;
      var attr = tag[0].match(/\bhref\s*=\s*["']([^"']+)["']/i);
      if (!attr) continue;
      var path = this.unescape(attr[1]);
      var required = new RegExp("^/slow_download/" + hash + "/[0-9]+/[0-9]+(?:\\?.*)?$", "i");
      if (!required.test(path)) continue;
      var url = baseURL + path;
      if (!links.some(function (item) { return item.url === url; }))
        links.push({format: "epub", url: url});
    }
    return links;
  },

  resolveFreeEPUB: function (hash, firstHost) {
    var hosts = this.orderedMirrors();
    if (firstHost && hosts.indexOf(firstHost) > 0) {
      hosts.splice(hosts.indexOf(firstHost), 1);
      hosts.unshift(firstHost);
    }
    for (var i = 0; i < hosts.length; i++) {
      var host = hosts[i];
      // Avoid repeating a failed challenge/timeout for every search hit.
      if (this.failedDetailHosts[host]) continue;
      try {
        var origin = "https://" + host;
        this.diagnostic("Loading public record metadata from " + host + " for " + hash + ".");
        var html = this.fetchPage(origin + "/md5/" + hash);
        this.progress("Checking published free download options…",
          "Inspecting the record's published Slow Partner paths for " + hash + ".");
        var links = this.slowLinks(html, hash, origin);
        if (links.length) {
          this.preferredMirror = host;
          this.diagnostic("Found " + links.length + " free landing-page link(s) on " + host + "; EPUB transfer not verified.");
          return links;
        }
      } catch (error) {
        // A valid detail page without a published free link (or one missing
        // MD5) says nothing about other editions on this host. Do not poison
        // the entire mirror cache based on one book's availability.
        var detailError = String(error);
        var recordOnly = /record contains no published free partner links|answered 404|answered 410/i.test(detailError);
        if (!recordOnly) {
          this.failedDetailHosts[host] = true;
          this.rememberTransportFailure(host, error);
        }
        this.diagnostic(host + (recordOnly ? " record has no published accessible free link: "
          : " free record unavailable: ") + error);
      }
    }
    this.diagnostic("No accessible published free landing-page links for " + hash + ".");
    return [];
  },

  // Read only an advertised countdown estimate. Do not wait, reload, click, or
  // interact with a verification challenge. Numbers are advisory, not promises.
  partnerWaitSeconds: function (html) {
    var text = String(html || "");
    var data = text.match(/\b(?:waitSeconds|wait_seconds)\s*[:=]\s*([0-9]{1,6})\b/i);
    var seconds = data ? Number(data[1]) : NaN;
    if (!isFinite(seconds)) {
      var words = this.plainText(text).match(/\b(?:please\s+)?wait\s+(?:for\s+)?(?:about\s+|approximately\s+)?([0-9]{1,5})\s*(seconds?|minutes?|hours?)\b/i);
      if (words) {
        var factor = /^hour/i.test(words[2]) ? 3600 : /^minute/i.test(words[2]) ? 60 : 1;
        seconds = Number(words[1]) * factor;
      }
    }
    return isFinite(seconds) && seconds > 0 && seconds <= 86400 ? seconds : null;
  },

  waitLabel: function (seconds) {
    if (seconds < 120) return Math.ceil(seconds) + " sec";
    if (seconds < 7200) return Math.ceil(seconds / 60) + " min";
    return Math.ceil(seconds / 3600) + " hr";
  },

  // Check at most ONE known official free landing page for an estimate; the
  // browser may not expose one. Never retry or reload, which can reset a queue.
  inspectPartnerWait: function (download) {
    if (!download || !folio.browser || typeof folio.browser.open !== "function") return null;
    this.progress("Checking free partner wait estimate…",
      "Reading a published free partner landing page once: " + download.url);
    try {
      var html = folio.browser.open(download.url);
      var seconds = this.partnerWaitSeconds(html);
      if (seconds !== null) {
        this.progress("Free partner wait: about " + this.waitLabel(seconds) + " (estimate).",
          "Partner landing page advertises a wait of " + seconds + " seconds; no EPUB file verified.");
      } else {
        this.diagnostic("No wait estimate published on the first free partner landing page.");
      }
      return seconds;
    } catch (error) {
      this.diagnostic("Free partner wait estimate unavailable: " + error);
      return null;
    }
  },

  // Resolve the *published* free file link after the partner's own countdown.
  // A /slow_download/ page is an HTML landing page and MUST NOT be handed to
  // Folio's EPUB importer as though it were the ZIP file itself.
  publishedFileURL: function (html) {
    var doc = String(html || "");
    var span = doc.match(/<span\b[^>]*class=["'][^"']*\bbg-gray-200\b[^"']*\bbreak-all\b[^"']*["'][^>]*>([\s\S]*?)<\/span>/i);
    var candidate = span ? this.plainText(span[1]) : "";
    if (!candidate) {
      var links = /<a\b([^>]*)>([\s\S]*?)<\/a>/gi;
      var link;
      while ((link = links.exec(doc)) !== null) {
        if (!/download now|download file/i.test(this.plainText(link[2]))) continue;
        var href = link[1].match(/\bhref=["'](https?:\/\/[^"']+)["']/i);
        if (href) { candidate = this.unescape(href[1]); break; }
      }
    }
    return /^https:\/\/[^\s<>"']+$/i.test(candidate) ? candidate : null;
  },

  // WebKit may append ordinary verification/normalization query parameters
  // (for example ?&check=1) to an already-open Slow Partner page. Reopening
  // the SAME host + published path would restart its legitimate free countdown.
  // Ignore only the query string when comparing; never merge different hashes,
  // partners, protocols, or paths, and never construct a new landing-page URL.
  slowPageIdentity: function (address) {
    var match = String(address || "").match(
      /^https:\/\/(annas-archive\.(?:gl|pk|gd)\/slow_download\/[a-f0-9]{32}\/\d+\/\d+)(?:[?#].*)?$/i);
    return match ? match[1].toLowerCase() : null;
  },

  // Optional Folio source hook. Called only when the user actually starts a
  // download, after source.search has selected a copy. Uses the SAME private
  // WebKit page to let its normal wait/reload run. No member API or payment.
  prepareDownload: function (landingURL) {
    if (!folio.browser || typeof folio.browser.open !== "function" ||
        typeof folio.browser.waitFor !== "function")
      throw new Error("A free partner download requires Folio's background browser.");
    if (!/^https:\/\/annas-archive\.(?:gl|pk|gd)\/slow_download\/[a-f0-9]{32}\/\d+\/\d+(?:\?[^#]*)?$/i.test(landingURL))
      throw new Error("The source returned an unexpected partner landing-page address.");

    this.progress("Opening the free partner page…", "Preparing " + landingURL);
    var html;
    try {
      // Search sometimes preloads the very first partner page for a wait
      // estimate. Preserve that live countdown instead of resetting it.
      var current = "";
      try { if (typeof folio.browser.url === "function") current = folio.browser.url(); }
      catch (_) { /* No browser page has been opened yet: start this page now. */ }
      html = this.slowPageIdentity(current) === this.slowPageIdentity(landingURL)
        ? folio.browser.html() : folio.browser.open(landingURL);
    } catch (error) {
      this.diagnostic("Could not open the free partner page: " + error);
      throw error;
    }

    var previousWait = null;
    var waitLimit = Date.now() + 6 * 60 * 1000;
    var reportedMonitoring = false;
    var reportedSpan = null;
    while (Date.now() < waitLimit) {
      var direct = this.publishedFileURL(html);
      if (direct) {
        var finalHost = direct.match(/^https:\/\/([^/]+)/i);
        this.progress("Free file link is ready; starting the EPUB transfer…",
          "Partner page published a final file URL on host " + (finalHost ? finalHost[1] : "unknown") + ".");
        return direct; // Folio independently validates the destination host.
      }
      var remaining = null;
      try {
        var clock = folio.browser.evaluate("document.querySelector('.js-partner-countdown')?.textContent.trim() || ''");
        var n = parseInt(clock, 10);
        if (isFinite(n) && n > 0) remaining = n;
      } catch (_) {}
      if (remaining === null) remaining = this.partnerWaitSeconds(html);
      if (remaining !== null) {
        if (previousWait !== null && remaining > previousWait + 8)
          this.diagnostic("The partner extended the countdown; server availability has not been confirmed.");
        this.progress("Free partner wait: about " + this.waitLabel(remaining) + "…",
          "Waiting for the source's published countdown (" + remaining + " seconds); no EPUB yet.");
        reportedMonitoring = false;
      } else if (!reportedMonitoring) {
        // Say it once per quiet stretch, not on every poll.
        this.progress("Waiting for the free partner link…",
          "Partner page has not published a valid file URL; monitoring the page.");
        reportedMonitoring = true;
      }
      var spanText = this.publishedSpanText(html);
      if (spanText && spanText !== reportedSpan) {
        reportedSpan = spanText;
        this.diagnostic("Partner link box shows: " + JSON.stringify(spanText.slice(0, 160)));
      }
      previousWait = remaining;
      // Each poll waits at most 15 seconds and allows the site's own
      // JavaScript to reload the page. Never force-reload or skip a timer.
      var pollStarted = Date.now();
      try { folio.browser.waitFor("span.bg-gray-200.break-all"); }
      catch (error) { this.diagnostic("Partner page changed during wait: " + error); }
      // waitFor returns at once when the link box already exists but holds no
      // usable https URL yet. Without a pause the loop burned all its polls
      // in under a second and gave up long before the six-minute budget.
      if (Date.now() - pollStarted < 4000) this.pause();
      try { html = folio.browser.html(); }
      catch (error) { throw new Error("Free partner page became unavailable: " + error); }
    }
    throw new Error("Free partner never published an EPUB file link (waited six minutes). Try another official free partner later.");
  },

  // Text inside the partner's link box, whatever it holds (for diagnostics).
  publishedSpanText: function (html) {
    var span = String(html || "").match(/<span\b[^>]*class=["'][^"']*\bbg-gray-200\b[^"']*\bbreak-all\b[^"']*["'][^>]*>([\s\S]*?)<\/span>/i);
    return span ? this.plainText(span[1]) : "";
  },

  // A real wait between polls: waitFor on a selector that never appears
  // waits its full 15 seconds and then returns "false".
  pause: function () {
    try { folio.browser.waitFor("#folio-poll-pause-never-present"); }
    catch (_) { /* A failed pause must not abort the wait. */ }
  },

  // The preferred language is optional; older Folio versions invoke search
  // with only (query, page) and keep the source's original ranking unchanged.
  search: function (query, page, preferredLanguage, expectedTitle, expectedAuthor) {
    query = String(query || "").trim();
    if (!query) return [];
    page = Math.max(0, Math.floor(Number(page) || 0));
    var requestedLanguage = this.normalizedLanguage(preferredLanguage);
    this.failedDetailHosts = {};
    var hosts = this.orderedMirrors();
    if (!hosts.length) {
      var shared = this.recall("cooldowns") || {}, latest = 0;
      for (var h in shared) if (shared[h] && shared[h].until > latest) latest = shared[h].until;
      for (var h2 in this.mirrorCooldowns) if (this.mirrorCooldowns[h2].until > latest) latest = this.mirrorCooldowns[h2].until;
      var minutes = Math.max(1, Math.ceil((latest - Date.now()) / 60000));
      this.progress("Skipped: no official mirror answered from this network moments ago.",
        "Every official mirror failed within the last few minutes; checking again in about " + minutes + " min.");
      throw new Error("Skipped: no official mirror answered from this network moments ago (next check in about " + minutes + " min).");
    }
    var failures = [];
    var transportFailures = 0;
    var unavailableCatalogMessage = null;
    var searchPath = "/search?q=" + encodeURIComponent(query) + "&display=table&ext=epub&page=" + (page + 1);
    // Race the mirrors instead of waiting out each one's timeout in turn
    // (three unreachable mirrors used to cost about two minutes on mobile
    // data). The fastest answer goes first; mirrors that failed on transport
    // are dropped, and any that answered with an HTTP denial or a browser
    // check keep their normal browser fallback below.
    var prefetched = null;
    if (hosts.length > 1 && typeof folio.fetchFirst === "function") {
      this.progress("Searching free EPUB listings…",
        "Asking " + hosts.join(", ") + " at once for " + JSON.stringify(query) + " (page " + (page + 1) + ").");
      try {
        var answer = JSON.parse(folio.fetchFirst(JSON.stringify(hosts.map(function (h) {
          return "https://" + h + searchPath;
        })), JSON.stringify({timeout: this.probeSeconds})));
        var winner = String(answer.url).replace(/^https:\/\//, "").split("/")[0];
        prefetched = {host: winner, html: answer.text};
        hosts.splice(hosts.indexOf(winner), 1);
        hosts.unshift(winner);
      } catch (raceError) {
        var reasons = String(raceError && raceError.message || raceError).replace(/^Error: /, "").split(" | ");
        var remaining = [];
        for (var r = 0; r < hosts.length; r++) {
          var reason = null;
          for (var q = 0; q < reasons.length; q++)
            if (reasons[q].indexOf(hosts[r] + ": ") === 0) reason = reasons[q].slice(hosts[r].length + 2);
          if (reason && this.transportFailure(reason)) {
            failures.push(hosts[r] + ": " + reason);
            transportFailures++;
            this.coolDown(hosts[r], this.transportFailure(reason));
          } else {
            remaining.push(hosts[r]);
          }
        }
        if (!remaining.length) {
          var summary = this.failureSummary(failures);
          this.progress("Official mirrors unreachable; skipped.", "No official mirror answered: " + summary);
          throw new Error("No mirror answered (" + summary + ").");
        }
        hosts = remaining;
      }
    }
    for (var i = 0; i < hosts.length; i++) {
      var host = hosts[i];
      try {
        var origin = "https://" + host;
        var url = origin + searchPath;
        var html;
        if (prefetched && prefetched.host === host) {
          html = prefetched.html;
          this.diagnostic("Using " + host + ", the first mirror to answer.");
        } else {
          this.progress("Searching free EPUB listings…",
            "Searching " + host + " for " + JSON.stringify(query) + " (page " + (page + 1) + ").");
          html = this.fetchPage(url);
        }
        var initialCards = this.searchCards(html);
        this.diagnostic("Parsed " + initialCards.length + " EPUB record(s) from " + host + ".");
        // Native-provided title/author are trusted query intent even when no
        // language preference was supplied. Older two-argument manual calls
        // retain Anna's normal result ordering and breadth.
        var identity = this.expectedIdentity(expectedTitle, expectedAuthor) ||
          (requestedLanguage ? this.lookupIdentity(query, initialCards) : null);
        var cards = initialCards;
        if (identity) {
          // Search result titles/authors are already present in the HTML table.
          // Do not spend twelve expensive record requests on unrelated books.
          // An exact normalized title is still required downstream for auto-read.
          var eligibleFirst = this.languageEligible(initialCards, requestedLanguage);
          var hasCredible = eligibleFirst.some(function (card) {
            var rank = source.identityRank(card, identity);
            return rank === 0 || rank === 1;
          });
          if (!hasCredible) {
            // At most ONE extra same-mirror search: the archive sometimes
            // interprets "Iron Gold brown" as a full-text phrase instead of
            // matching its indexed title. No extra detail or slow wait yet.
            var retryURL = origin + "/search?q=" + encodeURIComponent(identity.title) +
              "&display=table&ext=epub&page=" + (page + 1);
            this.progress("Refining search by exact book title…",
              "No credible " + identity.title + " / " + identity.surname +
              " row in the first listing; trying the title-only index once.");
            try {
              var additional = this.searchCards(this.fetchPage(retryURL));
              this.diagnostic("Title-only retry yielded " + additional.length + " EPUB listing(s).");
              var seenHashes = {};
              for (var c = 0; c < cards.length; c++) seenHashes[cards[c].hash] = true;
              for (var c = 0; c < additional.length; c++) {
                if (!seenHashes[additional[c].hash]) {
                  cards.push(additional[c]);
                  seenHashes[additional[c].hash] = true;
                }
              }
            } catch (retryError) {
              // A failed optional refinement must not discard the usable
              // results from the first successful search.
              this.diagnostic("Title-only refinement unavailable: " + retryError);
            }
          }
          var exactCards = [], seriesCards = [], nearbyCount = 0;
          for (var c = 0; c < cards.length; c++) {
            var rank = this.identityRank(cards[c], identity);
            if (rank === 0) exactCards.push(cards[c]);
            else if (rank === 1) seriesCards.push(cards[c]);
            else if (rank === 2) nearbyCount++;
          }
          // Canonical title > clear series subtitle. Ambiguous nearby aliases
          // are excluded from ALL automatic record-detail requests.
          // Inside each category: explicit language > unknown; then prefer
          // records whose creator is not a concatenation of duplicate names.
          var self = this;
          function ordered(group) {
            return self.languageEligible(group, requestedLanguage)
              .map(function (card, index) { return {card: card, index: index}; })
              .sort(function (a, b) {
                if (requestedLanguage) {
                  var aKnown = self.normalizedLanguage(a.card.language) === requestedLanguage;
                  var bKnown = self.normalizedLanguage(b.card.language) === requestedLanguage;
                  if (aKnown !== bKnown) return aKnown ? -1 : 1;
                }
                var aClarity = self.authorClarity(a.card, identity);
                var bClarity = self.authorClarity(b.card, identity);
                return aClarity - bClarity || a.index - b.index;
              }).map(function (item) { return item.card; });
          }
          // A known correct-language subtitle is safer than an exact title
          // with *unknown* language. Preserve exact-before-series ranking
          // within the same language-confidence tier.
          var exactOrdered = ordered(exactCards), seriesOrdered = ordered(seriesCards);
          if (requestedLanguage) {
            var matchesExpected = function (card) {
              return self.normalizedLanguage(card.language) === requestedLanguage;
            };
            cards = exactOrdered.filter(matchesExpected).concat(seriesOrdered.filter(matchesExpected),
              exactOrdered.filter(function (card) { return !matchesExpected(card); }),
              seriesOrdered.filter(function (card) { return !matchesExpected(card); }));
          } else {
            cards = exactOrdered.concat(seriesOrdered);
          }
          this.diagnostic("Identity-aware search for " + identity.title + " / " + identity.surname +
            ": " + exactCards.length + " exact title row(s), " + seriesCards.length +
            " clear series-label row(s), " + nearbyCount +
            " ambiguous nearby row(s) SKIPPED; unrelated/adapted results skipped before detail lookups.");
        } else {
          // Unstructured or ambiguous query: preserve the older search order.
          cards = this.languageEligible(cards, requestedLanguage);
        }
        this.preferredMirror = host;
        var results = [];
        var visitedHashes = {}, examined = 0;
        for (var j = 0; j < cards.length && examined < this.maxResults; j++) {
          var card = cards[j];
          if (visitedHashes[card.hash]) continue;
          visitedHashes[card.hash] = true;
          examined++;
          this.diagnostic("Anna EPUB record hash=" + card.hash +
            " language=" + (card.language || "unknown") + ".");
          this.progress("Loading book details " + examined + "/" + Math.min(cards.length, this.maxResults) + "…",
            "Looking up public record " + card.hash + " on approved mirrors.");
          var files = this.resolveFreeEPUB(card.hash, host);
          if (!files.length) continue;
          results.push({
            id: card.hash,
            title: card.title,
            authors: card.author ? [card.author] : [],
            year: card.year,
            language: card.language || null,
            origin: host,
            downloads: files
          });
        }
        if (examined && !results.length) {
          // This is NOT a failed catalogue search. Each distinct eligible
          // edition was checked against approved free partner pages already;
          // repeating the same MD5s via another catalogue mirror is wasteful.
          unavailableCatalogMessage = "Matching catalogue EPUB edition(s) found (" + examined +
            "), but no accessible published free EPUB partner links could be resolved from approved sources.";
          this.progress("Matching editions found, but free download is unavailable.", unavailableCatalogMessage);
          break;
        }
        if (results.length) {
          var estimate = this.inspectPartnerWait(results[0].downloads[0]);
          this.progress(estimate === null
            ? "Free partner links found; EPUB download unverified."
            : "Free partner wait ~" + this.waitLabel(estimate) + "; EPUB unverified.",
            "Found " + results.length + " record(s) with published free landing pages. A landing page is not a verified EPUB file.");
        } else {
          this.progress(identity ? "No credible matching EPUB editions found." : "No free EPUB listings found.",
            identity ? "No matching title/author and eligible language after at most one title-only search for " +
              identity.title + " / " + identity.surname + " on " + host + "; no record-detail requests were made."
              : "No records matched the EPUB listing query on " + host + ".");
        }
        return results;
      } catch (error) {
        failures.push(host + ": " + error);
        if (this.rememberTransportFailure(host, error)) transportFailures++;
        this.progress("Mirror unavailable; checking another official mirror…",
          host + " search failed: " + error);
      }
    }
    if (unavailableCatalogMessage) throw new Error(unavailableCatalogMessage);
    this.progress(transportFailures === failures.length && failures.length
      ? "Official mirrors unreachable (network, DNS or TLS)."
      : "Free search unavailable; mirror verification or network access may be required.",
      "All official mirrors failed: " + failures.join("; "));
    throw new Error("Free search is unavailable (" + this.failureSummary(failures) + ").");
  },

  // A blank query is not sent to a scrape server; Folio asks search(query) when
  // looking up a particular title, and this extension is intended for that flow.
  recent: function () { return []; }
};
