// The timeline's own layer: what a stream's items cannot get from the
// server once they are on the page, and the keyboard path through them.
//
//   data-target="e-18"    the item ?seq= points at: highlighted, scrolled to once
//   data-isolate="agent"  the lane ?lane= keeps: the others dim and go inert
//
// Keys, with focus in the timeline and no field focused:
//   j / k            next and previous item        Enter / Space   open and close
//                    (a subagent's items are on the page only while it is open)
//   o                open every tool call          x / Shift+x     next / previous denied
//                    (in time order: one in a closed subagent opens it on the server)
//   g e              the live end                  g t             the top
//   c                copy the focused item's link
//
// The timeline can be inside a closed row, Session started of the Run list. The item
// ?seq= points at and the live end open that row, and so do j, k and g e with focus on
// the row's summary: j moves to the first item, k to the last.
import {singleKeys} from "./shortcuts.js"

// The chevron of a subagent's head (`ApiaryWeb.RunPageComponents`).
export const SUBAGENT_TOGGLE = "[phx-click=subagent_toggle]"

const reducedMotion = () => matchMedia("(prefers-reduced-motion: reduce)").matches
const typing = el => el.closest("input, textarea, select, [contenteditable='true']")

// Opens every closed `details` that `el` is inside, so that `el` can be seen.
export const openAround = el => {
  for (let d = el && el.parentElement && el.parentElement.closest("details"); d; d = d.parentElement && d.parentElement.closest("details")) {
    if (!d.open) d.open = true
  }
}

