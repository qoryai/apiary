// The runs list and the controls of a list.

// The width the preview pane is for: from here a row chosen in the list opens beside it.
const WIDE = "(min-width: 1920px)"

// The runs list's table (its scroll region carries the hook). It tells the page whether the
// window is wide enough for the preview, and there makes a row a choice instead of a link:
// a click chooses the row (a second click on the chosen one, or Enter, opens the run), and
// ↑ and ↓ move the choice while the list has focus. The page puts the choice in the URL; the
// row is marked at once so the keys never wait for the server. Below that width nothing is
// done here, and a row is its link.
export const RunList = {
  mounted() {
    // The groups' fold of an earlier list is not a preference any more.
    try {
      localStorage.removeItem("qory:runs:collapsed")
    } catch (_e) {}

    this.query = window.matchMedia(WIDE)
    this.report = () => this.pushEvent("viewport", {wide: this.query.matches})
    this.query.addEventListener("change", this.report)
    this.report()

    this.el.addEventListener("click", e => {
      if (!this.query.matches || e.defaultPrevented) return
      if (e.button !== 0 || e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) return
      const row = e.target.closest("tr[data-run]")
      if (!row || !this.el.contains(row)) return
      if (row.getAttribute("aria-current") === "true") return
      // Inside a row only its own controls keep their click (a tooltip's term, a link
      // other than the row's).
      const link = e.target.closest("a")
      if (link && !link.classList.contains("q-rowlink")) return
      e.preventDefault()
      e.stopPropagation()
      this.choose(row)
    })

    this.el.addEventListener("keydown", e => {
      if (!this.query.matches || e.target.closest("input, select, textarea")) return
      const rows = [...this.el.querySelectorAll("tr[data-run]")]
      if (rows.length === 0) return
      const at = rows.findIndex(r => r.getAttribute("aria-current") === "true")
      if (e.key === "ArrowDown" || e.key === "ArrowUp") {
        e.preventDefault()
        const step = e.key === "ArrowDown" ? 1 : -1
        const next = at < 0 ? 0 : Math.max(0, Math.min(rows.length - 1, at + step))
        if (next !== at) this.choose(rows[next])
        rows[next].scrollIntoView({block: "nearest"})
      } else if (e.key === "Enter" && at >= 0 && e.target === this.el) {
        e.preventDefault()
        this.pushEvent("open", {id: rows[at].dataset.run})
      }
    })
  },
  choose(row) {
    this.el.querySelectorAll("tr[aria-current]").forEach(r => r.removeAttribute("aria-current"))
    row.setAttribute("aria-current", "true")
    this.pushEvent("select", {id: row.dataset.run})
  },
  destroyed() {
    this.query?.removeEventListener("change", this.report)
  },
}

// The query field of a list: Backspace in the empty field takes the last token out, as a
// chip field does; after a submit the page says what the field holds now (the free text,
// the qualifiers having become tokens).
export const QueryBar = {
  mounted() {
    this.input = () => this.el.querySelector("input[name=q]")
    this.el.addEventListener("keydown", e => {
      const input = this.input()
      if (e.key !== "Backspace" || e.target !== input || input.value !== "") return
      const remove = [...this.el.querySelectorAll("[data-token-remove]")].pop()
      if (remove) {
        e.preventDefault()
        remove.click()
      }
    })
    this.handleEvent("query:set", ({id, value}) => {
      const input = this.input()
      if (input && input.id === id) input.value = value
    })
  },
}
