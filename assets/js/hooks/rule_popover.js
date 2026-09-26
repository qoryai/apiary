// The popover of a connection row's Allow or Deny. The server renders it while it is
// open; this hook puts it in the top layer (so the table's scroll container cannot clip
// it), places it under its button, right edges aligned, and gives focus back to the
// button when it goes. Below 768 px the stylesheet makes it a bottom sheet and the
// placement here is overridden.
//
// `popover="auto"` brings Escape and a click outside; either closes it in the browser, and
// the server is told so with "rule_cancel".

const GAP = 6

export const RulePopover = {
  mounted() {
    this.anchorId = this.el.dataset.anchor
    this.closing = false

    this.onToggle = (event) => {
      if (event.newState === "closed" && !this.closing) this.pushEvent("rule_cancel", {})
    }
    this.place = () => this.position()

    this.el.addEventListener("toggle", this.onToggle)
    window.addEventListener("resize", this.place)
    window.addEventListener("scroll", this.place, true)

    if (typeof this.el.showPopover === "function") {
      try { this.el.showPopover() } catch (_already) {}
    } else {
      // No popover support: shown in place, fixed, above the page.
      this.el.style.display = "block"
      this.el.style.zIndex = "60"
    }

    this.position()
    const first = this.el.querySelector("[data-autofocus], input[type=radio]:checked, input[type=radio], select, button")
    if (first) requestAnimationFrame(() => first.focus({preventScroll: true}))
  },

  // A patch writes the server's attributes back; the place is this hook's.
  updated() {
    this.anchorId = this.el.dataset.anchor
    this.position()
  },

  destroyed() {
    this.closing = true
    window.removeEventListener("resize", this.place)
    window.removeEventListener("scroll", this.place, true)
    // The button may have become the "Rule" link; it keeps the id.
    const anchor = document.getElementById(this.anchorId)
    if (anchor) requestAnimationFrame(() => anchor.focus({preventScroll: true}))
  },

  position() {
    const anchor = document.getElementById(this.anchorId)
    if (!anchor) return
    const at = anchor.getBoundingClientRect()
    const height = this.el.offsetHeight
    const below = at.bottom + GAP
    const fits = below + height <= window.innerHeight - 8
    const top = fits ? below : Math.max(8, at.top - GAP - height)
    const right = Math.max(8, window.innerWidth - at.right)

    this.el.style.top = `${Math.round(top)}px`
    this.el.style.right = `${Math.round(right)}px`
    this.el.style.left = "auto"
    this.el.style.bottom = "auto"
  },
}
