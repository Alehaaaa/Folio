import assert from "node:assert/strict";
import fs from "node:fs";
import {fileURLToPath} from "node:url";
import {dirname, join} from "node:path";

const root = dirname(fileURLToPath(import.meta.url));
const script = fs.readFileSync(join(root, "Sources/GoodreadsLab/GoodreadsBridge.js"), "utf8");
const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;

function fakeHTML(html) {
  const shelfRow = html.includes("fixture-review-row") ? {
    querySelector(selector) {
      if (selector.includes('a[href*="/book/show/"]')) {
        return {getAttribute(key) { return key === "href" ? "/book/show/123" : "Sample Book"; }, textContent: "Sample Book"};
      }
      if (selector.includes("field.author")) return {textContent: "Example Author"};
      return null;
    },
  } : null;
  return {
    title: "Sample Book",
    querySelectorAll(selector) { return shelfRow && selector.includes("review_") ? [shelfRow] : []; },
    querySelector(selector) {
      if (selector.includes("og:title")) return {content: "Sample Book"};
      if (selector.includes("name=\"csrf-token\"")) return {getAttribute() { return "fixture-csrf"; }};
      return null;
    },
  };
}

async function run(action, payload, replies = [], origin = "https://www.goodreads.com") {
  const calls = [];
  const homeCard = {
    textContent: "Amanecer rojo 44% Update progress",
    querySelector(selector) {
      if (selector.includes('/book/show/')) return null;
      if (selector.includes('img[alt]')) return {getAttribute: () => "Amanecer rojo"};
      return null;
    },
  };
  const progressButton = {
    textContent: "Update progress", parentElement: homeCard,
    getAttribute(name) { return name === "data-reactid" ? ".usse22wxri.0.1.$=1$23148013.1.3.2.0" : null; },
  };
  const progressInput = {
    type: "text", name: "", id: "", value: "44", placeholder: "41",
    getAttribute(name) { return name === "aria-label" ? "Enter current percent read in Amanecer rojo" : null; },
    closest() { return {className: "updateReadingProgress__header"}; },
  };
  const fakeDocument = {
    querySelector(selector) {
      if (action === "inspectProgressEditor" && selector === "input.updateReadingProgress__headerInput") return progressInput;
      return selector.includes('meta[name="csrf-token"]') ? {getAttribute() { return "fixture-csrf"; }} : null;
    },
    querySelectorAll(selector) {
      if (action === "inspectHome" && selector === "button,a") return [progressButton];
      if (action === "inspectProgressEditor" && selector === "button.longTextPopupForm__submitButton") return [];
      return [];
    },
  };
  const fakeFetch = async (url, options) => {
    calls.push({url: String(url), options});
    const reply = replies.shift() ?? {code: 200, html: "<html></html>"};
    return {
      status: reply.code,
      ok: reply.code >= 200 && reply.code < 300,
      url: reply.url ?? String(url),
      headers: {get() { return "text/html"; }},
      text: async () => reply.html,
      json: async () => JSON.parse(reply.html),
    };
  };
  const execute = new AsyncFunction("action", "payload", "location", "document", "DOMParser", "fetch",
    "URL", "URLSearchParams", "AbortController", "setTimeout", "clearTimeout", script);
  const promise = execute(action, payload, {origin, href: origin + "/", pathname: "/"}, fakeDocument,
    class { parseFromString(html) { return fakeHTML(html); } }, fakeFetch,
    URL, URLSearchParams, AbortController, setTimeout, clearTimeout);
  return {result: await promise, calls};
}

async function expectReject(action, payload, replies, matcher, origin) {
  await assert.rejects(run(action, payload, replies, origin), matcher);
}

