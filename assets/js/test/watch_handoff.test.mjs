// The Watch link on the Verify tab (assets/js/hooks/watch_handoff.js): a click stores the
// film's version, time and speed for the next page; the next page takes the note once, for
// its own film only. `node --test 'assets/js/test/*.test.mjs'` (no npm).

import {test, beforeEach} from "node:test"
import assert from "node:assert/strict"

import {HANDOFF_KEY, WatchHandoff, applyHandoff, storeHandoff, takeHandoff} from "../hooks/watch_handoff.js"

const storage = () => {
  const map = new Map()
  return {
    getItem: key => (map.has(key) ? map.get(key) : null),
    setItem: (key, value) => map.set(key, String(value)),
    removeItem: key => map.delete(key),
  }
}

const film = (extra = {}) => {
  const listeners = {}
  return {
    defaultPlaybackRate: 1,
    playbackRate: 1,
    currentTime: 0,
    readyState: 0,
    addEventListener: (type, fn) => (listeners[type] = fn),
    fire: type => listeners[type]?.(),
    ...extra,
  }
}

beforeEach(() => {
  globalThis.sessionStorage = storage()
})

test("a click on Watch stores the film's version, time and speed", () => {
  const video = film({currentTime: 4.2, playbackRate: 1.5})
  const listeners = {}
  const el = {
    dataset: {version: "av_one"},
    closest: selector => (selector === "figure" ? {querySelector: () => video} : null),
    addEventListener: (type, fn) => (listeners[type] = fn),
    removeEventListener: () => {},
  }
  const hook = Object.create(WatchHandoff)
  hook.el = el
  hook.mounted()
  listeners.click()
  assert.deepEqual(JSON.parse(globalThis.sessionStorage.getItem(HANDOFF_KEY)), {
    version: "av_one",
    time: 4.2,
    rate: 1.5,
  })
})

test("a click on a Watch link with no film in its figure stores nothing", () => {
  const listeners = {}
  const el = {
    dataset: {version: "av_one"},
    closest: () => null,
    addEventListener: (type, fn) => (listeners[type] = fn),
  }
  const hook = Object.create(WatchHandoff)
  hook.el = el
  hook.mounted()
  assert.doesNotThrow(() => listeners.click())
  assert.equal(globalThis.sessionStorage.getItem(HANDOFF_KEY), null)
})

test("the note of this film is taken: its time and speed", () => {
  const items = storage()
  storeHandoff(items, "av_one", film({currentTime: 7, playbackRate: 2}))
  assert.deepEqual(takeHandoff(items, "av_one"), {time: 7, rate: 2})
})

test("the note is deleted after use: a second take finds none", () => {
  const items = storage()
  storeHandoff(items, "av_one", film({currentTime: 7, playbackRate: 2}))
  takeHandoff(items, "av_one")
  assert.equal(items.getItem(HANDOFF_KEY), null)
  assert.equal(takeHandoff(items, "av_one"), null)
})

test("the note of another film is not applied, and is deleted", () => {
  const items = storage()
  storeHandoff(items, "av_one", film({currentTime: 7, playbackRate: 2}))
  assert.equal(takeHandoff(items, "av_two"), null)
  assert.equal(items.getItem(HANDOFF_KEY), null)
})

test("a note that is not a time and a speed is not applied", () => {
  for (const note of [
    "not json",
    "null",
    JSON.stringify({version: "av_one", time: "4", rate: 1}),
    JSON.stringify({version: "av_one", time: -1, rate: 1}),
    JSON.stringify({version: "av_one", time: 1, rate: 0}),
    JSON.stringify({version: "av_one", time: null, rate: 1}),
  ]) {
    const items = storage()
    items.setItem(HANDOFF_KEY, note)
    assert.equal(takeHandoff(items, "av_one"), null)
  }
})

test("a storage that is missing or refuses gives no note and takes none", () => {
  assert.equal(takeHandoff(null, "av_one"), null)
  assert.doesNotThrow(() => storeHandoff(null, "av_one", film()))
  const refusing = {
    getItem: () => {
      throw new Error("refused")
    },
    setItem: () => {
      throw new Error("refused")
    },
  }
  assert.equal(takeHandoff(refusing, "av_one"), null)
  assert.doesNotThrow(() => storeHandoff(refusing, "av_one", film()))
})

test("the note sets the time at once for a film whose length is known, else when it is", () => {
  const known = film({readyState: 1})
  applyHandoff(known, {time: 4, rate: 1.5})
  assert.equal(known.currentTime, 4)
  assert.equal(known.playbackRate, 1.5)

  const loading = film()
  applyHandoff(loading, {time: 4, rate: 1.5})
  assert.equal(loading.currentTime, 0)
  assert.equal(loading.playbackRate, 1.5)
  loading.fire("loadedmetadata")
  assert.equal(loading.currentTime, 4)
})

test("applying the note does not start the film", () => {
  const video = film({readyState: 1, play: () => assert.fail("the film must not start")})
  applyHandoff(video, {time: 1, rate: 1})
})
