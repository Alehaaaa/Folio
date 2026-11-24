import assert from "node:assert/strict";
import {readFileSync} from "node:fs";
import {join, dirname} from "node:path";
import {fileURLToPath} from "node:url";
import vm from "node:vm";

const path = join(dirname(fileURLToPath(import.meta.url)), "Sources/GoodreadsLab/GoodreadsTrafficProbe.js");
const script = readFileSync(path, "utf8");
const events = [];
const handlers = {};
class FakeElement {
  tagName = "BUTTON";
  id = "updateProgress";
  className = "update-progress";
  innerText = "Update progress";
  outerHTML = '<button id="updateProgress" value="secret-value" data-csrf="secret-token">Update progress</button>';
  closest() { return this; }
  getAttribute(name) { return name === "data-testid" ? "update-progress" : null; }
}
class FakeXHR {
  listeners = {};
  open(method, url) { this.method = method; this.url = url; }
  send() { this.status = 200; this.listeners.loadend?.(); }
  addEventListener(type, callback) { this.listeners[type] = callback; }
  getResponseHeader() { return "application/json"; }
}
// Use the platform's prototype rather than an explicit static prototype field.
const observer = class { observe() {} };
const document = {
  title: "Goodreads Home",
  readyState: "complete",
  scripts: [],
  addEventListener(type, callback) { handlers[type] = callback; },
};
const window = {
  webkit: {messageHandlers: {goodreadsRecorder: {postMessage(value) { events.push(value); }}}},
  addEventListener(type, callback) { handlers[type] = callback; },
  fetch: async () => ({status: 200, headers: {get: () => "application/json"}}),
  eval: source => source,
};
const context = {
  window, document, URL, URLSearchParams, FormData, Request,
  XMLHttpRequest: FakeXHR, MutationObserver: observer,
  PerformanceObserver: class { observe() {} },
  Element: FakeElement, HTMLFormElement: class extends FakeElement {},
  location: {href: "https://www.goodreads.com/", host: "www.goodreads.com", pathname: "/"},
  performance: {now: () => 22},
  history: {pushState() {}, replaceState() {}},
  console: {log() {}, info() {}, warn() {}, error() {}, debug() {}},
  Date, setTimeout, clearTimeout,
};
vm.runInNewContext(script, context, {timeout: 1000});
assert.equal(window.__goodreadsLabRecorder.status().active, false);
window.__goodreadsLabRecorder.start();
handlers.click({target: new FakeElement(), clientX: 100, clientY: 200, isTrusted: true});
await window.fetch("https://www.goodreads.com/user_status.json", {
  method: "POST", body: "user_status%5Bpercent%5D=41&authenticity_token=secret-token",
});
await new Promise(resolve => setTimeout(resolve, 0));
window.__goodreadsLabRecorder.stop();
assert.ok(events.some(event => event.type === "click"));
const clicked = events.find(event => event.type === "click");
assert.match(clicked.target.html, /value="\[REDACTED\]"/);
assert.ok(!JSON.stringify(clicked).includes("secret-token"));
const request = events.find(event => event.type === "request");
assert.equal(request.method, "POST");
assert.equal(request.target.path, "/user_status.json");
assert.equal(request.safeValues["user_status[percent]"], "41");
assert.ok(!JSON.stringify(events).includes("secret-token"));
assert.ok(events.some(event => event.type === "response" && event.status === 200));
const eventCount = events.length;
handlers.click({target: new FakeElement(), clientX: 0, clientY: 0, isTrusted: true});
assert.equal(events.length, eventCount, "Stop must disable new events");
console.log("PASS recorder start/stop, click HTML redaction, POST shape and completion");
