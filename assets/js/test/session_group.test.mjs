// The run's timeline inside Run the agent, a row of the Run list that can be closed
// (assets/js/hooks/timeline_keys.js and live_end.js): the item `?seq=` points at, j and k
// on the row's summary, g e, and the new-events pill open the row. A fake DOM of
// `details` elements stands in for the page.
// `node --test 'assets/js/test/*.test.mjs'` (no npm).

import {test} from "node:test"
import assert from "node:assert/strict"

// An element: its tag, its parent, and `closest` for a tag name, as a browser matches it.
const element = (tag, parent = null, extra = {}) => {
  const el = {
    tagName: tag.toUpperCase(),
    parentElement: parent,
    children: [],
    dataset: {},
    listeners: {},
    closest(name) {
      for (let at = this; at; at = at.parentElement) if (at.tagName === name.toUpperCase()) return at
      return null
    },
    addEventListener(type, fn) {
      this.listeners[type] = fn
    },
    removeEventListener(type) {
      delete this.listeners[type]
    },
    ...extra,
  }
  if (parent) parent.children.push(el)
  return el
}

// The Run list's Run the agent row, closed, with its summary and the timeline's list of
// three items inside it.
const page = () => {
  const group = element("details", null, {open: false})
  const summary = element("summary", group)
  group.querySelector = sel => (sel === ":scope > summary" ? summary : null)
  const body = element("div", group)
  const ol = element("ol", body)
  const focused = []
  const items = ["e-2", "e-3", "e-4"].map(id => {
    const li = element("li", ol, {id, inert: false, offsetParent: {}})
    li.classList = {toggle() {}, contains: () => false, add() {}, remove() {}}
    li.querySelector = () => null
    li.focus = () => focused.push(id)
    li.scrollIntoView = () => {}
    li.getBoundingClientRect = () => ({top: 100, bottom: 120})
    return li
  })
  ol.firstElementChild = items[0]
  return {group, summary, ol, items, focused}
}

class FakeObserver {
  observe() {}
  disconnect() {}
}

let byId = {}
globalThis.MutationObserver = FakeObserver
globalThis.matchMedia = () => ({matches: true})
globalThis.requestAnimationFrame = fn => fn()
globalThis.window = {scrollTo() {}, scrollBy() {}, addEventListener() {}, removeEventListener() {}, innerHeight: 800, scrollY: 0}
globalThis.document = {
  getElementById: id => byId[id] || null,
  activeElement: null,
  querySelector: () => null,
  // One list: `end` falls back to the list the hook is on.
  querySelectorAll: () => [],
  documentElement: {getAttribute: () => null, scrollHeight: 2000},
}

const {TimelineKeys, openAround} = await import("../hooks/timeline_keys.js")
const {LiveEnd} = await import("../hooks/live_end.js")

const mount = el => {
  const hook = Object.assign(Object.create(TimelineKeys), {el})
  hook.mounted()
  return hook
}

const key = (target, k) => {
  let prevented = false
  const e = {key: k, target, defaultPrevented: false, preventDefault: () => (prevented = true)}
  return {e, prevented: () => prevented}
}

test("openAround opens every closed details an element is inside", () => {
  const outer = element("details", null, {open: false})
  const inner = element("details", outer, {open: false})
  const li = element("li", inner)
  openAround(li)
  assert.equal(inner.open, true)
  assert.equal(outer.open, true)
})

test("the item ?seq= points at opens Run the agent", () => {
  const p = page()
  byId = Object.fromEntries(p.items.map(li => [li.id, li]))
  p.ol.dataset.target = "e-3"
  mount(p.ol)
  assert.equal(p.group.open, true)
  assert.deepEqual(p.focused, ["e-3"])
})

test("with no target, Run the agent stays closed", () => {
  const p = page()
  byId = {}
  mount(p.ol)
  assert.equal(p.group.open, false)
})

