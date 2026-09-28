// The sidebar as a drawer below 768 px: focus moves in and back out, the page
// behind is inert and does not scroll, Escape and navigation close it.
export const NavDrawer = {
  mounted() {
    const toggle = this.el.querySelector(".drawer-toggle")
    const wide = matchMedia("(min-width: 768px)")
    const sync = focus => {
      const open = toggle.checked && !wide.matches
      const main = this.el.querySelector(".drawer-content")
      main.toggleAttribute("inert", open)
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
      if (toggle.checked === open) return
      toggle.checked = open
      sync(focus)
    }
    this.el.addEventListener("click", e => {
      if (e.target.closest("[data-drawer-open]")) set(true)
      else if (e.target.closest("[data-drawer-close]")) set(false)
    })
    toggle.addEventListener("change", () => sync(true))
    this.onKey = e => {
      if (e.key === "Escape" && toggle.checked && !wide.matches && !e.defaultPrevented) set(false)
    }
    document.addEventListener("keydown", this.onKey)
    this.onNav = () => set(false, false)
    window.addEventListener("phx:page-loading-stop", this.onNav)
    this.onWide = () => wide.matches && set(false, false)
    wide.addEventListener("change", this.onWide)
    this.wide = wide
  },
  destroyed() {
    window.removeEventListener("phx:page-loading-stop", this.onNav)
    document.removeEventListener("keydown", this.onKey)
    this.wide.removeEventListener("change", this.onWide)
    document.documentElement.style.overflow = ""
  },
}
