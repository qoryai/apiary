// The timeline's own layer (brief-runs rh): what a stream's items cannot get from the
// server once they are on the page, and the keyboard path through them.
//
//   data-target="e-18"    the item ?seq= points at: highlighted, scrolled to once
//   data-isolate="agent"  the lane ?lane= keeps: the others dim and go inert
//
// Keys, with focus in the timeline and no field focused:
//   j / k            next and previous item        Enter / Space   open and close
//   o                open every tool call          x / Shift+x     next / previous denied
//   g e              the live end                  g t             the top
//   c                copy the focused item's link

const reducedMotion = () => matchMedia("(prefers-reduced-motion: reduce)").matches
const typing = el => el.closest("input, textarea, select, [contenteditable='true']")

export const TimelineKeys = {
  mounted() {
    this.lastTarget = null
    this.onKey = e => this.key(e)
    this.el.addEventListener("keydown", this.onKey)
    this.observer = new MutationObserver(() => this.apply())
    this.observer.observe(this.el, {childList: true})
    this.apply()
  },

  updated() {
    this.apply()
  },

  destroyed() {
    this.el.removeEventListener("keydown", this.onKey)
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
      li.classList.toggle("q-ti-off", off)
      li.inert = off
      li.classList.toggle("is-target", Boolean(target) && li.id === target)
    }
    if (target !== this.lastTarget) {
      this.lastTarget = target
      const li = target && document.getElementById(target)
      if (li) {
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
          if (details) details.open = !details.open
        })
    }
  },

  done(e, run) {
    e.preventDefault()
    run()
  },

  denied(by) {
    const li = this.step(by, item => item.dataset.denied === "1" || item.querySelector(".q-cx-denied"))
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
      await navigator.clipboard.writeText(link.href)
      li.classList.add("is-target")
      setTimeout(() => li.id !== this.el.dataset.target && li.classList.remove("is-target"), 600)
    } catch (_err) {
      // No clipboard without a secure context: the link is still in the item.
    }
  },
}
