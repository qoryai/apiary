// The controls under a version page's player (assets/js/hooks/artifact_player.js): Cinema
// kept in the browser's storage across pages, Full screen on the player's `<figure>`, and
// the Watch note applied to the film. `node --test 'assets/js/test/*.test.mjs'` (no npm).

import {test, beforeEach} from "node:test"
import assert from "node:assert/strict"

import {ArtifactPlayer, CINEMA_KEY, readCinema, writeCinema} from "../hooks/artifact_player.js"
import {HANDOFF_KEY} from "../hooks/watch_handoff.js"

// A Storage with a `Map`.
const storage = (items = {}) => {
  const map = new Map(Object.entries(items))
  return {
    map,
    getItem: key => (map.has(key) ? map.get(key) : null),
    setItem: (key, value) => map.set(key, String(value)),
    removeItem: key => map.delete(key),
  }
}

// An element that takes listeners and fires them.
const target = extra => {
  const listeners = {}
  return {
    listeners,
    addEventListener: (type, fn) => (listeners[type] = fn),
    removeEventListener: (type, fn) => {
      if (listeners[type] === fn) delete listeners[type]
    },
    fire: (type, event = {}) => listeners[type]?.(event),
    ...extra,
  }
}

const button = (dataset = {}) => {
  const attributes = {}
  const classes = new Set()
  const text = {textContent: "Full screen"}
  const icon = {classList: {toggle: (name, on) => (on ? classes.add(name) : classes.delete(name))}}
  return target({
    dataset,
    attributes,
    classes,
    text,
    hidden: false,
    setAttribute: (name, value) => (attributes[name] = value),
    getAttribute: name => attributes[name],
    querySelector: selector => (selector === "[data-text]" ? text : selector === "[data-icon]" ? icon : null),
  })
}

const film = () => {
  const video = target({defaultPlaybackRate: 1, playbackRate: 1, currentTime: 0, readyState: 0})
  return video
}

// The hook mounted on the controls of a player: a `<figure>` with `video`, and the
// controls with Cinema and Full screen. `fullscreen` is false for a browser with none.
const mount = ({video = film(), fullscreen = true, version = "av_one"} = {}) => {
  const cinema = button()
  const full = button({
    title: "Full screen",
    label: "Full screen",
    leaveTitle: "Leave full screen (Esc)",
    leaveLabel: "Leave full screen",
  })
  const box = {querySelector: selector => (selector === "video" ? video : null)}
  if (fullscreen) box.requestFullscreen = () => (globalThis.document.fullscreenElement = box)
  const el = {
    dataset: {version},
    closest: selector => (selector === "figure" ? box : null),
    querySelector: selector =>
      selector === "[data-cinema-toggle]" ? cinema : selector === "[data-full-screen]" ? full : null,
  }
  const hook = Object.create(ArtifactPlayer)
  hook.el = el
  hook.mounted()
  return {hook, el, cinema, full, box, video}
}

beforeEach(() => {
  globalThis.localStorage = storage()
  globalThis.sessionStorage = storage()
  globalThis.document = target({
    fullscreenElement: null,
    exitFullscreen: () => {
      globalThis.document.fullscreenElement = null
    },
  })
})

test("readCinema and writeCinema keep Cinema on, or off, in the storage", () => {
  const items = storage()
  assert.equal(readCinema(items), false)
  writeCinema(items, true)
  assert.equal(items.getItem(CINEMA_KEY), "on")
  assert.equal(readCinema(items), true)
  writeCinema(items, false)
  assert.equal(items.getItem(CINEMA_KEY), null)
  assert.equal(readCinema(items), false)
})

test("a storage that refuses is read as Cinema off, and written to without an error", () => {
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
  assert.equal(readCinema(refusing), false)
  assert.doesNotThrow(() => writeCinema(refusing, true))
  assert.equal(readCinema(null), false)
})

test("Cinema starts off, with the button not pressed", () => {
  const {el, cinema} = mount()
  assert.equal(el.dataset.cinema, "false")
  assert.equal(cinema.getAttribute("aria-pressed"), "false")
})

test("a click on Cinema presses it, sets data-cinema and keeps it in the storage", () => {
  const {el, cinema} = mount()
  cinema.fire("click")
  assert.equal(el.dataset.cinema, "true")
  assert.equal(cinema.getAttribute("aria-pressed"), "true")
  assert.equal(globalThis.localStorage.getItem(CINEMA_KEY), "on")
  cinema.fire("click")
  assert.equal(el.dataset.cinema, "false")
  assert.equal(cinema.getAttribute("aria-pressed"), "false")
  assert.equal(globalThis.localStorage.getItem(CINEMA_KEY), null)
})

