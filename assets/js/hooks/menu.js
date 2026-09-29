// A daisyUI dropdown with menu manners: a click toggles and leaves focus on the
// trigger (nothing jumps under the cursor); Enter, Space and ArrowDown open and
// focus the first item, ArrowUp the last; arrows wrap, Home and End go to the
// ends; Escape closes and gives focus back; focus leaving closes.
//
// With `data-float` the list floats: it is a `popover="manual"` shown in the top layer
// while open, placed under its trigger, right edges aligned (above it when there is no
// room below), so a table's scroll region never clips a row's menu. It stays where the
// DOM has it, so focus and clicks inside it are still the menu's.

const GAP = 4

export const Menu = {
  mounted() {
    const trigger = () => this.el.querySelector("[aria-haspopup]")
    // What is shown: a Filter menu holds its sections' controls hidden until one opens.
    const items = () =>
      [...this.el.querySelectorAll(".dropdown-content :is(a, button):not([disabled])")].filter(
        item => item.getClientRects().length > 0
      )
    this.float = this.el.hasAttribute("data-float")
    const set = open => {
      this.el.classList.toggle("dropdown-open", open)
      trigger()?.setAttribute("aria-expanded", String(open))
      if (this.float) open ? this.place() : this.unplace()
    }
    const close = refocus => {
      set(false)
      if (this.el.contains(document.activeElement)) {
        refocus ? trigger()?.focus() : document.activeElement.blur()
      }
    }
    this.el.addEventListener("click", e => {
      const t = trigger()
      if (t && t.contains(e.target)) {
        this.el.classList.contains("dropdown-open") ? close(false) : set(true)
      } else if (e.target.closest("a, [data-menu-close]")) {
        close(false)
      }
    })
    this.el.addEventListener("keydown", e => {
      const list = items()
      const at = list.indexOf(document.activeElement)
      const t = trigger()
      const open = this.el.classList.contains("dropdown-open") || this.el.matches(":focus-within")
      if ((e.key === "Enter" || e.key === " ") && e.target === t) {
        // Not the button's own click: that would open with focus still on the trigger.
        e.preventDefault()
        if (this.el.classList.contains("dropdown-open")) {
          close(true)
        } else {
          set(true)
          list[0]?.focus()
        }
      } else if (e.key === "Escape" && open) {
        e.preventDefault()
        e.stopPropagation()
        close(true)
      } else if (e.key === "ArrowDown" || e.key === "ArrowUp") {
        e.preventDefault()
        set(true)
        const step = e.key === "ArrowDown" ? 1 : -1
        const next = at < 0 ? (step > 0 ? 0 : list.length - 1) : (at + step + list.length) % list.length
        list[next]?.focus()
      } else if (e.key === "Home" || e.key === "End") {
        e.preventDefault()
        list[e.key === "Home" ? 0 : list.length - 1]?.focus()
      }
    })
    this.el.addEventListener("focusout", e => {
      if (!this.el.contains(e.relatedTarget)) set(false)
    })
    this.outside = e => {
      if (!this.el.contains(e.target)) set(false)
    }
    document.addEventListener("pointerdown", this.outside)
    this.reflow = () => {
      if (this.el.classList.contains("dropdown-open")) this.position()
    }
    if (this.float) {
      window.addEventListener("resize", this.reflow)
      window.addEventListener("scroll", this.reflow, true)
    }
  },

  // A patch keeps the open state (`JS.ignore_attributes`); the place is this hook's.
  updated() {
    if (this.float) this.reflow()
  },

  destroyed() {
    document.removeEventListener("pointerdown", this.outside)
    window.removeEventListener("resize", this.reflow)
    window.removeEventListener("scroll", this.reflow, true)
  },

  list() {
    return this.el.querySelector(".dropdown-content")
  },

  place() {
    const list = this.list()
    if (!list) return
    if (typeof list.showPopover === "function" && !list.matches(":popover-open")) {
      try { list.showPopover() } catch (_shown) {}
    }
    this.position()
  },

  unplace() {
    const list = this.list()
    if (list && typeof list.hidePopover === "function" && list.matches(":popover-open")) {
      try { list.hidePopover() } catch (_hidden) {}
    }
  },

  position() {
    const list = this.list()
    const trigger = this.el.querySelector("[aria-haspopup]")
    if (!list || !trigger) return
    const at = trigger.getBoundingClientRect()
    const height = list.offsetHeight
    const below = at.bottom + GAP
    const top = below + height <= window.innerHeight - 8 ? below : Math.max(8, at.top - GAP - height)
    const right = Math.max(8, window.innerWidth - at.right)
    Object.assign(list.style, {
      position: "fixed",
      inset: "auto",
      top: `${Math.round(top)}px`,
      right: `${Math.round(right)}px`,
      margin: "0",
    })
  },
}
