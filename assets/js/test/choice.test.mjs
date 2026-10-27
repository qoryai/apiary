// What a choice field's search keeps (assets/js/hooks/choice.js, `matches`): an option
// whose title and subtitle hold every word typed, in any case and any order.
// `node --test 'assets/js/test/*.test.mjs'` (no npm).

import {test} from "node:test"
import assert from "node:assert/strict"

import {matches, putBack, words} from "../hooks/choice.js"

const OPUS = "Claude Opus 5.5 claude-opus-5-5"

test("an empty query, or one of spaces, keeps every option", () => {
  assert.equal(matches(OPUS, ""), true)
  assert.equal(matches(OPUS, "   "), true)
  assert.deepEqual(words("  "), [])
})

test("a query matches the title or the subtitle, in any case", () => {
  assert.equal(matches(OPUS, "opus"), true)
  assert.equal(matches(OPUS, "OPUS-5"), true)
  assert.equal(matches(OPUS, "sonnet"), false)
})

test("every word must match, in any order", () => {
  assert.equal(matches(OPUS, "5.5 claude"), true)
  assert.equal(matches(OPUS, "opus haiku"), false)
})

// Escape (`putBack`): the radio to check again, or none, in which case no change is sent.
const SOFTWARE = {value: "software"}
const GENERAL = {value: "general"}

test("Escape checks again the option chosen when the panel opened", () => {
  assert.equal(putBack(SOFTWARE, GENERAL), SOFTWARE)
})

test("Escape sends nothing when the choice did not change", () => {
  assert.equal(putBack(SOFTWARE, SOFTWARE), null)
  assert.equal(putBack(null, null), null)
})

test("Escape with nothing chosen at the start keeps the checked option, never none", () => {
  assert.equal(putBack(null, GENERAL), null)
})
