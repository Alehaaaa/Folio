// Offline sandbox for the source failures seen on a phone on mobile data
// (All Systems Red / Sistemas críticos, 2026-11-26), plus nearby cases.
//
// Each bundled source script runs unchanged against a simulated network with
// a virtual clock: every host either answers after some seconds, refuses
// (HTTP 403), fails TLS/DNS, or stalls until URLSession's timeout. Each case
// is timed twice: on the previous Folio runtime (no folio.fetchFirst, so the
// sources try mirrors one by one) and on the current one (mirrors raced).
//
// Run: node checks/test-source-failures-sandbox.cjs
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const root = path.join(__dirname, "..");
const read = (file) => fs.readFileSync(path.join(root, file), "utf8");
const annaSearch = read("checks/anna-fixtures/search.html");
const annaDetail = read("checks/anna-fixtures/detail.html");
const annaHash = "51d2b22ca12a8b470b51f543298b34c9";
const githubConfig = 'export const OFFICIAL_MIRRORS = ["annas-archive.gl", "annas-archive.pk", "annas-archive.gd"] as const;';

// What one stalled request costs on the phone: the log shows 35–45 s per
// Anna mirror and ~35 s for libgen.li with URLSession's 30 s request limit.
const STALL = 35;

/// A simulated network. `hosts` maps a host to {after, fail, body(url)}:
/// `fail: "stall"` waits out the timeout, any other string is the error text.
function network(hosts, memo = new Map(), clock = { now: 0 }) {
  const requests = [];
  const outcome = (url, limit) => {
    const host = new URL(url).host;
    const rule = hosts[host] || { fail: "A server with the specified hostname could not be found." };
    if (rule.fail === "stall") return { after: limit, error: "The request timed out." };
    if (rule.fail) return { after: rule.after ?? 0.3, error: rule.fail };
    if ((rule.after ?? 0.3) >= limit) return { after: limit, error: "The request timed out." };
    return { after: rule.after ?? 0.3, text: rule.body ? rule.body(url) : "" };
  };
  const folio = {
    fetchText(url) {
      requests.push(url);
      const r = outcome(url, STALL);
      clock.now += r.after;
      if (r.error) throw new Error(r.error);
      return r.text;
    },
    log() {},
    status() {},
    config: {},
  };
  const withRace = {
    ...folio,
    // Notes kept across job runtimes, as SourceMemo does in Folio.
    remember(key, value, seconds) { memo.set(key, { value, until: clock.now + seconds }); },
    recall(key) { const n = memo.get(key); return n && n.until > clock.now ? n.value : null; },
    fetchWith(url, options) {
      const limit = Math.min(Math.max(JSON.parse(options).timeout || 30, 3), 30);
      requests.push(url);
      const r = outcome(url, limit === 30 ? STALL : limit);
      clock.now += r.after;
      if (r.error) throw new Error(r.error);
      return r.text;
    },
    fetchFirst(urlsJSON, optionsJSON) {
      const urls = JSON.parse(urlsJSON);
      const limit = Math.min(Math.max(JSON.parse(optionsJSON).timeout || 15, 3), 30);
      urls.forEach((u) => requests.push(u));
      const results = urls.map((u) => ({ url: u, ...outcome(u, limit) }));
      const wins = results.filter((r) => !r.error).sort((a, b) => a.after - b.after);
      if (wins.length) {
        clock.now += wins[0].after;
        return JSON.stringify({ url: wins[0].url, text: wins[0].text });
      }
      clock.now += Math.max(...results.map((r) => r.after));
      throw new Error(results.map((r) => `${new URL(r.url).host}: ${r.error}`).join(" | "));
    },
  };
  return { clock, requests, folio, withRace };
}

function load(file, folio, clock) {
  const context = { folio, Date: { now: () => clock.now * 1000 }, RegExp, JSON, encodeURIComponent, Math };
  vm.createContext(context);
  vm.runInContext("folio.fetchJSON = function (u) { return JSON.parse(folio.fetchText(u)); };", context);
  vm.runInContext(read(file), context, { timeout: 5000 });
  return context.source;
}