const tests = [
  ["Home progress is detected from the actual React button and its book key", async () => {
    const {result} = await run("inspectHome", {});
    assert.equal(result.updateButtons, 1);
    assert.equal(result.cards[0].id, "23148013");
    assert.equal(result.cards[0].percent, 44);
    assert.equal(result.cards[0].title, "Amanecer rojo");
  }],
  ["the actual React progress input is recognized without an HTML form", async () => {
    const {result} = await run("inspectProgressEditor", {});
    assert.equal(result.formAction, "/user_status.json (XHR)");
    assert.equal(result.controls[0].percent, 44);
  }],
  ["cross-origin pages cannot send Goodreads requests", async () => {
    await expectReject("session", {}, [], /Open www.goodreads.com/, "https://www.amazon.com");
  }],
  ["a shelf write sends exactly the intended fields", async () => {
    const {result, calls} = await run("setStatus", {bookID: "123", shelf: "to-read"});
    assert.equal(result.verified, false);
    assert.equal(calls.length, 1);
    assert.equal(new URL(calls[0].url).pathname, "/shelf/add_to_shelf");
    assert.equal(calls[0].options.method, "POST");
    const fields = new URLSearchParams(calls[0].options.body);
    assert.equal(fields.get("book_id"), "123");
    assert.equal(fields.get("name"), "to-read");
    assert.equal(fields.get("authenticity_token"), "fixture-csrf");
    assert.equal(calls[0].options.credentials, "same-origin");
  }],
  ["a progress write uses percent, not page count", async () => {
    const {result, calls} = await run("setProgress", {bookID: "123", percent: 37}, [
      {code: 200, html: "{}"}, {code: 200, html: "<html><title>Sample Book</title></html>"},
    ]);
    assert.equal(result.observedPercent, null);
    assert.equal(result.verified, false);
    assert.equal(calls.length, 2);
    assert.equal(new URL(calls[0].url).pathname, "/user_status.json");
    const fields = new URLSearchParams(calls[0].options.body);
    assert.equal(fields.get("user_status[book_id]"), "123");
    assert.equal(fields.get("user_status[percent]"), "37");
    assert.equal(fields.get("user_status[body]"), "");
  }],
  ["a page update uses the recorded Goodreads page field, without percent", async () => {
    const {result, calls} = await run("setProgress", {bookID: "23148013", unit: "page", value: 220}, [
      {code: 200, html: JSON.stringify({})},
    ]);
    assert.equal(calls.length, 1);
    assert.equal(new URL(calls[0].url).pathname, "/user_status.json");
    const fields = new URLSearchParams(calls[0].options.body);
    assert.deepEqual([...fields.keys()].sort(), ["user_status[book_id]", "user_status[body]", "user_status[page]", "authenticity_token"].sort());
    assert.equal(fields.get("user_status[book_id]"), "23148013");
    assert.equal(fields.get("user_status[page]"), "220");
    assert.equal(result.page, 220);
    assert.equal(result.verified, false);
  }],
  ["page progress is verified only when the response confirms the actual page", async () => {
    const {result} = await run("setProgress", {bookID: "23148013", unit: "page", value: 220}, [
      {code: 200, html: JSON.stringify({user_status: {page: 220}})},
    ]);
    assert.equal(result.verified, true);
    assert.equal(result.observedPage, 220);
  }],
  ["saved percentage is verified using Goodreads' JSON write response", async () => {
    const {result, calls} = await run("setProgress", {bookID: "123", percent: 37}, [
      {code: 200, html: JSON.stringify({updatedAt: "2026-11-24T18:00:00Z", currentPosition: 37, finalPosition: 100})},
    ]);
    assert.equal(result.verified, true);
    assert.equal(result.observedPercent, 37);
    assert.equal(calls.length, 1);
  }],
  ["bad book IDs are rejected before a network request", async () => {
    await expectReject("setStatus", {bookID: "123/../456", shelf: "read"}, [], /digits only/);
  }],
  ["bad shelves and invalid percentages are rejected", async () => {
    await expectReject("setStatus", {bookID: "123", shelf: "private"}, [], /Unknown Goodreads shelf/);
    await expectReject("setProgress", {bookID: "123", percent: 101}, [], /0 to 100/);
    await expectReject("setProgress", {bookID: "123", unit: "page", value: -1}, [], /non-negative integer/);
    await expectReject("setProgress", {bookID: "123", unit: "page", value: 2.5}, [], /non-negative integer/);
    await expectReject("setProgress", {bookID: "123", unit: "chapters", value: 12}, [], /must be percent or page/);
  }],
  ["a login redirect must not masquerade as a successful write", async () => {
    await expectReject("setStatus", {bookID: "123", shelf: "read"}, [
      {code: 200, url: "https://www.goodreads.com/user/sign_in", html: "<h1>Sign In</h1>"},
    ], /requires a signed-in/);
  }],
  ["server errors are never reported as successful writes", async () => {
    await expectReject("setStatus", {bookID: "123", shelf: "read"}, [
      {code: 422, html: "error"},
    ], /HTTP 422/);
  }],
  ["the All shelf populates a deduplicated book selection", async () => {
    const {result, calls} = await run("readShelves", {userID: "9876"}, [
      {code: 200, html: "fixture-review-row"},
    ]);
    assert.equal(calls.length, 1);
    assert.equal(new URL(calls[0].url).searchParams.get("shelf"), "all");
    assert.equal(result.books.length, 1);
    assert.deepEqual({id: result.books[0].id, title: result.books[0].title, shelf: result.books[0].shelf},
      {id: "123", title: "Sample Book", shelf: ""});
  }],
  ["empty All view falls back to the four exclusive shelves", async () => {
    const {result, calls} = await run("readShelves", {userID: "9876"}, [
      {code: 200, html: "<html></html>"},
      {code: 200, html: "fixture-review-row"},
      {code: 200, html: "fixture-review-row"},
      {code: 200, html: "<html></html>"},
      {code: 200, html: "<html></html>"},
    ]);
    assert.equal(calls.length, 5);
    assert.equal(result.books.length, 1);
    assert.equal(result.books[0].shelf, "to-read");
  }],
  ["a Goodreads My Books link resolves its numeric profile ID", async () => {
    const {result, calls} = await run("readShelves", {
      userID: "https://www.goodreads.com/review/list/188989236-alejandro-mart-n?shelf=currently-reading",
    }, [
      {code: 200, html: "fixture-review-row"},
    ]);
    assert.equal(result.books[0].id, "123");
    assert.equal(new URL(calls[0].url).pathname, "/review/list/188989236");
  }],
  ["the authenticated reading-session endpoint returns progress", async () => {
    const {result, calls} = await run("readProgress", {}, [{code: 200, html: JSON.stringify({
      sessions: [{book: {id: "123", title: "Example"}, currentPosition: 42, finalPosition: 100}],
    })}]);
    assert.equal(new URL(calls[0].url).pathname, "/home/load_reading_sessions");
    assert.equal(result.sessions.length, 1);
    assert.equal(result.sessions[0].percent, 42);
    assert.equal(result.sessions[0].bookID, "123");
  }],
  ["GraphQL shelf writes require a confirmed shelf in their response", async () => {
    const {result, calls} = await run("setStatusGraphQL", {bookID: "123", shelf: "read"}, [
      {code: 200, html: '<html><body>kca://book/abc-123</body></html>'},
      {code: 200, html: "a".repeat(80)},
      {code: 200, html: JSON.stringify({data: {shelveBook: {shelving: {shelf: {name: "read"}}}}})},
    ]);
    assert.equal(result.verified, true);
    assert.equal(calls.length, 3);
    assert.equal(new URL(calls[1].url).pathname, "/authenticate");
    assert.equal(new URL(calls[2].url).pathname, "/graphql");
    const body = JSON.parse(calls[2].options.body);
    assert.equal(body.variables.input.id, "kca://book/abc-123");
    assert.equal(body.variables.input.shelfName, "read");
    assert.equal(body.operationName, "ShelveBook");
  }],
  ["GraphQL rejects success responses that name another shelf", async () => {
    await expectReject("setStatusGraphQL", {bookID: "123", shelf: "read"}, [
      {code: 200, html: "kca://book/abc123"},
      {code: 200, html: "a".repeat(80)},
      {code: 200, html: JSON.stringify({data: {shelveBook: {shelving: {shelf: {name: "to-read"}}}}})},
    ], /did not confirm/);
  }],
];

let failed = 0;
for (const [name, test] of tests) {
  try {
    await test();
    console.log(`PASS ${name}`);
  } catch (error) {
    failed++;
    console.error(`FAIL ${name}:`, error);
  }
}
if (failed) process.exitCode = 1;
else console.log(`${tests.length} Goodreads bridge tests passed.`);