test("Cinema stays on across pages: the next page's hook reads it on mount", () => {
  mount().cinema.fire("click")
  // The next page: a new element, the same storage.
  const next = mount({version: "av_two"})
  assert.equal(next.el.dataset.cinema, "true")
  assert.equal(next.cinema.getAttribute("aria-pressed"), "true")
})

test("Full screen shows the player's figure in full screen, and the button reads Leave full screen", () => {
  const {full, box} = mount()
  full.fire("click")
  assert.equal(globalThis.document.fullscreenElement, box)
  globalThis.document.fire("fullscreenchange")
  assert.equal(full.getAttribute("aria-pressed"), "true")
  assert.equal(full.getAttribute("title"), "Leave full screen (Esc)")
  assert.equal(full.text.textContent, "Leave full screen")
  assert.ok(full.classes.has("hero-arrows-pointing-in-micro"))
  assert.ok(!full.classes.has("hero-arrows-pointing-out-micro"))
})

test("Escape or the button leaves full screen, and the button reads Full screen again", () => {
  const {full} = mount()
  full.fire("click")
  globalThis.document.fire("fullscreenchange")
  full.fire("click")
  assert.equal(globalThis.document.fullscreenElement, null)
  globalThis.document.fire("fullscreenchange")
  assert.equal(full.getAttribute("aria-pressed"), "false")
  assert.equal(full.getAttribute("title"), "Full screen")
  assert.equal(full.text.textContent, "Full screen")
  assert.ok(full.classes.has("hero-arrows-pointing-out-micro"))
})

test("another element in full screen does not press the button", () => {
  const {full} = mount()
  globalThis.document.fullscreenElement = {}
  globalThis.document.fire("fullscreenchange")
  assert.equal(full.getAttribute("aria-pressed"), "false")
})

test("a browser with no full screen has no Full screen button", () => {
  const {full, cinema} = mount({fullscreen: false})
  assert.equal(full.hidden, true)
  assert.equal(cinema.hidden, false)
})

test("a note for this film opens it at the note's time and speed, deletes the note, and does not play", () => {
  globalThis.sessionStorage.setItem(
    HANDOFF_KEY,
    JSON.stringify({version: "av_one", time: 4.5, rate: 1.5}),
  )
  const video = film()
  video.readyState = 1
  video.play = () => assert.fail("the film must not start")
  mount({video})
  assert.equal(video.currentTime, 4.5)
  assert.equal(video.playbackRate, 1.5)
  assert.equal(video.defaultPlaybackRate, 1.5)
  assert.equal(globalThis.sessionStorage.getItem(HANDOFF_KEY), null)
})

test("a note for another film changes nothing and is deleted", () => {
  globalThis.sessionStorage.setItem(
    HANDOFF_KEY,
    JSON.stringify({version: "av_other", time: 4.5, rate: 2}),
  )
  const video = film()
  video.readyState = 1
  mount({video})
  assert.equal(video.currentTime, 0)
  assert.equal(video.playbackRate, 1)
  assert.equal(globalThis.sessionStorage.getItem(HANDOFF_KEY), null)
})

test("a note applies its time when the film's length is known", () => {
  globalThis.sessionStorage.setItem(
    HANDOFF_KEY,
    JSON.stringify({version: "av_one", time: 3, rate: 0.5}),
  )
  const video = film()
  mount({video})
  assert.equal(video.currentTime, 0)
  assert.equal(video.playbackRate, 0.5)
  video.fire("loadedmetadata")
  assert.equal(video.currentTime, 3)
})

test("no note leaves the film at 0:00 and 1x", () => {
  const video = film()
  mount({video})
  assert.equal(video.currentTime, 0)
  assert.equal(video.playbackRate, 1)
})

test("controls with no film (a set of pictures) mount, and leave Cinema and Full screen working", () => {
  const box = {requestFullscreen() {}, querySelector: () => null}
  const cinema = button()
  const full = button({title: "a", label: "b", leaveTitle: "c", leaveLabel: "d"})
  const el = {
    dataset: {version: "av_one"},
    closest: () => box,
    querySelector: selector => (selector === "[data-cinema-toggle]" ? cinema : full),
  }
  const hook = Object.create(ArtifactPlayer)
  hook.el = el
  assert.doesNotThrow(() => hook.mounted())
  cinema.fire("click")
  assert.equal(el.dataset.cinema, "true")
  assert.doesNotThrow(() => hook.destroyed())
})

test("the hook stops listening once removed", () => {
  const {hook, cinema, full} = mount()
  hook.destroyed()
  assert.equal(cinema.listeners.click, undefined)
  assert.equal(full.listeners.click, undefined)
  assert.equal(globalThis.document.listeners.fullscreenchange, undefined)
})
