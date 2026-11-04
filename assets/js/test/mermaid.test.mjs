// What the Mermaid hook draws of a block (assets/js/hooks/mermaid.js, `source`): without
// its directive lines, its front matter, and its click, link, links and callback lines;
// the settings it passes to mermaid.initialize (`settings`), with the secure list that
// the vendored Mermaid applies to a document's front matter; the blocks it does not draw,
// as drawing them would load an address (`loads`); the redraw on a theme change
// (`watchTheme`); and the width it gives the <img> (`width`). `node --test 'assets/js/test/*.test.mjs'` (no npm).

import {test} from "node:test"
import assert from "node:assert/strict"

import {dompurifyConfig, loads, secure, settings, source, watchTheme, width} from "../hooks/mermaid.js"

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

test("drops a class diagram's link and callback statements, and keeps linkStyle", () => {
  const text = [
    "classDiagram",
    '  link Invoice "https://example.com/invoice" "Open"',
    '  callback Invoice "pay" "Pay"',
    '  class Order; LINK Order "https://example.com/order"',
    '  click Invoice href "https://example.com"',
    "  Invoice --> Order",
    "  linkStyle 0 stroke:#888",
  ].join("\n")

  assert.equal(source(text), "classDiagram\n  Invoice --> Order\n  linkStyle 0 stroke:#888")
})

test("drops a sequence diagram's link and links statements", () => {
  const text = [
    "sequenceDiagram",
    "  participant Alice",
    "  link Alice: Dashboard @ https://example.com/dashboard",
    '  links Alice: {"Docs": "https://example.com/docs"}',
    "  Alice->>Bob: Send the invoice",
  ].join("\n")

  assert.equal(
    source(text),
    "sequenceDiagram\n  participant Alice\n  Alice->>Bob: Send the invoice",
  )
})

test("keeps a flowchart node called link, links or callback", () => {
  const text = [
    "flowchart LR",
    "  link --> B",
    "  links --> callback",
    "  callback -->|pay: now| link",
    "  link-->C",
    '  link --> D["Invoice"]',
  ].join("\n")

  assert.equal(source(text), text)
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
  assert.deepEqual(config.dompurifyConfig, dompurifyConfig)
  assert.equal(config.securityLevel, "strict")
  assert.equal(config.theme, "base")
})

test("does not draw a flowchart node's image, written in any way YAML reads", () => {
  assert.equal(loads('flowchart LR\n  A@{ img: "/acme/logo.png", label: "Logo" }'), true)
  assert.equal(loads('flowchart LR\n  A@{\n  "IMG": "https://example.com/a.png"\n  }'), true)
  assert.equal(loads('flowchart LR\n  A@{ "\\x69mg": "/a.png" }'), true)
  assert.equal(loads("flowchart LR\n  A@{ shape: rect, label: \"Invoice\" }\n  A --> B"), false)
})

test("draws imgur, and img outside a node data block", () => {
  const text = [
    "flowchart LR",
    "  A[Upload to imgur] --> B@{ shape: rect, label: \"imgur: the host\" }",
    "  B --> C[img: the tag]",
  ].join("\n")
  assert.equal(loads(text), false)
})

test("does not draw a node data block with the word img in it, even in a label", () => {
  assert.equal(loads("flowchart LR\n  A@{ label: it's, img: \"/x\", other: 'y' }"), true)
  assert.equal(loads("flowchart LR\n  A@{ label: it's, img: \"/acme/q1\", other: 'y' }"), true)
  assert.equal(loads("flowchart LR\n  C@{ shape: circle, label: 'img: the tag' }"), true)
})

test("finds an img key after a quoted closing brace and in a later block", () => {
  assert.equal(loads('flowchart LR\n  A@{ label: "a } b", img: "/a.png" }'), true)
  assert.equal(loads('flowchart LR\n  A@{ label: "x", "img": "/q.png" }'), true)
  assert.equal(loads('flowchart LR\n  A@{ shape: rect }\n  B@{ shape: rect, img: "/b.png" }'), true)
  assert.equal(loads('flowchart LR\n  A@{ shape: rect, label: {img: "/c.png"} }'), true)
  assert.equal(loads('flowchart LR\n  A@{ shape: rect, &k img: "/d.png" }'), true)
  assert.equal(loads('flowchart LR\n  A@{ shape: rect, img: "/e.png"'), true)
})

test("does not draw a sequence diagram's properties line, whose icon is an image", () => {
  const text = 'sequenceDiagram\n  participant Alice\n  properties Alice: {"icon": "/acme/a.png"}'
  assert.equal(loads(text), true)
  assert.equal(loads("sequenceDiagram\n  Alice->>Bob: properties of the invoice"), false)
})

