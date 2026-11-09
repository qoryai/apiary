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

const TimelineKeysModule = await import("../hooks/timeline_keys.js")
const {TimelineKeys, TimelinePush} = TimelineKeysModule

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

// Enter and Space on an item (`key`): a tool call's <details> opens and closes in the
// browser; a subagent's head has no <details>, and its chevron is clicked, which sends
// `subagent_toggle` to the server.

// Presses `key` on `li` and returns whether the hook took the key.
const pressed = (hook, li, key) => {
  let prevented = false
  hook.key({key, target: li, defaultPrevented: false, preventDefault: () => (prevented = true)})
  return prevented
}

// An item that has `inside`, by selector, and is no field.
const keyItem = inside => {
  const li = item("e-9", "agent-a1")
  li.matches = selector => selector === "li.q-ti"
  li.closest = () => null
  li.querySelector = selector => inside[selector] || null
  return li
}

// Single-key shortcuts on, as `shortcuts.js` reads them from <html>.
globalThis.document.documentElement = {getAttribute: () => null}

test("Enter on a subagent's head clicks its chevron", () => {
  const {SUBAGENT_TOGGLE} = TimelineKeysModule
  let clicks = 0
  const li = keyItem({[SUBAGENT_TOGGLE]: {click: () => clicks++}})
  const hook = mount(timeline(undefined, []))
  assert.ok(pressed(hook, li, "Enter"))
  assert.ok(pressed(hook, li, " "))
  assert.equal(clicks, 2)
})

test("Enter on a tool call opens its details, and clicks nothing", () => {
  const {SUBAGENT_TOGGLE} = TimelineKeysModule
  let clicks = 0
  const details = {open: false}
  const li = keyItem({details, [SUBAGENT_TOGGLE]: {click: () => clicks++}})
  const hook = mount(timeline(undefined, []))
  assert.ok(pressed(hook, li, "Enter"))
  assert.equal(details.open, true)
  assert.equal(clicks, 0)
})

// x and Shift+x (`denied`): the denied calls in time order, those of a closed subagent
// included. Its head has their sequences in `data-hidden-denied`; the hook sends
// `subagent_open` for one, and moves to the call when the reply comes.

globalThis.matchMedia = () => ({matches: true})

// Items by sequence, each with `data` for its dataset; `focused` is where focus is.
const deniedTimeline = (rows, until) => {
  const el = timeline(undefined, [])
  el.dataset.until = until
  el.children = rows.map(([seq, data]) => {
    const li = item(`e-${seq}`, "main")
    Object.assign(li.dataset, {seq: String(seq)}, data)
    li.parentElement = el
    li.closest = selector => (selector === "li.q-ti" ? li : null)
    li.matches = selector => selector === "li.q-ti"
    li.querySelector = () => null
    li.focus = () => (globalThis.document.activeElement = li)
    li.scrollIntoView = () => {}
    li.getBoundingClientRect = () => ({top: 100, bottom: 120})
    return li
  })
  el.firstElementChild = el.children[0]
  return el
}

const ROWS = [
  [2, {}],
  [3, {hiddenDenied: "5 7"}],
  [6, {denied: "1"}],
  [9, {denied: "1"}],
  [11, {}],
]

// The list is `#timeline`; its events leave from `#timeline-push`, beside it, which has the
// `TimelinePush` hook. `hook.pushed` collects what that element sends. The list's hook has
// a `pushEvent` that fails the test: LiveView would lock the list, the stream container.
const pusher = () => {
  const listeners = {}
  const el = {
    addEventListener: (type, fn) => (listeners[type] = fn),
    dispatchEvent: e => listeners[e.type](e),
  }
  const hook = Object.assign(Object.create(TimelinePush), {el})
  hook.mounted()
  return hook
}

const {getElementById} = globalThis.document

const deniedHook = (t, el) => {
  t.after(() => (globalThis.document.getElementById = getElementById))
  el.id = "timeline"
  const hook = mount(el)
  const push = pusher()
  hook.pushed = []
  push.pushEvent = (event, payload, reply) => hook.pushed.push({event, payload, reply})
  hook.pushEvent = event => assert.fail(`${event} pushed from the list`)
  globalThis.document.getElementById = id => (id === "timeline-push" ? push.el : null)
  return hook
}

const at = (el, seq) => el.children.find(li => li.dataset.seq === String(seq))

test("x opens a closed subagent for its denied call, in time order with the others", t => {
  const el = deniedTimeline(ROWS)
  const hook = deniedHook(t, el)
  at(el, 2).focus()

  assert.ok(pressed(hook, at(el, 2), "x"))
  assert.deepEqual(hook.pushed.map(p => [p.event, p.payload]), [["subagent_open", {seq: "5"}]])

  // The reply comes after the patch that put the call on the page: focus moves to it.
  const call = deniedTimeline([[5, {denied: "1"}]]).children[0]
  globalThis.document.getElementById = id => (id === "e-5" ? call : null)
  hook.pushed[0].reply()
  assert.equal(globalThis.document.activeElement, call)
})