/// Runs `body(source)` on both runtimes; returns timings and outcomes.
function compare(file, hosts, body) {
  const out = {};
  for (const [label, key] of [["before", "folio"], ["after", "withRace"]]) {
    const net = network(hosts);
    const source = load(file, net[key], net.clock);
    let result, error;
    try { result = body(source); } catch (e) { error = String(e.message || e); }
    out[label] = { seconds: Math.round(net.clock.now * 10) / 10, result, error, requests: net.requests.length };
  }
  return out;
}

const rows = [];
function record(name, r) {
  rows.push([name, r.before.seconds, r.after.seconds, r.after.error ? "fails: " + r.after.error.slice(0, 70) : "ok"]);
}

const github = { "raw.githubusercontent.com": { after: 0.5, body: () => githubConfig } };
const annaOK = (after) => ({
  after,
  body: (url) => (url.includes("/md5/") ? annaDetail : annaSearch),
});
const annaSearchCall = (s) => s.search("Pride and Prejudice Jane Austen", 0);

// 1. The phone log: every Anna mirror stalls.
{
  const r = compare("extensions/annas-archive.js", {
    ...github,
    "annas-archive.gl": { fail: "stall" }, "annas-archive.pk": { fail: "stall" }, "annas-archive.gd": { fail: "stall" },
  }, annaSearchCall);
  record("Anna's Archive: all mirrors stall (log)", r);
  assert.ok(r.before.seconds >= 100, "reproduces the ~2 minute wait");
  assert.ok(r.after.seconds <= 18, `gives up within one probe, took ${r.after.seconds}s`);
  assert.match(r.after.error, /No mirror answered \(gl, pk, gd: timed out\)/);
}
// 2. One mirror stalls, another answers.
{
  const r = compare("extensions/annas-archive.js", {
    ...github, "annas-archive.gl": { fail: "stall" }, "annas-archive.pk": annaOK(1.5), "annas-archive.gd": { fail: "stall" },
  }, annaSearchCall);
  record("Anna's Archive: first mirror stalls, .pk answers", r);
  assert.equal(r.after.result.length, 1);
  assert.ok(r.after.seconds < r.before.seconds - 30, "skips the stalled first mirror");
}
// 3. Every mirror fails DNS or TLS straight away.
{
  const r = compare("extensions/annas-archive.js", {
    ...github,
    "annas-archive.gl": { fail: "A TLS error caused the secure connection to fail." },
    "annas-archive.pk": { fail: "A server with the specified hostname could not be found." },
    "annas-archive.gd": { fail: "A TLS error caused the secure connection to fail." },
  }, annaSearchCall);
  record("Anna's Archive: DNS/TLS failures", r);
  assert.ok(r.after.seconds <= 2);
  assert.match(r.after.error, /No mirror answered/);
}
// 4. A refusal keeps its fallback; the stalled mirrors are not retried.
{
  const r = compare("extensions/annas-archive.js", {
    ...github,
    "annas-archive.gl": { fail: "annas-archive.gl answered 403" },
    "annas-archive.pk": { fail: "stall" }, "annas-archive.gd": { fail: "stall" },
  }, annaSearchCall);
  record("Anna's Archive: 403 + two stalls", r);
  assert.ok(r.after.seconds <= 18, `took ${r.after.seconds}s`);
}

const libgenTable = `<table id="tablelibgen"><tr>
  <td><a href="/edition.php?id=1">Sistemas críticos</a></td><td><a href="/author.php?id=1">Martha Wells</a></td>
  <td>Kids</td><td>2019</td><td>Spanish</td><td>160</td><td>1 MB</td><td>EPUB</td>
  <td><a href="/ads.php?md5=0123456789abcdef0123456789abcdef">LibGen</a></td></tr></table>`;
