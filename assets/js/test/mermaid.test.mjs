// What the Mermaid hook draws of a block (assets/js/hooks/mermaid.js, `source`): without
// its directive lines and its click lines; and the width it gives the <img> (`width`).
// `node --test 'assets/js/test/*.test.mjs'` (no npm).

import {test} from "node:test"
import assert from "node:assert/strict"

import {source, width} from "../hooks/mermaid.js"

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