export const TimelineKeys = {
  mounted() {
    this.lastTarget = null
    this.onKey = e => this.key(e)
    this.el.addEventListener("keydown", this.onKey)
    // A patch of one item puts the server's attributes back: what this hook set on it
    // (inert, the dimming, the target) is set again. `apply` writes only what differs: a
    // write of the value already there still makes a record, which calls `apply` again.
    this.observer = new MutationObserver(() => this.apply())
    this.observer.observe(this.el, {childList: true, subtree: true, attributes: true, attributeFilter: ["class", "inert"]})
    this.group = null
    this.onGroupKey = e => this.groupKey(e)
    this.bindGroup()
    this.apply()
  },

  // The row the timeline is inside, if any, has a keydown listener for j, k and g e on its
  // summary. When the session starts on an open page, the timeline's list moves into
  // Session started with no new mount, so `updated` finds the row again.
  bindGroup() {
    const group = (this.el.parentElement && this.el.parentElement.closest("details")) || null
    if (group === this.group) return
    if (this.group) this.group.removeEventListener("keydown", this.onGroupKey)
    this.group = group
    if (group) group.addEventListener("keydown", this.onGroupKey)
  },

  // Items loaded above the reader must not move what they are reading: remember the first
  // item on screen and where it was, and put it back there.
  beforeUpdate() {
    const anchor = this.items().find(li => li.getBoundingClientRect().bottom > 64)
    this.anchor = anchor ? {id: anchor.id, top: anchor.getBoundingClientRect().top, first: this.el.firstElementChild?.id} : null
  },

  updated() {
    this.bindGroup()
    this.apply()
    const was = this.anchor
    this.anchor = null
    if (!was || this.el.firstElementChild?.id === was.first) return
    const li = document.getElementById(was.id)
    if (li) window.scrollBy({top: li.getBoundingClientRect().top - was.top, behavior: "auto"})
  },

  destroyed() {
    this.el.removeEventListener("keydown", this.onKey)
    if (this.group) this.group.removeEventListener("keydown", this.onGroupKey)
    this.observer.disconnect()
    clearTimeout(this.chord)
  },

  items() {
    return Array.from(this.el.children).filter(li => !li.inert && li.offsetParent !== null)
  },

  apply() {
    const {target, isolate} = this.el.dataset
    for (const li of this.el.children) {
      const off = Boolean(isolate) && li.dataset.lane !== isolate
      // A forced toggle of a class that is already right makes no record, but
      // `inert = true` is a setAttribute, which makes one every time.
      li.classList.toggle("q-ti-off", off)
      if (li.inert !== off) li.inert = off
      li.classList.toggle("is-target", Boolean(target) && li.id === target)
    }
    if (target !== this.lastTarget) {
      this.lastTarget = target
      const li = target && document.getElementById(target)
      if (li) {
        openAround(li)
        const details = li.querySelector("details")
        if (details) details.open = true
        li.scrollIntoView({block: "center", behavior: "auto"})
        li.focus({preventScroll: true})
      }
    }
  },

  current() {
    const active = document.activeElement && document.activeElement.closest("li.q-ti")
    if (active && active.parentElement === this.el) return active
    // Nothing focused yet: the first item on screen.
    return this.items().find(li => li.getBoundingClientRect().bottom > 64) || null
  },

  focus(li) {
    if (!li) return
    li.focus({preventScroll: true})
    li.scrollIntoView({block: "nearest", behavior: reducedMotion() ? "auto" : "smooth"})
  },

  step(by, test = () => true) {
    const items = this.items()
    const at = items.indexOf(this.current())
    const focused = document.activeElement && document.activeElement.closest("li.q-ti")
    let i = focused ? at + by : Math.max(at, 0)
    for (; i >= 0 && i < items.length; i += by) {
      if (test(items[i])) return items[i]
    }
    return null
  },

  key(e) {
    if (e.defaultPrevented || e.ctrlKey || e.metaKey || e.altKey || typing(e.target)) return
    if (e.key.length === 1 && !singleKeys()) return
    const onItem = e.target.matches("li.q-ti")

    if (this.chord) {
      clearTimeout(this.chord)
      this.chord = null
      if (e.key === "e") return this.done(e, () => this.end())
      if (e.key === "t") return this.done(e, () => this.top())
    }

    switch (e.key) {
      case "j": return this.done(e, () => this.focus(this.step(1)))
      case "k": return this.done(e, () => this.focus(this.step(-1)))
      case "x": return this.done(e, () => this.denied(1))
      case "X": return this.done(e, () => this.denied(-1))
      case "o": return this.done(e, () => this.openAll())
      case "c": return this.done(e, () => this.copy())
      case "g":
        this.chord = setTimeout(() => (this.chord = null), 1200)
        return e.preventDefault()
      case "Enter":
      case " ":
        if (!onItem) return
        return this.done(e, () => {
          const details = e.target.querySelector("details")
          if (details) return (details.open = !details.open)
          // A subagent's head opens and closes its items on the server.
          const toggle = e.target.querySelector(SUBAGENT_TOGGLE)
          if (toggle) toggle.click()
        })
    }
  },

  // A key on the summary of the row the timeline is inside.
  groupKey(e) {
    const summary = this.group.querySelector(":scope > summary")
    if (e.target !== summary) return
    if (e.defaultPrevented || e.ctrlKey || e.metaKey || e.altKey) return
    if (e.key.length === 1 && !singleKeys()) return

    if (this.chord) {
      clearTimeout(this.chord)
      this.chord = null
      if (e.key === "e") return this.done(e, () => this.end())
    }

    switch (e.key) {
      case "j":
      case "k":
        return this.done(e, () => {
          openAround(this.el)
          const items = this.items()
          this.focus(e.key === "j" ? items[0] : items[items.length - 1])
        })
      case "g":
        this.chord = setTimeout(() => (this.chord = null), 1200)
        return e.preventDefault()
    }
  },

  done(e, run) {
    e.preventDefault()
    run()
  },

  // The denied calls on the page in time order: the items, and the calls a closed
  // subagent's head stands for (`data-hidden-denied`), up to the window's last item while
  // items follow it (`data-until`). From the focused item, else from the first on screen.
  denied(by) {
    const at = this.current()
    if (!at) return
    const from = this.placeOf(at)
    const focused = Boolean(document.activeElement && document.activeElement.closest("li.q-ti"))
    const until = this.el.dataset.until ? Number(this.el.dataset.until) : Infinity
    const ahead = seq => (focused ? (seq - from) * by > 0 : (seq - from) * by >= 0)
    let next = null
    const take = (seq, li) => {
      if (ahead(seq) && (!next || (seq - next.seq) * by < 0)) next = {seq, li}
    }
    for (const li of this.items()) {
      if (li.dataset.denied === "1" || li.querySelector(".q-cx-denied")) take(Number(li.dataset.seq), li)
      for (const seq of (li.dataset.hiddenDenied || "").split(" ").filter(Boolean).map(Number)) {
        if (seq <= until) take(seq, null)
      }
    }
    if (!next) return
    if (next.li) return this.reveal(next.li)
    // The subagent opens, and the call is on the page when the reply comes.
    this.push("subagent_open", {seq: String(next.seq)}, () =>
      this.reveal(document.getElementById(`e-${next.seq}`)),
    )
  },

  // An item's place in time: its sequence, or for a row with none, a Pushed row, a half
  // step after the item before it, or 0 when no item comes before it.
  placeOf(li) {
    if (li.dataset.seq) return Number(li.dataset.seq)
    const items = Array.from(this.el.children)
    for (let i = items.indexOf(li) - 1; i >= 0; i--) {
      if (items[i].dataset.seq) return Number(items[i].dataset.seq) + 0.5
    }
    return 0
  },

  // Sends an event from `#<list id>-push` (`TimelinePush`), outside the stream.
  push(event, payload, onReply) {
    const detail = {event, payload, onReply}
    document.getElementById(`${this.el.id}-push`).dispatchEvent(new CustomEvent("timeline:push", {detail}))
  },

  reveal(li) {
    if (!li) return
    const details = li.querySelector("details")
    if (details) details.open = true
    this.focus(li)
  },

  openAll() {
    const tools = Array.from(this.el.querySelectorAll("details.q-tool:not(.q-cx-group)"))
    const open = tools.some(d => !d.open)
    tools.forEach(d => (d.open = open))
  },

  end() {
    openAround(this.el)
    const pill = document.querySelector(".q-newpill-show[phx-click]")
    if (pill) return pill.click()
    window.scrollTo({top: document.documentElement.scrollHeight, behavior: reducedMotion() ? "auto" : "smooth"})
    const items = this.items()
    if (items.length) items[items.length - 1].focus({preventScroll: true})
  },

  top() {
    window.scrollTo({top: 0, behavior: reducedMotion() ? "auto" : "smooth"})
    const items = this.items()
    if (items.length) items[0].focus({preventScroll: true})
  },

  async copy() {
    const li = this.current()
    const link = li && li.querySelector("[data-permalink]")
    if (!link) return
    try {
      // Inside a summary the number is text with the path in `data-href`.
      await navigator.clipboard.writeText(link.href || new URL(link.dataset.href, location.href).href)
      li.classList.add("is-target")
      setTimeout(() => li.id !== this.el.dataset.target && li.classList.remove("is-target"), 600)
    } catch (_err) {
      // No clipboard without a secure context: the link is still in the item.
    }
  },
}

// The element the timeline's keys send their events from, beside the list and outside
// the stream. LiveView locks a hook's element until the acknowledgement of its event
// arrives, and a stream patched inside a locked element appends new rows at the end: a
// second `x` before the first acknowledgement would lock the list.
export const TimelinePush = {
  mounted() {
    this.el.addEventListener("timeline:push", ({detail: {event, payload, onReply}}) =>
      this.pushEvent(event, payload, onReply),
    )
  },
}