test("does not draw an eventmodeling diagram with markup in it", () => {
  assert.equal(loads("eventmodeling\ntf 01 cmd A {<b>x</b> }"), true)
  assert.equal(loads("%% Invoices\n\n  eventmodeling\ntf 01 cmd A {<b>x</b> }"), true)
  assert.equal(loads("eventmodeling\ntf 01 cmd A { x }"), false)
  assert.equal(loads("flowchart LR\n  A[\"a < b\"] --> B"), false)
})

test("does not draw CSS that loads an address, escaped or not", () => {
  for (const text of [
    "flowchart LR\n  A --> B\n  style A fill:url(https://example.com/a.svg#p)",
    "flowchart LR\n  classDef c fill:URL(/a.svg#p)",
    "flowchart LR\n  classDef c fill:\\75 rl(/a.svg#p)",
    "flowchart LR\n  classDef c fill:u\\rl(/a.svg#p)",
    "flowchart LR\n  linkStyle 0 stroke:image-set(\"/a.png\" 1x)",
    "flowchart LR\n  style A fill:-webkit-image-set(\"/a.png\" 1x)",
    "flowchart LR\n  style A fill:red; @import \"/a.css\"",
    'C4Context\n  UpdateElementStyle(a, $bgColor="url(/a.svg#p)")',
  ])
    assert.equal(loads(text), true, text)
})

test("draws a diagram with no address", () => {
  const text = [
    "flowchart LR",
    "  A[Upload image] --> B(Invoice total)",
    "  classDef total fill:#eef,stroke:#88a",
    "  class B total",
    "  linkStyle 0 stroke:#888",
  ].join("\n")
  assert.equal(loads(text), false)
})

// A MutationObserver stand-in: it keeps what it observes, and `fire` runs its callback.
class FakeObserver {
  static last = null
  constructor(callback) {
    this.callback = callback
    this.disconnected = false
    FakeObserver.last = this
  }
  observe(target, options) {
    this.target = target
    this.options = options
  }
  disconnect() {
    this.disconnected = true
  }
  fire() {
    this.callback([])
  }
}

test("draws again when data-theme on <html> changes, and only then", () => {
  let redraws = 0
  const html = {
    value: "qory-light",
    getAttribute: name => (name === "data-theme" ? html.value : null),
  }
  const stop = watchTheme(html, () => redraws++, FakeObserver)
  const observer = FakeObserver.last

  assert.equal(observer.target, html)
  assert.deepEqual(observer.options, {attributes: true, attributeFilter: ["data-theme"]})

  html.value = "qory-dark"
  observer.fire()
  assert.equal(redraws, 1)

  // The same value again, such as the system theme set once more: no redraw.
  observer.fire()
  assert.equal(redraws, 1)

  html.value = "qory-light"
  observer.fire()
  assert.equal(redraws, 2)

  stop()
  assert.equal(observer.disconnected, true)
})

test("watches nothing where there is no MutationObserver", () => {
  const html = {getAttribute: () => "qory-light"}
  const stop = watchTheme(html, () => assert.fail("no redraw"), undefined)
  assert.equal(typeof stop, "function")
  stop()
})

test("Mermaid's sanitizer drops what loads, links or styles, in every text it sanitizes", () => {
  const config = settings({})
  assert.equal(config.dompurifyConfig, dompurifyConfig)
  assert.ok(config.secure.includes("dompurifyConfig"))

  for (const tag of ["img", "image", "picture", "source", "video", "audio", "iframe"])
    assert.ok(dompurifyConfig.FORBID_TAGS.includes(tag), tag)
  for (const tag of ["object", "embed", "form", "input", "a", "svg", "use", "style"])
    assert.ok(dompurifyConfig.FORBID_TAGS.includes(tag), tag)
  for (const attr of ["style", "class", "id", "src", "srcset", "href", "xlink:href"])
    assert.ok(dompurifyConfig.FORBID_ATTR.includes(attr), attr)
  for (const attr of ["background", "poster"]) assert.ok(dompurifyConfig.FORBID_ATTR.includes(attr))
})

test("the vendored Mermaid sanitizes with the site's dompurifyConfig", async () => {
  // Mermaid's sanitizeText uses the dompurifyConfig of the config it is given, Mermaid's
  // current config, where there is one. DOMPurify needs a window, so in Node this shows
  // that the setting reaches that config, and that a directive cannot replace it.
  const {default: mermaid} = await import("../../vendor/mermaid/mermaid.esm.min.mjs")
  mermaid.initialize(settings({}))
  await mermaid.parse('%%{init: {"dompurifyConfig": {"ADD_TAGS": ["img"]}}}%%\nflowchart LR\n  A').catch(() => null)
  assert.deepEqual(mermaid.mermaidAPI.getConfig().dompurifyConfig, dompurifyConfig)
})