test("Shift+x goes back the same way, and x skips a call after the window's last item", t => {
  const el = deniedTimeline(ROWS)
  const hook = deniedHook(t, el)
  at(el, 11).focus()

  assert.ok(pressed(hook, at(el, 11), "X"))
  assert.equal(globalThis.document.activeElement, at(el, 9))
  assert.deepEqual(hook.pushed, [])

  // Before 9, the subagent's call at 7 comes after the item at 6.
  pressed(hook, at(el, 9), "X")
  at(el, 6).focus()
  pressed(hook, at(el, 6), "X")
  assert.deepEqual(hook.pushed.map(p => p.payload), [{seq: "7"}, {seq: "5"}])

  // Items follow the window's last item, 6: the subagent's call at 7 is past the page.
  const cut = deniedTimeline(ROWS.slice(0, 3), "6")
  const cutHook = deniedHook(t, cut)
  at(cut, 6).focus()
  pressed(cutHook, at(cut, 6), "x")
  assert.deepEqual(cutHook.pushed, [])
  at(cut, 2).focus()
  pressed(cutHook, at(cut, 2), "x")
  assert.deepEqual(cutHook.pushed.map(p => p.payload), [{seq: "5"}])
})

test("x and Shift+x from a Pushed row, which has no sequence, go to the calls after and before it", t => {
  const el = deniedTimeline([
    [2, {}],
    [6, {denied: "1"}],
    [8, {}],
    [9, {denied: "1"}],
  ])
  // A Pushed row after the item at 6 (`push-<id>`, no `data-seq`).
  const pushedRow = deniedTimeline([[0, {}]]).children[0]
  pushedRow.id = "push-vr_1"
  delete pushedRow.dataset.seq
  pushedRow.parentElement = el
  el.children.splice(2, 0, pushedRow)
  const hook = deniedHook(t, el)

  pushedRow.focus()
  assert.ok(pressed(hook, pushedRow, "x"))
  assert.equal(globalThis.document.activeElement, at(el, 9))

  pushedRow.focus()
  assert.ok(pressed(hook, pushedRow, "X"))
  assert.equal(globalThis.document.activeElement, at(el, 6))
})

// g e (`end`): with one Timeline per agent session, the live end is the last item of the
// last list on the page, also from a key pressed in an earlier session's list.

const endList = (id, seqs) => {
  const el = deniedTimeline(seqs.map(seq => [seq, {}]))
  el.id = id
  el.parentElement = null
  return el
}

test("g e from the first session's list focuses the last item of the last list", t => {
  const {querySelector, querySelectorAll} = globalThis.document
  const window = globalThis.window
  t.after(() => {
    Object.assign(globalThis.document, {querySelector, querySelectorAll})
    globalThis.window = window
  })
  const first = endList("timeline", [1, 3, 4])
  const second = endList("timeline-2", [13, 14, 16])
  globalThis.document.querySelector = () => null
  globalThis.document.querySelectorAll = selector => (selector === "ol.q-tl" ? [first, second] : [])
  globalThis.document.documentElement.scrollHeight = 1000
  globalThis.window = {scrollTo: () => {}}

  const hook = mount(first)
  at(first, 3).focus()
  assert.ok(pressed(hook, at(first, 3), "g"))
  assert.ok(pressed(hook, at(first, 3), "e"))
  assert.equal(globalThis.document.activeElement, at(second, 16))
})

test("g e with a Timeline after the list focuses the run's end in the last agent session's list", t => {
  const {querySelector, querySelectorAll} = globalThis.document
  const window = globalThis.window
  t.after(() => {
    Object.assign(globalThis.document, {querySelector, querySelectorAll})
    globalThis.window = window
  })
  // Session 1 ran and holds the run's end, 17; session 2's wall failed after its start, so
  // its item 15 is in the Timeline after the list, which comes last on the page.
  const first = endList("timeline", [1, 7, 17])
  const agent = {open: false, parentElement: null}
  first.parentElement = {closest: selector => (selector === "details" ? agent : null)}
  const after = endList("timeline-after-list", [15])
  globalThis.document.querySelector = () => null
  globalThis.document.querySelectorAll = selector => (selector === "ol.q-tl" ? [first, after] : [])
  globalThis.document.documentElement.scrollHeight = 1000
  globalThis.window = {scrollTo: () => {}}

  const hook = mount(after)
  at(after, 15).focus()
  assert.ok(pressed(hook, at(after, 15), "g"))
  assert.ok(pressed(hook, at(after, 15), "e"))
  assert.equal(globalThis.document.activeElement, at(first, 17))
  assert.equal(agent.open, true, "session 1's Run the agent opens")
})
