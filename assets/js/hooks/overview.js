// The fourteen-day chart of the hive overview (brief-overview.md od5). The server renders
// the SVG; this hook owns what only the browser knows: the one tooltip for both plots,
// placed under the hovered or focused slot; the reading preference of the table twin,
// kept in localStorage; Home and End between the slots; and, on a coarse pointer, the
// first tap that opens the tooltip before the second follows the link.
//
// The tooltip element is the hook's (`phx-update="ignore"`); everything else is patched
// by LiveView and read here from data attributes.

const KEY = "qory:overview:table"
const coarse = () => window.matchMedia("(pointer: coarse)").matches

export const DaysChart = {
  mounted() {
    this.tip = this.el.querySelector(".q-chart-tt")
    this.expanded = null
    this.onOver = e => this.show(e.target.closest("a[data-day]"))
    this.onOut = e => {
      const slot = e.target.closest("a[data-day]")
      if (slot && !slot.contains(e.relatedTarget)) this.hide(slot)
    }
    this.onFocus = e => this.show(e.target.closest("a[data-day]"))
    this.onBlur = e => this.hide(e.target.closest("a[data-day]"))
    this.onKey = e => {
      if (e.key !== "Home" && e.key !== "End") return
      const slots = [...this.el.querySelectorAll("a[data-day]")]
      if (!slots.includes(document.activeElement)) return
      e.preventDefault()
      slots[e.key === "Home" ? 0 : slots.length - 1].focus()
    }
    this.onClick = e => {
      const slot = e.target.closest("a[data-day]")
      if (!slot || !coarse()) return
      // The first tap reads the numbers; the second follows.
      if (this.expanded !== slot) {
        e.preventDefault()
        e.stopPropagation()
        this.show(slot)
      }
    }
    this.el.addEventListener("mouseover", this.onOver)
    this.el.addEventListener("mouseout", this.onOut)
    this.el.addEventListener("focusin", this.onFocus)
    this.el.addEventListener("focusout", this.onBlur)
    this.el.addEventListener("keydown", this.onKey)
    this.el.addEventListener("click", this.onClick, true)

    // The reading preference wins over the server's default, once, at mount.
    let stored = null
    try { stored = localStorage.getItem(KEY) } catch (_e) {}
    if (stored !== null && stored !== this.el.dataset.table) {
      this.pushEvent("chart_table", {on: stored === "1"})
    }

    // Below 480 px the server draws the phone geometry (16 px columns, every third label).
    this.measure = () => {
      const narrow = this.el.clientWidth > 0 && this.el.clientWidth < 480
      if (String(narrow ? 1 : 0) !== this.el.dataset.narrow) this.pushEvent("chart_size", {narrow})
    }
    this.onResize = () => {
      clearTimeout(this.resizeTimer)
      this.resizeTimer = setTimeout(this.measure, 150)
    }
    window.addEventListener("resize", this.onResize)
    this.measure()
  },

  updated() {
    try { localStorage.setItem(KEY, this.el.dataset.table) } catch (_e) {}
    this.measure()
    // The slot that held the tooltip may have been drawn anew.
    if (this.expanded && !this.expanded.isConnected) this.hide(this.expanded)
  },

  destroyed() {
    clearTimeout(this.resizeTimer)
    window.removeEventListener("resize", this.onResize)
    this.el.removeEventListener("mouseover", this.onOver)
    this.el.removeEventListener("mouseout", this.onOut)
    this.el.removeEventListener("focusin", this.onFocus)
    this.el.removeEventListener("focusout", this.onBlur)
    this.el.removeEventListener("keydown", this.onKey)
    this.el.removeEventListener("click", this.onClick, true)
  },

  show(slot) {
    if (!slot || !this.tip) return
    if (this.expanded && this.expanded !== slot) this.hide(this.expanded)
    this.expanded = slot
    slot.setAttribute("aria-expanded", "true")
    const {label, runs, den} = slot.dataset
    this.tip.replaceChildren()
    const b = document.createElement("b")
    b.textContent = label
    const line = (text, cls) => {
      const s = document.createElement("span")
      const i = document.createElement("i")
      if (cls) i.className = cls
      s.append(i, document.createTextNode(text))
      return s
    }
    this.tip.append(b, line(runs), line(den, "q-den"))
    this.tip.classList.add("q-on")
    const at = slot.getBoundingClientRect()
    const box = this.el.getBoundingClientRect()
    const width = this.tip.offsetWidth
    const left = Math.min(Math.max(0, at.left - box.left + at.width / 2 - width / 2), box.width - width)
    this.tip.style.left = `${Math.round(left)}px`
    this.tip.style.top = `${Math.round(at.top - box.top - this.tip.offsetHeight - 6)}px`
  },

  hide(slot) {
    if (slot) slot.setAttribute("aria-expanded", "false")
    if (this.expanded === slot || !slot) this.expanded = null
    if (this.tip && !this.expanded) this.tip.classList.remove("q-on")
  },
}

// The page: after an act removed the control that had focus (an allow, a close), focus
// moves where the server says ("overview:focus" with the element's id), never to the body.
export const OverviewPage = {
  mounted() {
    this.handleEvent("overview:focus", ({id}) => {
      requestAnimationFrame(() => document.getElementById(id)?.focus({preventScroll: false}))
    })
  },
}
