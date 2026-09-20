// The runs list (brief-runs rd8, re1).

// Which groups are collapsed is a reading preference, not a filter: it lives in
// localStorage under `qory:runs:collapsed`, never in the URL. The hook sits on the table;
// each <tbody data-group> carries its key, its header button toggles it.
const KEY = "qory:runs:collapsed"

const read = () => {
  try {
    const value = JSON.parse(localStorage.getItem(KEY) || "[]")
    return new Set(Array.isArray(value) ? value.filter(v => typeof v === "string") : [])
  } catch (_e) {
    return new Set()
  }
}

const write = set => {
  try {
    localStorage.setItem(KEY, JSON.stringify([...set].slice(-200)))
  } catch (_e) {}
}

export const RunGroups = {
  mounted() {
    this.apply()
    this.el.addEventListener("click", e => {
      const button = e.target.closest("button[data-group-toggle]")
      if (!button || !this.el.contains(button)) return
      const body = button.closest("tbody[data-group]")
      const collapsed = read()
      collapsed.has(body.dataset.group) ? collapsed.delete(body.dataset.group) : collapsed.add(body.dataset.group)
      write(collapsed)
      this.apply()
    })
  },
  updated() {
    this.apply()
  },
  apply() {
    const collapsed = read()
    this.el.querySelectorAll("tbody[data-group]").forEach(body => {
      const is = collapsed.has(body.dataset.group)
      body.toggleAttribute("data-collapsed", is)
      body.querySelector("button[data-group-toggle]")?.setAttribute("aria-expanded", String(!is))
    })
  },
}

// "1 new run": a new run is not inserted under the reader. At the top of page 1 with
// nothing focused inside the table it is, by following the link for them.
export const NewRuns = {
  mounted() {
    this.maybe()
  },
  updated() {
    this.maybe()
  },
  maybe() {
    if (this.el.dataset.auto !== "true") return
    const table = document.querySelector(this.el.dataset.table)
    const reading = table && table.contains(document.activeElement)
    const atTop = (window.scrollY || document.documentElement.scrollTop) < 120
    if (atTop && !reading && !document.hidden) this.el.click()
  },
}
