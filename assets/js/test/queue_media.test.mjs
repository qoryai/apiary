// One item of the Scenarios queue (assets/js/hooks/queue_media.js): the film's length, read
// from the thumbnail's metadata, written into the item's line, and written again after a
// patch of the page. `node --test 'assets/js/test/*.test.mjs'` (no npm).

import {test} from "node:test"
import assert from "node:assert/strict"

import {QueueMedia, formatLength} from "../hooks/queue_media.js"

const item = ({video = true, readyState = 0, duration = NaN} = {}) => {
  const listeners = {}
  const thumbnail = {
    duration,
    readyState,
    muted: false,
    addEventListener: (type, fn) => (listeners[type] = fn),
    removeEventListener: (type, fn) => {
      if (listeners[type] === fn) delete listeners[type]
    },
    listeners,
  }
  const line = {textContent: "Video", dataset: {length: "Demo video · %{length}"}}
  const el = {
    querySelector: selector =>
      selector === "video" ? (video ? thumbnail : null) : selector === "[data-length]" ? line : null,
  }
  const hook = Object.create(QueueMedia)
  hook.el = el
  hook.mounted()
  return {hook, thumbnail, line}
}

test("formatLength is minutes and two-digit seconds, rounded down", () => {
  assert.equal(formatLength(10), "0:10")
  assert.equal(formatLength(10.9), "0:10")
  assert.equal(formatLength(9), "0:09")
  assert.equal(formatLength(75), "1:15")
  assert.equal(formatLength(3600), "60:00")
  assert.equal(formatLength(0), "0:00")
})

test("formatLength is nil for a length the browser does not give", () => {
  for (const length of [NaN, Infinity, -1, undefined, null, "10"]) {
    assert.equal(formatLength(length), null)
  }
})

test("the line reads the length once the thumbnail's metadata loads", () => {
  const {thumbnail, line} = item()
  assert.equal(thumbnail.muted, true)
  assert.equal(line.textContent, "Video")
  thumbnail.duration = 10
  thumbnail.listeners.loadedmetadata()
  assert.equal(line.textContent, "Demo video · 0:10")
})

test("a thumbnail whose metadata is already there fills the line on mount", () => {
  const {line} = item({readyState: 1, duration: 75})
  assert.equal(line.textContent, "Demo video · 1:15")
})

test("a patch that puts the server's text back is followed by the length again", () => {
  const {hook, line} = item({readyState: 1, duration: 10})
  line.textContent = "Video"
  hook.updated()
  assert.equal(line.textContent, "Demo video · 0:10")
})

test("a length the browser does not give leaves the server's text", () => {
  const {thumbnail, line} = item()
  thumbnail.duration = Infinity
  thumbnail.listeners.loadedmetadata()
  assert.equal(line.textContent, "Video")
})

test("an item with no film (a set of pictures) mounts, takes a patch and is removed", () => {
  const {hook, line} = item({video: false})
  assert.doesNotThrow(() => hook.updated())
  assert.doesNotThrow(() => hook.destroyed())
  assert.equal(line.textContent, "Video")
})

test("the hook stops listening once removed", () => {
  const {hook, thumbnail} = item()
  hook.destroyed()
  assert.equal(thumbnail.listeners.loadedmetadata, undefined)
})
