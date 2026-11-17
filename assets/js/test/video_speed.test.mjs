// A film's Speed row (assets/js/hooks/video_speed.js): a click on a button plays the film
// at the button's rate and presses that button; a rate set in the browser's player menu
// presses its button, or none.
// `node --test 'assets/js/test/*.test.mjs'` (no npm).

import {test} from "node:test"
import assert from "node:assert/strict"

import {VideoSpeed, mark, setRate} from "../hooks/video_speed.js"

// A button with what the hook reads: its `data-rate` and its `aria-pressed`, which
// starts "false", so that a test shows which button the hook presses.
const button = rate => {
  const el = {
    dataset: {rate},
    attributes: {"aria-pressed": "false"},
    setAttribute: (name, value) => (el.attributes[name] = value),
    closest: selector => (selector === "button[data-rate]" ? el : null),
  }
  return el
}

const pressed = buttons => buttons.map(b => b.attributes["aria-pressed"])

// A video that fires "ratechange" when its rate changes, as a browser's does.
const film = () => {
  const listeners = {}
  const video = {
    defaultPlaybackRate: 1,
    rate: 1,
    get playbackRate() {
      return this.rate
    },
    set playbackRate(rate) {
      this.rate = rate
      listeners.ratechange?.()
    },
    addEventListener: (type, fn) => (listeners[type] = fn),
    removeEventListener: (type, fn) => {
      if (listeners[type] === fn) delete listeners[type]
    },
    listeners,
  }
  return video
}

// The Speed row inside a `<figure>` with `video`, and the hook mounted on it. With no
// video, the row is in no figure. A click reaches the row's click listener, if it has one.
const row = video => {
  const buttons = ["0.5", "1", "1.5", "2"].map(button)
  const listeners = {}
  const figure = {querySelector: selector => (selector === "video" ? video : null)}
  const el = {
    closest: selector => (selector === "figure" && video ? figure : null),
    querySelectorAll: selector => (selector === "button[data-rate]" ? buttons : []),
    addEventListener: (type, fn) => (listeners[type] = fn),
  }
  const hook = Object.create(VideoSpeed)
  hook.el = el
  hook.mounted()
  const click = target => listeners.click?.({target})
  return {hook, buttons, click}
}

test("setRate plays the film at the rate, and keeps it as the default rate", () => {
  const video = film()
  setRate(video, 1.5)
  assert.equal(video.playbackRate, 1.5)
  assert.equal(video.defaultPlaybackRate, 1.5)
})

test("mark presses only the button of the rate, and none for a rate the row lacks", () => {
  const buttons = ["0.5", "1", "1.5", "2"].map(button)
  mark(buttons, 2)
  assert.deepEqual(pressed(buttons), ["false", "false", "false", "true"])
  mark(buttons, 1.25)
  assert.deepEqual(pressed(buttons), ["false", "false", "false", "false"])
})

test("a film starts at 1x with the 1x button pressed", () => {
  const video = film()
  const {buttons} = row(video)
  assert.equal(video.playbackRate, 1)
  assert.deepEqual(pressed(buttons), ["false", "true", "false", "false"])
})

test("a film already at 1.5x when the hook mounts has the 1.5x button pressed", () => {
  const video = film()
  video.playbackRate = 1.5
  const {buttons} = row(video)
  assert.deepEqual(pressed(buttons), ["false", "false", "true", "false"])
})

test("a click on 2x plays the film at 2x and presses 2x", () => {
  const video = film()
  const {buttons, click} = row(video)
  click(buttons[3])
  assert.equal(video.playbackRate, 2)
  assert.equal(video.defaultPlaybackRate, 2)
  assert.deepEqual(pressed(buttons), ["false", "false", "false", "true"])
  click(buttons[0])
  assert.equal(video.playbackRate, 0.5)
  assert.deepEqual(pressed(buttons), ["true", "false", "false", "false"])
})

test("a click between the buttons changes nothing", () => {
  const video = film()
  const {buttons, click} = row(video)
  click({closest: () => null})
  assert.equal(video.playbackRate, 1)
  assert.deepEqual(pressed(buttons), ["false", "true", "false", "false"])
})

test("a rate set in the browser's player menu presses its button, or none", () => {
  const video = film()
  const {buttons} = row(video)
  video.playbackRate = 1.5
  assert.deepEqual(pressed(buttons), ["false", "false", "true", "false"])
  video.playbackRate = 1.75
  assert.deepEqual(pressed(buttons), ["false", "false", "false", "false"])
})

test("the hook stops listening to the film once removed", () => {
  const video = film()
  const {hook} = row(video)
  hook.destroyed()
  assert.equal(video.listeners.ratechange, undefined)
})

test("a row with no video mounts, takes a click and is removed without an error", () => {
  const {hook, buttons, click} = row(null)
  assert.doesNotThrow(() => click(buttons[3]))
  assert.doesNotThrow(() => hook.destroyed())
  assert.deepEqual(pressed(buttons), ["false", "false", "false", "false"])
})