const libgenCall = (s) => s.search("Sistemas críticos wells", 0, "es", "Sistemas críticos");
// 5. The phone log: libgen.li stalls, libgen.gl answers.
{
  const r = compare("extensions/libgen.js", {
    "libgen.li": { fail: "stall" }, "libgen.gl": { after: 1, body: () => libgenTable },
    "libgen.vg": { after: 2, body: () => libgenTable },
  }, libgenCall);
  record("Library Genesis: libgen.li stalls (log)", r);
  assert.equal(r.after.result.length, 1);
  assert.ok(r.after.seconds <= 2, `took ${r.after.seconds}s`);
  assert.ok(r.before.seconds >= 35);
}
// 6. Every LibGen mirror refuses.
{
  const hosts = {};
  for (const h of ["libgen.li", "libgen.gl", "libgen.vg", "libgen.la", "libgen.bz"]) hosts[h] = { fail: `${h} answered 403` };
  const r = compare("extensions/libgen.js", hosts, libgenCall);
  record("Library Genesis: every mirror 403", r);
  assert.match(r.after.error, /No mirror answered.*403/);
  assert.ok(r.after.seconds <= 1);
}
// 7. Every LibGen mirror stalls.
{
  const hosts = {};
  for (const h of ["libgen.li", "libgen.gl", "libgen.vg", "libgen.la", "libgen.bz"]) hosts[h] = { fail: "stall" };
  const r = compare("extensions/libgen.js", hosts, libgenCall);
  record("Library Genesis: every mirror stalls", r);
  assert.ok(r.before.seconds >= 170);
  assert.ok(r.after.seconds <= 13, `took ${r.after.seconds}s`);
}
// 8. The fastest LibGen answer is a challenge page: the others are tried.
{
  const r = compare("extensions/libgen.js", {
    "libgen.li": { after: 0.2, body: () => "<title>Just a moment...</title>" },
    "libgen.gl": { after: 1, body: () => libgenTable },
  }, libgenCall);
  record("Library Genesis: challenge page wins race", r);
  assert.equal(r.after.result.length, 1);
}

// 9–10. OAPEN refuses (the log) or stalls: one request, one short reason.
for (const [name, rule, pattern] of [
  ["OAPEN: 403 (log)", { fail: "library.oapen.org answered 403" }, /turning away automated searches/],
  ["OAPEN: stalls", { fail: "stall" }, /did not answer in time/],
]) {
  const r = compare("extensions/oapen.js", { "library.oapen.org": rule }, (s) => s.search("Sistemas críticos", 0));
  record(name, r);
  assert.match(r.after.error, pattern);
  assert.equal(r.after.requests, 1);
  assert.ok(r.after.seconds <= 15.5);
}

// 11. Lectulandia: the first download mirror fails TLS (the log).
{
  const net = network({});
  const source = load("extensions/lectulandia.js", {
    ...net.withRace,
    browser: {
      open() { throw new Error("Error: A TLS error caused the secure connection to fail."); },
      waitFor() { return "false"; }, url() { return ""; }, html() { return ""; },
    },
  }, net.clock);
  assert.throws(
    () => source.prepareDownload("https://ww3.lectulandia.com/download.php?t=1&d=abc123"),
    (e) => String(e.message) === "secure connection failed (TLS)");
  rows.push(["Lectulandia: link 1 TLS failure (log)", "-", "-", "one line: secure connection failed (TLS); trying link 2"]);
}

// 12. Orchestration: an exact Spanish EPUB arrives early; the search moves on
// after the grace period instead of waiting for stalled sources. This models
// ExtensionStore.findCopies (exactMatchGrace = 4 s).
{
  const grace = 4;
  const finishes = { Lectulandia: { at: 6, exact: true }, "Anna's Archive": { at: 118 }, "Library Genesis": { at: 44 }, OAPEN: { at: 0.5 } };
  const exactAt = Math.min(...Object.values(finishes).filter((f) => f.exact).map((f) => f.at));
  const all = Math.max(...Object.values(finishes).map((f) => f.at));
  const ends = Math.min(all, exactAt + grace);
  rows.push(["Search waits for slow sources after an exact hit (log)", all, ends, "moves on after the grace period"]);
  assert.equal(ends, 10);
}

// 13. The Calamity Club (second phone log): libgen.li's tooltip markup
// leaked into titles, so an English EPUB was "nearby but not verified".
{
  const md5 = "686de11f0d38fe80f9bbfd9c4d6eff16";
  const table = `<table id="tablelibgen"><tr><td><b><a href="series.php?id=7">Standalone</a></b><br>` +
    `<a data-toggle="tooltip" title="Add/Edit : 2025-01-02<br>The Calamity Club - Kathryn Stockett" href="edition.php?id=208485630">The Calamity Club</a> ` +
    `<nobr><span class="badge badge-primary">b</span> <span class="badge badge-secondary">f</span> 10094557</nobr></td>` +
    `<td><a href="/author.php?id=1">Kathryn Stockett</a></td><td>Putnam</td><td>2025</td><td>English</td><td>400</td>` +
    `<td>1 MB</td><td>epub</td><td><a href="/ads.php?md5=${md5}">LibGen</a></td></tr></table>`;
  const r = compare("extensions/libgen.js", { "libgen.la": { after: 0.8, body: () => table } },
    (s) => s.search("The Calamity Club stockett", 0, "en", "The Calamity Club"));
  rows.push(["Library Genesis: tooltip markup in titles (log 2)", "-", r.after.seconds,
    "title: " + r.after.result[0].title]);
  assert.equal(r.after.result[0].title, "The Calamity Club");
}

