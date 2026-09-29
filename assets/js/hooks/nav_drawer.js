// The sidebar. Below 768 px it is a drawer: focus moves in and back out, the top bar and
// the page behind are inert and do not scroll, Escape and navigation close it. From 768 px
// it folds to icons and back, by its Collapse control or the [ key outside a field; the
// fold is a reading preference in localStorage, which the root layout applies before the
// first paint, and while it is folded each item's name is its title.
const KEY = "qory:sidebar"

export const NavDrawer = {
  mounted() {
    const toggle = this.el.querySelector(".drawer-toggle")
    const wide = matchMedia("(min-width: 768px)")
    const sync = focus => {
      const open = toggle.checked && !wide.matches
      for (const behind of this.el.querySelectorAll(".drawer-content, #top-bar")) {
        behind.toggleAttribute("inert", open)
      }
      document.documentElement.style.overflow = open ? "hidden" : ""
      this.el.querySelector("[data-drawer-open]")?.setAttribute("aria-expanded", String(open))
      if (focus) {
        // The drawer is still hidden in this frame; focus once it shows.
        const target = this.el.querySelector(open ? "[data-drawer-close]" : "[data-drawer-open]")
        let tries = 0
        const go = () => {
          target?.focus()
          if (document.activeElement !== target && tries++ < 30) requestAnimationFrame(go)
        }
        go()
      }
    }
    const set = (open, focus = true) => {
      if (!toggle || toggle.checked === open) return
      toggle.checked = open
      sync(focus)
    }
    this.el.addEventListener("click", e => {
      if (e.target.closest("[data-drawer-open]")) set(true)
      else if (e.target.closest("[data-drawer-close]")) set(false)
      else if (e.target.closest("[data-sidebar-collapse]")) this.fold(!this.folded())
    })
    toggle?.addEventListener("change", () => sync(true))
    this.onKey = e => {
      if (e.key === "Escape" && toggle?.checked && !wide.matches && !e.defaultPrevented) {
        set(false)
      } else if (
        e.key === "[" &&
        wide.matches &&
        !e.metaKey && !e.ctrlKey && !e.altKey &&
        !e.target.closest?.("input, textarea, select, [contenteditable]") &&
        this.el.querySelector("[data-sidebar-collapse]")
      ) {
        this.fold(!this.folded())
      }
    }
    document.addEventListener("keydown", this.onKey)
    this.onNav = () => set(false, false)
    window.addEventListener("phx:page-loading-stop", this.onNav)
    this.onWide = () => wide.matches && set(false, false)
    wide.addEventListener("change", this.onWide)
    this.wide = wide
    this.titles()
  },

  updated() {
    this.titles()
  },

  destroyed() {
    window.removeEventListener("phx:page-loading-stop", this.onNav)
    document.removeEventListener("keydown", this.onKey)
    this.wide.removeEventListener("change", this.onWide)
    document.documentElement.style.overflow = ""
  },

  folded() {
    return document.documentElement.dataset.sidebar === "collapsed"
  },

  fold(folded) {
    if (folded) document.documentElement.dataset.sidebar = "collapsed"
    else delete document.documentElement.dataset.sidebar
    try {
      folded ? localStorage.setItem(KEY, "collapsed") : localStorage.removeItem(KEY)
    } catch (_e) {}
    this.titles()
  },

  // While folded, an item shows no words: its name is its title.
  titles() {
    const folded = this.folded()
    for (const item of this.el.querySelectorAll("#sidebar .q-nav-item")) {
      const text = item.querySelector(".q-nav-text")?.textContent.trim()
      if (folded && text) item.setAttribute("title", text)
      else if (!item.id.startsWith("nav-pin-")) item.removeAttribute("title")
    }
    this.el
      .querySelector("[data-sidebar-collapse]")
      ?.setAttribute("aria-pressed", String(folded))
  },
}
