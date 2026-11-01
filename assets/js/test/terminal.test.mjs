// The pure parts of the Terminal hook (assets/js/hooks/terminal.js): the recorded size, the
// counts it drops, where a write stops for a marked line, and the view a box opens in.
// `node --test 'assets/js/test/*.test.mjs'` (no npm).

import {test} from "node:test"
import assert from "node:assert/strict"

import {
  MOST_LINES_MOVED,
  MOST_REPEATS,
  fill,
  openingView,
  overCount,
  size,
  stopAt,
} from "../hooks/terminal.js"

test("a size is two integers a terminal can be", () => {
  assert.deepEqual(size("120x40"), [120, 40])
  assert.equal(size("0x40"), null)
  assert.equal(size("120x"), null)
  assert.equal(size("99999x40"), null)
  assert.equal(size(null), null)
})

test("a scroll of more lines than any screen has is dropped", () => {
  // CSI 10000000 S: 16 bytes that held the page for 7.2 s.
  assert.equal(overCount([10000000], MOST_LINES_MOVED), true)
  assert.equal(overCount([2147483647], MOST_LINES_MOVED), true)
  assert.equal(overCount([MOST_LINES_MOVED], MOST_LINES_MOVED), false)
  assert.equal(overCount([3], MOST_LINES_MOVED), false)
})

test("a count with sub-parameters is read from its first number", () => {
  assert.equal(overCount([[MOST_REPEATS + 1, 2]], MOST_REPEATS), true)
  assert.equal(overCount([[5, 2]], MOST_REPEATS), false)
})

test("a sequence with no count is carried out", () => {
  assert.equal(overCount([], MOST_LINES_MOVED), false)
})

test("a write stops before the marked byte when the mark falls inside it", () => {
  assert.equal(stopAt(1000, 500, 1200), 200)
})

test("a write runs whole when the mark is outside it, at its start or absent", () => {
  assert.equal(stopAt(1000, 500, 900), 500)
  assert.equal(stopAt(1000, 500, 1500), 500)
  assert.equal(stopAt(1000, 500, 1000), 500)
  assert.equal(stopAt(1000, 500, null), 500)
})

test("a run on pipes with a Transcript opens in the reader's view", () => {
  assert.equal(openingView("transcript", null, true), "transcript")
  assert.equal(openingView("transcript", "raw", true), "raw")
  assert.equal(openingView("transcript", "transcript", true), "transcript")
})

test("the Collapsed view kept as a choice opens the Transcript", () => {
  assert.equal(openingView("transcript", "collapsed", true), "transcript")
})

test("a run with no Transcript, or on a pseudo-terminal, opens in Raw", () => {
  assert.equal(openingView("raw", "transcript", true), "raw")
  assert.equal(openingView("raw", "transcript", false), "raw")
})

test("a box with no choice keeps the view the server set", () => {
  assert.equal(openingView("transcript", "raw", false), "transcript")
})

test("a template fills its bindings and keeps an unknown one", () => {
  assert.equal(fill("%{index} of %{total}", {index: 2, total: 5}), "2 of 5")
  assert.equal(fill("%{size} px", {}), "%{size} px")
})
