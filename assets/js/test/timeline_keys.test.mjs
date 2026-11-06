// The timeline's lane isolation (assets/js/hooks/timeline_keys.js, `apply`): with `?lane=`,
// the items of the other lanes dim and go inert, and the hook's MutationObserver calls
// `apply` again after each patch. A browser records a mutation for every `setAttribute`,
// also one that writes the value already there, and setting `inert = true` is a
// `setAttribute`. If `apply` writes `inert` on every call, each call makes the record that
// calls it again, and the tab hangs. The fake DOM below records mutations the way a
// browser does, and delivers them until none is left.
// `node --test 'assets/js/test/*.test.mjs'` (no npm).

import {test} from "node:test"
import assert from "node:assert/strict"

// MutationObserver: records are queued and delivered by `flush`, as a browser delivers
// them in a microtask after the script that made them.
let queue = []
let observers = []

class FakeObserver {
  constructor(callback) {
    this.callback = callback
  }
  observe() {
    observers.push(this)
  }
  disconnect() {
    observers = observers.filter(o => o !== this)
  }
}

const record = (target, attributeName) => queue.push({type: "attributes", target, attributeName})

// Delivers the queued records until none is left, and returns how many rounds that took.
// A hook that feeds itself never stops: the cap ends the test.
const flush = (cap = 100) => {
  let rounds = 0
  while (queue.length && rounds < cap) {
    const records = queue
    queue = []
    rounds++
    for (const o of observers) o.callback(records)
  }
  return rounds
}

// classList.toggle(token, force) changes the attribute, and makes a record, only when the
// token's presence changes.
const classList = li => {
  const tokens = new Set()
  return {
    contains: t => tokens.has(t),
    add: t => {
      if (!tokens.has(t)) tokens.add(t), record(li, "class")
    },
    remove: t => {
      if (tokens.delete(t)) record(li, "class")
    },
    toggle: (t, force) => {
      const on = force === undefined ? !tokens.has(t) : Boolean(force)
      if (on !== tokens.has(t)) {
        on ? tokens.add(t) : tokens.delete(t)
        record(li, "class")
      }
      return on
    },
  }
}

// `inert` reflects the attribute: true is setAttribute("inert", ""), which makes a record
// every time; false is removeAttribute("inert"), which makes one only when it was there.
const item = (id, lane) => {
  let inert = false
  const li = {id, dataset: {lane}, offsetParent: {}}
  li.classList = classList(li)
  Object.defineProperty(li, "inert", {
    get: () => inert,
    set: value => {
      if (value || inert) record(li, "inert")
      inert = Boolean(value)
    },
  })
  return li
}

const timeline = (isolate, lanes) => {
  const children = lanes.map((lane, i) => item(`e-${i + 2}`, lane))
  return {
    dataset: {isolate},
    children,
    firstElementChild: children[0],
    addEventListener() {},
    removeEventListener() {},
  }
}

globalThis.MutationObserver = FakeObserver
globalThis.document = {getElementById: () => null, activeElement: null}

const {TimelineKeys} = await import("../hooks/timeline_keys.js")

const mount = el => {
  queue = []
  observers = []
  const hook = Object.assign(Object.create(TimelineKeys), {el})
  hook.mounted()
  return hook
}

// A run with two subagents, as the demo's session-with-subagents has.
const LANES = ["main", "agent-a1", "agent-a1", "main", "agent-a2", "agent-a2", "main"]

test("isolating a subagent's lane settles after one round of records", () => {
  const el = timeline("agent-a1", LANES)
  mount(el)
  assert.ok(flush() <= 1, "apply() keeps making the records that call it again")
  assert.deepEqual(
    el.children.map(li => li.inert),
    [true, false, false, true, true, true, true],
  )
  assert.ok(el.children[0].classList.contains("q-ti-off"))
  assert.ok(!el.children[1].classList.contains("q-ti-off"))
})

test("isolating the main lane settles too", () => {
  const el = timeline("main", LANES)
  mount(el)
  assert.ok(flush() <= 1, "apply() keeps making the records that call it again")
  assert.deepEqual(
    el.children.map(li => li.inert),
    [false, true, true, false, true, true, false],
  )
})

test("a second apply with nothing changed makes no record", () => {
  const el = timeline("agent-a2", LANES)
  const hook = mount(el)
  flush()
  hook.apply()
  assert.equal(queue.length, 0)
})

test("a patch that puts an item's inert back is undone once, and settles", () => {
  const el = timeline("agent-a1", LANES)
  mount(el)
  flush()
  // LiveView patches item e-2 and drops what the hook set on it.
  const li = el.children[0]
  li.inert = false
  li.classList.toggle("q-ti-off", false)
  assert.ok(flush() <= 2, "apply() keeps making the records that call it again")
  assert.equal(li.inert, true)
  assert.ok(li.classList.contains("q-ti-off"))
})

test("leaving the lane wakes every item, and settles", () => {
  const el = timeline("agent-a1", LANES)
  const hook = mount(el)
  flush()
  delete el.dataset.isolate
  hook.updated()
  assert.ok(flush() <= 1)
  assert.deepEqual(
    el.children.map(li => li.inert),
    LANES.map(() => false),
  )
  assert.ok(el.children.every(li => !li.classList.contains("q-ti-off")))
})
