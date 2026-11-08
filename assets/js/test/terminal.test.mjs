// The pure parts of the Terminal hook (assets/js/hooks/terminal.js): the recorded size, the
// counts it drops, where a write stops for a marked line, and the view a box opens in.
// `node --test 'assets/js/test/*.test.mjs'` (no npm).

import {test} from "node:test"
import assert from "node:assert/strict"

import {
  MOST_LINES_MOVED,
  MOST_REPEATS,
  SUBAGENT_BUTTONS,
  Terminal,
  fill,
  openingView,
  transcriptFollowing,
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

test("a link to a line of the Transcript opens it, whatever the reader chose", () => {
  assert.equal(openingView("transcript", "raw", true, true), "transcript")
  assert.equal(openingView("raw", "raw", true, true), "transcript")
  assert.equal(openingView("raw", null, false, true), "transcript")
})

test("a box with no choice keeps the view the server set", () => {
  assert.equal(openingView("transcript", "raw", false), "transcript")
})

test("a template fills its bindings and keeps an unknown one", () => {
  assert.equal(fill("%{index} of %{total}", {index: 2, total: 5}), "2 of 5")
  assert.equal(fill("%{size} px", {}), "%{size} px")
})

test("the Transcript's end button reads Following only on a live run read at its end", () => {
  assert.equal(transcriptFollowing(true, true), true)
  assert.equal(transcriptFollowing(true, false), false)
  assert.equal(transcriptFollowing(false, true), false)
})

// A Transcript box at y 100 of the page, scrolled `scrollTop` into 2000 px of lines.
const fakeLine = (id, top) => ({
  id,
  top,
  getBoundingClientRect() {
    return {top: this.top, bottom: this.top + 20}
  },
})

const fakeHook = lines => {
  const transcript = {
    scrollTop: 400,
    scrollHeight: 2000,
    getBoundingClientRect: () => ({top: 100}),
    querySelector: selector => lines.find(line => selector === `[id="${line.id}"]`) || null,
    querySelectorAll: selector => (selector === "ol > li" ? lines : []),
  }
  return Object.assign(Object.create(Terminal), {
    transcript,
    view: "transcript",
    live: true,
    transcriptAtEnd: true,
    held: null,
    trEndButton: null,
  })
}

const click = (line, matches = true) => {
  const button = {closest: selector => (selector === "li" ? line : null)}
  return {target: {closest: selector => (matches && selector === SUBAGENT_BUTTONS ? button : null)}}
}

test("a subagent's caret stops following the end and keeps its head where it was", () => {
  const head = fakeLine("e-5", 300)
  const hook = fakeHook([fakeLine("e-3", 260), head])

  hook.holdLine(click(head))
  assert.equal(hook.transcriptAtEnd, false)

  // The lines open: the patch moved the head 150 px down; the box scrolls it back.
  head.top = 450
  hook.placeTranscript()
  assert.equal(hook.transcript.scrollTop, 550)

  // A later patch that leaves the head where it was writes nothing.
  hook.transcript.scrollTop = 1234
  head.top = 300
  hook.placeTranscript()
  assert.equal(hook.transcript.scrollTop, 1234)
})

test("Expand all keeps the first line on screen where it was", () => {
  const above = fakeLine("e-3", 60)
  const first = fakeLine("e-4", 110)
  const hook = fakeHook([above, first])

  hook.holdLine({target: {closest: s => (s === SUBAGENT_BUTTONS ? {closest: () => null} : null)}})
  first.top = 90
  hook.placeTranscript()
  assert.equal(hook.transcript.scrollTop, 380)
})

test("another click leaves the Transcript following its end", () => {
  const head = fakeLine("e-5", 300)
  const hook = fakeHook([head])

  hook.holdLine(click(head, false))
  assert.equal(hook.transcriptAtEnd, true)
  hook.placeTranscript()
  assert.equal(hook.transcript.scrollTop, 2000)
})