test("j on the row's summary opens it and moves to the first item, k to the last", () => {
  for (const [k, id] of [["j", "e-2"], ["k", "e-4"]]) {
    const p = page()
    byId = {}
    mount(p.ol)
    const {e, prevented} = key(p.summary, k)
    p.group.listeners.keydown(e)
    assert.equal(p.group.open, true, k)
    assert.ok(prevented(), k)
    assert.deepEqual(p.focused, [id], k)
  }
})

test("a key on an item inside the row is no key of the summary", () => {
  const p = page()
  byId = {}
  mount(p.ol)
  const {e, prevented} = key(p.items[0], "j")
  p.group.listeners.keydown(e)
  assert.equal(p.group.open, false)
  assert.ok(!prevented())
})

test("g e on the row's summary opens it and goes to the live end", () => {
  const p = page()
  byId = {}
  const hook = mount(p.ol)
  p.group.listeners.keydown(key(p.summary, "g").e)
  p.group.listeners.keydown(key(p.summary, "e").e)
  clearTimeout(hook.chord)
  assert.equal(p.group.open, true)
  assert.deepEqual(p.focused, ["e-4"])
})

// The LiveEnd hook as the page has it: on `#live-end`, which has no list inside, with the
// timeline's list elsewhere in the document. The test's end puts `document.querySelector`
// back.
const liveEnd = (t, p) => {
  const querySelector = document.querySelector
  t.after(() => (document.querySelector = querySelector))
  document.querySelector = sel => (sel === "ol.q-tl" ? p.ol : null)
  return Object.assign(Object.create(LiveEnd), {el: {querySelector: () => null}})
}

test("the new-events pill opens the row the timeline is inside", t => {
  const p = page()
  byId = Object.fromEntries(p.items.map(li => [li.id, li]))
  liveEnd(t, p).toEnd("e-4")
  assert.equal(p.group.open, true)
  assert.deepEqual(p.focused, ["e-4"])
})

test("the live end with no item to focus opens the row around the timeline", t => {
  const p = page()
  byId = {}
  liveEnd(t, p).toEnd(null)
  assert.equal(p.group.open, true)
})

test("the live end measures again when the page's height changes", t => {
  const {ResizeObserver} = globalThis
  const {body} = document
  t.after(() => {
    globalThis.ResizeObserver = ResizeObserver
    document.body = body
    document.documentElement.scrollHeight = 2000
  })
  const observed = []
  let resized = null
  globalThis.ResizeObserver = class {
    constructor(fn) {
      resized = fn
    }
    observe(el) {
      observed.push(el)
    }
    disconnect() {}
  }
  document.body = {}
  document.documentElement.scrollHeight = 2000
  const pushed = []
  const hook = Object.assign(liveEnd(t, page()), {
    pushEvent: (event, value) => pushed.push([event, value.at_end]),
    handleEvent() {},
  })
  hook.mounted()
  assert.deepEqual(observed, [document.body])
  assert.deepEqual(pushed, [["live_end", false]])

  // A subagent opens near the end and the page grows: no scroll, no patch of #live-end.
  document.documentElement.scrollHeight = 900
  resized()
  assert.deepEqual(pushed, [["live_end", false], ["live_end", true]])
  hook.destroyed()
})

test("a list that moves into Run the agent after its mount: j on the row's summary opens it", () => {
  // Mounted outside any row, as before the session starts.
  const p = page()
  const outside = element("div")
  p.ol.parentElement = outside
  byId = {}
  const hook = mount(p.ol)
  assert.equal(hook.group, null)

  // The session starts: the same list is now inside the row, and the hook is updated.
  p.ol.parentElement = p.group.children[1]
  hook.beforeUpdate()
  hook.updated()
  const {e, prevented} = key(p.summary, "j")
  p.group.listeners.keydown(e)
  assert.equal(p.group.open, true)
  assert.ok(prevented())
  assert.deepEqual(p.focused, ["e-2"])
})
