// The Watch link on the Verify tab (assets/js/hooks/watch_handoff.js): a plain click stores
// the film's version, place, time and speed for the next page; the next page takes the note
// once, for the film with that version id and place.
// `node --test 'assets/js/test/*.test.mjs'` (no npm).

import {test, beforeEach} from "node:test"
import assert from "node:assert/strict"

import {
  HANDOFF_KEY,
  WatchHandoff,
  applyHandoff,
  plainClick,
  storeHandoff,
  takeHandoff,
} from "../hooks/watch_handoff.js"

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

// A Watch link in a figure with `video`; `data-film` is the film's place among the films.
const link = (video, dataset = {version: "av_one", film: "0"}) => {
  const listeners = {}
  const el = {
    dataset,
    closest: selector => (selector === "figure" && video ? {querySelector: () => video} : null),
    addEventListener: (type, fn) => (listeners[type] = fn),
    removeEventListener: (type, fn) => {
      if (listeners[type] === fn) delete listeners[type]
    },
  }
  const hook = Object.create(WatchHandoff)
  hook.el = el
  hook.mounted()
  return {hook, click: (event = {button: 0}) => listeners.click(event), listeners}
}

const stored = () => JSON.parse(globalThis.sessionStorage.getItem(HANDOFF_KEY))

beforeEach(() => {
  globalThis.sessionStorage = storage()
})

test("a plain click on Watch stores the film's version, place, time and speed", () => {
  const {click} = link(film({currentTime: 4.2, playbackRate: 1.5}), {version: "av_one", film: "1"})
  click()
  assert.deepEqual(stored(), {version: "av_one", index: 1, time: 4.2, rate: 1.5})
})

test("a click that opens another tab or window, or saves the link, stores nothing", () => {
  const {click} = link(film({currentTime: 4.2}))
  for (const event of [
    {button: 0, ctrlKey: true},
    {button: 0, metaKey: true},
    {button: 0, shiftKey: true},
    {button: 0, altKey: true},
    {button: 1},
    {button: 2},
    {button: 0, defaultPrevented: true},
  ]) {
    click(event)
    assert.equal(globalThis.sessionStorage.getItem(HANDOFF_KEY), null, JSON.stringify(event))
  }
  click({button: 0})
  assert.notEqual(globalThis.sessionStorage.getItem(HANDOFF_KEY), null)
})

test("plainClick is the main button with no modifier key, not taken over", () => {
  assert.equal(plainClick({button: 0}), true)
  assert.equal(plainClick({button: 0, ctrlKey: false, defaultPrevented: false}), true)
  assert.equal(plainClick({button: 1}), false)
  assert.equal(plainClick({button: 0, metaKey: true}), false)
})

test("a click on a Watch link with no film in its figure stores nothing", () => {
  const {click} = link(null)
  assert.doesNotThrow(() => click())
  assert.equal(globalThis.sessionStorage.getItem(HANDOFF_KEY), null)
})

test("the link stops listening once removed", () => {
  const {hook, listeners} = link(film())
  hook.destroyed()
  assert.equal(listeners.click, undefined)
})

test("the note of this film is taken: its time and speed", () => {
  const items = storage()
  storeHandoff(items, "av_one", 0, film({currentTime: 7, playbackRate: 2}))
  assert.deepEqual(takeHandoff(items, "av_one", 0), {time: 7, rate: 2})
})

test("the note is deleted after use: a second take finds none", () => {
  const items = storage()
  storeHandoff(items, "av_one", 0, film({currentTime: 7, playbackRate: 2}))
  takeHandoff(items, "av_one", 0)
  assert.equal(items.getItem(HANDOFF_KEY), null)
  assert.equal(takeHandoff(items, "av_one", 0), null)
})

test("the note of another film is not applied, and is deleted", () => {
  const items = storage()
  storeHandoff(items, "av_one", 0, film({currentTime: 7, playbackRate: 2}))
  assert.equal(takeHandoff(items, "av_two", 0), null)
  assert.equal(items.getItem(HANDOFF_KEY), null)
})

test("the note of another film of the same version is not applied, and is deleted", () => {
  const items = storage()
  storeHandoff(items, "av_one", 1, film({currentTime: 7, playbackRate: 2}))
  assert.equal(takeHandoff(items, "av_one", 0), null)
  assert.equal(items.getItem(HANDOFF_KEY), null)
})

test("a note that is not a time and a speed is not applied, and is deleted", () => {
  for (const note of [
    "not json",
    "null",
    "{",
    JSON.stringify({version: "av_one", index: 0, time: "4", rate: 1}),
    JSON.stringify({version: "av_one", index: 0, time: -1, rate: 1}),
    JSON.stringify({version: "av_one", index: 0, time: 1, rate: 0}),
    JSON.stringify({version: "av_one", index: 0, time: null, rate: 1}),
    JSON.stringify({version: "av_one", time: 1, rate: 1}),
  ]) {
    const items = storage()
    items.setItem(HANDOFF_KEY, note)
    assert.equal(takeHandoff(items, "av_one", 0), null, note)
    assert.equal(items.getItem(HANDOFF_KEY), null, note)
  }
})

test("a storage that is missing or refuses gives no note and takes none", () => {
  assert.equal(takeHandoff(null, "av_one", 0), null)
  assert.doesNotThrow(() => storeHandoff(null, "av_one", 0, film()))
  const refusing = {
    getItem: () => {
      throw new Error("refused")
    },
    setItem: () => {
      throw new Error("refused")
    },
    removeItem: () => {
      throw new Error("refused")
    },
  }
  assert.equal(takeHandoff(refusing, "av_one", 0), null)
  assert.doesNotThrow(() => storeHandoff(refusing, "av_one", 0, film()))
})

test("a storage that reads but refuses to delete still gives the note", () => {
  const items = storage()
  storeHandoff(items, "av_one", 0, film({currentTime: 7, playbackRate: 2}))
  items.removeItem = () => {
    throw new Error("refused")
  }
  assert.deepEqual(takeHandoff(items, "av_one", 0), {time: 7, rate: 2})
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
