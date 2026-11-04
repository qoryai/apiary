// What the Mermaid hook draws of a block (assets/js/hooks/mermaid.js, `source`): without
// its directive lines, its front matter, and its click, link, links and callback lines;
// the settings it passes to mermaid.initialize (`settings`), with the secure list that
// the vendored Mermaid applies to a document's front matter; and the width it gives the
// <img> (`width`). `node --test 'assets/js/test/*.test.mjs'` (no npm).

import {test} from "node:test"
import assert from "node:assert/strict"

import {secure, settings, source, width} from "../hooks/mermaid.js"

// The front matter of the security round's finding: it turns HTML labels back on.
const FRONT_MATTER = [
  "---",
  "config:",
  "  htmlLabels: true",
  "  themeCSS: \".q-x { color: red }\"",
  "  dompurifyConfig:",
  "    ADD_TAGS: [\"foreignObject\"]",
  "  flowchart:",
  "    htmlLabels: true",
  "---",
  "flowchart LR",
  "  A[\"<b>x</b><img src='/some/path'>\"] --> B",
].join("\n")

test("drops each init directive line, keeping the diagram", () => {
  const text = [
    '%%{init: {"theme": "dark", "securityLevel": "loose"}}%%',
    "flowchart LR",
    '  %%{ initialize: {"maxEdges": 9999} }%%',
    "  A[Cart] --> B[Invoice]",
  ].join("\n")

  assert.equal(source(text), "flowchart LR\n  A[Cart] --> B[Invoice]")
})

test("drops a line with a directive after a statement", () => {
  assert.equal(
    source('flowchart LR\n  A --> B %%{init: {"theme": "dark"}}%%\n  B --> C'),
    "flowchart LR\n  B --> C",
  )
})

test("drops each click line, at its start or after a ;", () => {
  const text = [
    "flowchart LR",
    "  A --> B",
    '  click A "https://example.com" "Open"',
    "  CLICK B callback",
    '  B --> C; click C href "javascript:alert(1)"',
    "  C --> D",
  ].join("\r\n")

  assert.equal(source(text), "flowchart LR\n  A --> B\n  C --> D")
})

test("keeps a line where click is a word of a label", () => {
  const text = "flowchart LR\n  A[click here] --> B[Clicks counted]"
  assert.equal(source(text), text)
})

test("the width is the SVG's max-width, rounded up", () => {
  assert.equal(width('<svg width="100%" style="max-width: 835.5px;" viewBox="0 0 835 200">'), 836)
  assert.equal(width('<svg width="100%" viewBox="0 0 835 200">'), null)
})

test("drops a front matter block at the start", () => {
  assert.equal(source(FRONT_MATTER), "flowchart LR\n  A[\"<b>x</b><img src='/some/path'>\"] --> B")
})

test("drops front matter after blank lines, after a dropped directive, and twice", () => {
  const front = "---\nconfig:\n  htmlLabels: true\n---"
  assert.equal(source(`\n  \n${front}\nflowchart LR\n  A --> B`), "flowchart LR\n  A --> B")
  assert.equal(source(`%%{init: {}}%%\n${front}\nflowchart LR`), "flowchart LR")
  assert.equal(source(`${front}\n${front}\nflowchart LR`), "flowchart LR")
})

test("drops the rest after a front matter block with no end", () => {
  assert.equal(source("---\nconfig:\n  htmlLabels: true\nflowchart LR\n  A --> B"), "")
})

test("keeps a --- line after the diagram's first line", () => {
  const text = "flowchart LR\n---\n  A --> B"
  assert.equal(source(text), text)
})

test("drops each link, links and callback line, and keeps linkStyle", () => {
  const text = [
    "classDiagram",
    '  link Invoice "https://example.com/invoice" "Open"',
    '  callback Invoice "pay" "Pay"',
    '  class Invoice; LINKS Invoice: {"Docs": "https://example.com"}',
    "  Invoice --> Order",
    "  linkStyle 0 stroke:#888",
  ].join("\n")

  assert.equal(source(text), "classDiagram\n  Invoice --> Order\n  linkStyle 0 stroke:#888")
})

test("passes the secure list, with every HTML, CSS and link setting, to initialize", () => {
  const config = settings({primaryColor: "#eeeeee"})

  assert.deepEqual(config.secure, secure)
  for (const key of [
    "secure",
    "securityLevel",
    "startOnLoad",
    "maxTextSize",
    "suppressErrorRendering",
    "maxEdges",
    "htmlLabels",
    "dompurifyConfig",
    "themeCSS",
    "theme",
    "themeVariables",
    "fontFamily",
    "ticketBaseUrl",
  ])
    assert.ok(config.secure.includes(key), key)

  assert.equal(config.securityLevel, "strict")
  assert.equal(config.htmlLabels, false)
  assert.equal(config.maxTextSize, 20000)
  assert.equal(config.maxEdges, 200)
  assert.equal(config.theme, "base")
  assert.deepEqual(config.themeVariables, {primaryColor: "#eeeeee"})
})

test("the vendored Mermaid keeps htmlLabels off against a front matter config", async () => {
  // The front matter is not filtered here, so this shows the secure list alone. In Node,
  // parse applies the front matter's config, then stops at DOMPurify, which needs a
  // window; the config it applied is what render would draw with.
  const {default: mermaid} = await import("../../vendor/mermaid/mermaid.esm.min.mjs")

  // Without the secure list, the front matter turns HTML labels on: the check below
  // reaches the code that applies a front matter config.
  const {secure: _left, ...open} = settings({})
  mermaid.initialize(open)
  await mermaid.parse(FRONT_MATTER).catch(() => null)
  assert.equal(mermaid.mermaidAPI.getConfig().htmlLabels, true)

  mermaid.initialize(settings({}))
  await mermaid.parse(FRONT_MATTER).catch(() => null)
  const config = mermaid.mermaidAPI.getConfig()

  assert.equal(config.htmlLabels, false)
  assert.equal(config.flowchart?.htmlLabels, undefined)
  assert.equal(config.themeCSS, undefined)
  assert.equal(config.dompurifyConfig, undefined)
  assert.equal(config.securityLevel, "strict")
  assert.equal(config.theme, "base")
})
