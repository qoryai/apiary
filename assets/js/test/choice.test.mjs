// What a choice field's search keeps (assets/js/hooks/choice.js, `matches`): an option
// whose title and subtitle hold every word typed, in any case and any order.
// `node --test 'assets/js/test/*.test.mjs'` (no npm).

import {test} from "node:test"
import assert from "node:assert/strict"

import {matches, narrowed, next, putBack, words} from "../hooks/choice.js"

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

// A search over groups (`narrowed`): a heading shows while one of its options does.
const option = (text, extra = {}) => ({text, keep: false, disabled: false, checked: false, ...extra})
const SOURCES = [
  {options: [option("Reading…", {disabled: true})]},
  {options: [option("example-org/shared-harness"), option("example-org/ops")]},
  {options: [option("Enter an address")]},
]

test("a search hides the heading of a group with no match, and counts every group", () => {
  const {groups, found, total} = narrowed(SOURCES, "harness")
  assert.deepEqual(groups.map(g => g.heading), [false, true, false])
  assert.deepEqual(groups[1].options, [true, false])
  assert.equal(found, 1)
  // Reading… is not an option to count.
  assert.equal(total, 3)
})

test("without a query every heading shows, an empty group's too", () => {
  const {groups} = narrowed([{options: []}, ...SOURCES], "")
  assert.deepEqual(groups.map(g => g.heading), [true, true, true, true])
})

test("a group keeps its heading for its chosen or kept option", () => {
  const {groups} = narrowed(
    [{options: [option("Claude Opus 5.5", {checked: true})]}, {options: [option("Another model", {keep: true})]}],
    "deepseek"
  )
  assert.deepEqual(groups.map(g => g.heading), [true, true])
})

// The keys' next option (`next`): never a disabled one or one the search hides.
const ROWS = [{disabled: true}, {}, {hidden: true}, {}, {disabled: true}]

test("the keys pass over disabled and hidden options, around the ends", () => {
  assert.equal(next(ROWS, -1, 1), 1)
  assert.equal(next(ROWS, -1, -1), 3)
  assert.equal(next(ROWS, 1, 1), 3)
  assert.equal(next(ROWS, 3, 1), 1)
  assert.equal(next(ROWS, 1, -1), 3)
})

test("with every option disabled the keys go nowhere", () => {
  assert.equal(next([{disabled: true}], -1, 1), -1)
  assert.equal(next([], -1, 1), -1)
})
