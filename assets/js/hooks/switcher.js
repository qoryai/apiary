// The switcher of the breadcrumb: a popover of places, opened by the chevron beside the
// organisation or the workspace. A search on top filters the places as the reader types
// (by organisation and workspace, name and slug); Recent lists the places opened last,
// kept in localStorage as a reading preference (their switch ids, nothing else). The arrow
// keys move between the search and the places, Enter opens the first match, Escape closes
// and gives focus back to the chevron that opened it; focus or a pointer leaving closes.
// An edition's group is folded behind its heading, a button that opens it; a search opens
// every group it finds a place in, and an empty search folds them back as they were.
// Every word is in the markup.
const KEY = "qory:recent-places"
const RECENT = 5

const readRecent = () => {
  try {
    const list = JSON.parse(localStorage.getItem(KEY) || "[]")
    return Array.isArray(list) ? list.filter(id => typeof id === "string") : []
  } catch (_e) {
    return []
  }
}

const remember = id => {
  if (!id) return
  try {
    const list = [id, ...readRecent().filter(other => other !== id)].slice(0, RECENT + 1)
    localStorage.setItem(KEY, JSON.stringify(list))
  } catch (_e) {}
}

export const Switcher = {
  mounted() {
    this.panel = this.el.querySelector(".q-switcher")
    this.search = this.panel.querySelector("input")
    remember(this.el.dataset.current)

    this.el.addEventListener("click", e => {
      const fold = e.target.closest("button[data-fold]")
      if (fold) {
        e.preventDefault()
        fold.setAttribute("aria-expanded", String(fold.getAttribute("aria-expanded") !== "true"))
        this.filter()
        return
      }
      const trigger = e.target.closest("[data-switcher-open]")
      if (trigger) {
        e.preventDefault()
        this.isOpen() && this.opener === trigger ? this.close(true) : this.open(trigger)
        return
      }
      const place = e.target.closest("a[data-place], a[data-recent]")
      if (place) remember(place.dataset.place === "" ? place.id : place.dataset.recent)
    })
    this.search.addEventListener("input", () => this.filter())
    this.el.addEventListener("keydown", e => this.onKey(e))
    this.el.addEventListener("focusout", e => {
      if (this.isOpen() && !this.el.contains(e.relatedTarget)) this.close(false)
    })
    this.outside = e => {
      if (this.isOpen() && !this.el.contains(e.target)) this.close(false)
    }
    document.addEventListener("pointerdown", this.outside)
  },

  destroyed() {
    document.removeEventListener("pointerdown", this.outside)
  },

  isOpen() {
    return !this.panel.hidden
  },

  open(trigger) {
    this.opener = trigger
    this.renderRecent()
    this.search.value = ""
    this.filter()
    this.panel.hidden = false
    this.triggers().forEach(t => t.setAttribute("aria-expanded", String(t === trigger)))
    this.search.focus()
  },

  close(refocus) {
    this.panel.hidden = true
    this.triggers().forEach(t => t.setAttribute("aria-expanded", "false"))
    if (refocus) this.opener?.focus()
  },

  triggers() {
    return [...this.el.querySelectorAll("[data-switcher-open]")]
  },

  // The places opened last, the current one left out, as links of their own.
  renderRecent() {
    const section = this.panel.querySelector("#organisation-menu-recent")
    const list = section.querySelector("[data-recent]")
    list.replaceChildren()
    const current = this.el.dataset.current
    for (const id of readRecent()) {
      if (id === current || list.children.length >= RECENT) continue
      const place = document.getElementById(id)
      if (!place) continue
      const link = document.createElement("a")
      link.href = place.getAttribute("href")
      link.className = "q-switcher-place"
      link.dataset.recent = id
      link.textContent = place.dataset.recentLabel
      const item = document.createElement("li")
      item.append(link)
      list.append(item)
    }
    section.hidden = list.children.length === 0
  },

  filter() {
    const q = this.search.value.trim().toLowerCase()
    let any = false
    this.panel.querySelectorAll("[data-group]").forEach(group => {
      let groupAny = false
      group.querySelectorAll("[data-org]").forEach(org => {
        const orgMatch = q !== "" && org.dataset.search.includes(q)
        let orgAny = false
        org.querySelectorAll("a[data-place]").forEach(place => {
          const show = q === "" || orgMatch || place.dataset.search.includes(q)
          place.parentElement.hidden = !show
          orgAny ||= show
        })
        org.hidden = !orgAny
        groupAny ||= orgAny
      })
      group.hidden = !groupAny
      // A folded group shows its places while a search finds one in it.
      const list = group.querySelector("[data-fold-list]")
      const fold = group.querySelector("button[data-fold]")
      if (list && fold) list.hidden = q === "" ? fold.getAttribute("aria-expanded") !== "true" : false
      any ||= groupAny
    })
    const recent = this.panel.querySelector("#organisation-menu-recent")
    if (q !== "") recent.hidden = true
    else recent.hidden = recent.querySelector("[data-recent]").children.length === 0
    this.panel.querySelector("#organisation-menu-empty").hidden = any
    // Say what the search left, in the server's words: a count, or that nothing matches.
    const status = this.panel.querySelector("#organisation-menu-status")
    if (status) {
      let shown = 0
      this.panel.querySelectorAll("a[data-place]").forEach(place => {
        if (!place.parentElement.hidden && !place.closest("[hidden]")) shown++
      })
      const words = q === "" ? "" : shown === 0 ? status.dataset.none : shown === 1 ? status.dataset.one : status.dataset.other
      status.textContent = (words || "").replace("%{count}", String(shown))
    }
  },

  links() {
    return [...this.panel.querySelectorAll("a, button[data-fold]")].filter(
      a => a.offsetParent !== null,
    )
  },

  onKey(e) {
    if (!this.isOpen()) return
    const links = this.links()
    const at = links.indexOf(document.activeElement)
    if (e.key === "Escape") {
      e.preventDefault()
      e.stopPropagation()
      this.close(true)
    } else if (e.key === "ArrowDown") {
      e.preventDefault()
      links[at < 0 ? 0 : Math.min(at + 1, links.length - 1)]?.focus()
    } else if (e.key === "ArrowUp") {
      e.preventDefault()
      at <= 0 ? this.search.focus() : links[at - 1].focus()
    } else if (e.key === "Enter" && e.target === this.search) {
      e.preventDefault()
      const first = links.find(a => a.dataset.place === "")
      first?.click()
    }
  },
}
