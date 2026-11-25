// Amazon metadata: names with HTML character references decode fully, and
// translators listed in the byline are not taken as authors.
// node checks/test-amazon-metadata.cjs
const fs = require("fs");
const path = require("path");
const vm = require("vm");
const assert = require("assert");

const page = `<html><body>
<span id="productTitle" class="a-size-extra-large">Harry Potter y el prisionero de Azkaban</span>
<div id="bylineInfo" class="a-section">
<span class="author notFaded" data-width=""><a class="a-link-normal" href="/s?k=J.K.+Rowling">J.K. Rowling</a><span class="contribution" spacing="none"><span class="a-color-secondary">(Autor)</span><span class="a-color-secondary">,</span></span></span>
<span class="author notFaded" data-width=""><a class="a-link-normal" href="/s?k=Adolfo">Adolfo Mu&ntilde;oz Garc&iacute;a</a><span class="contribution" spacing="none"><span class="a-color-secondary">(Traductor)</span><span class="a-color-secondary">,</span></span></span>
<span class="author notFaded" data-width=""><a class="a-link-normal" href="/s?k=Alicia">Alicia Dellepiane</a><span class="contribution" spacing="none"><span class="a-color-secondary">(Traductor)</span></span></span>
<span class="author notFaded" data-width=""><a class="a-link-normal" href="/s?k=Nieves">Nieves Mart&iacute;n Azofra</a><span class="contribution" spacing="none"><span class="a-color-secondary">(Traductor)</span></span></span>
</div>
</div>
<div id="bookDescription_feature_div"><noscript>El tercer a&ntilde;o de Harry en Hogwarts &amp; m&aacute;s.</noscript></div>
</body></html>`;

// Stand-in for Folio's native folio.decodeHTML (the Swift decoder is tested in test-html-entities.swift).
const named = { ntilde: "ñ", iacute: "í", aacute: "á", amp: "&", quot: "\"", nbsp: " ", rlm: "‏", lrm: "‎" };
function decodeHTML(s) {
  for (let i = 0; i < 3; i++) {
    const next = s.replace(/&(#x[0-9a-f]+|#[0-9]+|[a-z]+);/gi, (all, k) =>
      k[0] === "#" ? String.fromCodePoint(parseInt(k[1] === "x" || k[1] === "X" ? k.slice(2) : k.slice(1), k[1] === "x" || k[1] === "X" ? 16 : 10))
                   : (named[k] !== undefined ? named[k] : all));
    if (next === s) break;
    s = next;
  }
  return s;
}

function run(withDecoder) {
  const folio = { log() {}, fetchWith: () => page, config: {} };
  if (withDecoder) folio.decodeHTML = decodeHTML;
  const ctx = { folio };
  vm.createContext(ctx);
  vm.runInContext(fs.readFileSync(path.join(__dirname, "../extensions/metadata-amazon.js"), "utf8") + "\nthis.source = source;", ctx);
  return ctx.source.product("www.amazon.es", "8498386322", "es");
}

const record = run(true);
assert.strictEqual(record.authors, "J.K. Rowling", "translators must not be authors: " + record.authors);
assert.strictEqual(record.title, "Harry Potter y el prisionero de Azkaban");
assert.strictEqual(record.description, "El tercer año de Harry en Hogwarts & más.");
console.log("PASS Amazon: authors " + JSON.stringify(record.authors) + ", description " + JSON.stringify(record.description));

const older = run(false);
assert.strictEqual(older.authors, "J.K. Rowling");
console.log("PASS Amazon on Folio builds without folio.decodeHTML still parses the byline");