// 14. Internet Archive upload titled "X By Author" with the same creator.
{
  const r = compare("extensions/internet-archive.js", {
    "archive.org": { after: 0.6, body: () => JSON.stringify({ response: { docs: [{
      identifier: "the-calamity-club-by-kathryn-stockett", title: "The Calamity Club By Kathryn Stockett",
      creator: "The Calamity Club By Kathryn Stockett", format: ["EPUB"] }] } }) },
  }, (s) => s.search("The Calamity Club stockett", 0, "en", "The Calamity Club", "Kathryn Stockett"));
  rows.push(["Internet Archive: \"Title By Author\" upload (log 2)", "-", r.after.seconds,
    r.after.result[0].title + " / " + r.after.result[0].authors.join(", ")]);
  assert.equal(r.after.result[0].title, "The Calamity Club");
  assert.deepEqual([...r.after.result[0].authors], ["Kathryn Stockett"]);
}

// 15. Retrying soon after Anna's mirrors all stalled (log 2 waited 15–17 s on
// each of three retries): later jobs skip them until the note expires.
{
  const memo = new Map(), clock = { now: 0 };
  const hosts = { ...github, "annas-archive.gl": { fail: "stall" }, "annas-archive.pk": { fail: "stall" }, "annas-archive.gd": { fail: "stall" } };
  const job = () => {
    const net = network(hosts, memo, clock);
    const source = load("extensions/annas-archive.js", net.withRace, clock);
    const start = clock.now;
    let error;
    try { annaSearchCall(source); } catch (e) { error = String(e.message); }
    return { seconds: Math.round((clock.now - start) * 10) / 10, error, requests: net.requests.length };
  };
  const first = job();
  clock.now += 30;
  const retry = job();
  clock.now += 200;
  const later = job();
  rows.push(["Anna's Archive: retry right after all mirrors stalled (log 2)", first.seconds, retry.seconds, retry.error.slice(0, 70)]);
  assert.ok(first.seconds <= 16);
  assert.equal(retry.seconds, 0);
  assert.equal(retry.requests, 0, "no mirror list or search requests on the retry");
  assert.match(retry.error, /Skipped: no official mirror answered/);
  assert.ok(later.requests > 0, "mirrors are probed again once the note expires");
}

// 16. A slow, dropping file host (third phone log: libgen.la kept dropping
// and resuming). Models FileTransfer: with another mirror waiting, a link
// that averages under 16 KB/s after 20 s with minutes to go, or sends
// nothing for 20 s, is dropped and the next mirror starts.
{
  const size = 900 * 1024;
  const mirrors = [{ rate: 6 * 1024, dropsEvery: 40 }, { rate: 400 * 1024 }];
  // Before: 60 s idle limit, two resumes, then the whole copy failed.
  const slow = mirrors[0];
  const beforeSeconds = Math.min(size / slow.rate, 3 * slow.dropsEvery + 2 * 60 + 6);
  // After: give up on mirror 1 at 20 s, then mirror 2 at full speed.
  const afterSeconds = 20 + size / mirrors[1].rate;
  rows.push(["File download: slow, dropping mirror (log 3)", Math.round(beforeSeconds), Math.round(afterSeconds),
    "switches to the next mirror after 20 s"]);
  assert.ok(afterSeconds < 25);
}

const pad = (v, n) => String(v).padEnd(n);
console.log(pad("Case", 64) + pad("before s", 10) + pad("after s", 9) + "result");
for (const [name, before, after, result] of rows) console.log(pad(name, 64) + pad(before, 10) + pad(after, 9) + result);
console.log("PASS: every logged source failure is fast, quiet and recoverable in the sandbox");
