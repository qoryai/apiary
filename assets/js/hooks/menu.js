// A daisyUI dropdown with menu manners: a click toggles and leaves focus on the
// trigger (nothing jumps under the cursor); Enter, Space and ArrowDown open and
// focus the first item, ArrowUp the last; arrows wrap, Home and End go to the
// ends; Escape closes and gives focus back; focus leaving closes. The items are not
// tab stops (`tabindex="-1"`): Tab from one closes the menu and goes on from its
// trigger. A field inside (a Filter section's search, its options) keeps its own keys.
//
// With `data-float` the list floats: it is a `popover="manual"` shown in the top layer
// while open, placed under its trigger, right edges aligned (above it when there is no
// room below), so a table's scroll region never clips a row's menu. It stays where the
// DOM has it, so focus and clicks inside it are still the menu's.

const GAP = 4

// The trigger: a menu button (`aria-haspopup`), or a disclosure's button
// (`aria-controls` with `aria-expanded`), as a Filter chip, the Filter menu of a list
// with sections and Jump to date are. The first in the menu's markup is its trigger.
export const TRIGGER = "[aria-haspopup], [aria-controls][aria-expanded]"

export const Menu = {
  mounted() {
    const trigger = () => this.el.querySelector(TRIGGER)
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
      const t = trigger()
      const open = this.el.classList.contains("dropdown-open") || this.el.matches(":focus-within")
      if (e.key === "Escape" && open) {
        e.preventDefault()
        e.stopPropagation()
        close(true)
        return
      }
      // A field keeps its keys: the caret's Home and End, a radio's arrows. From a
      // section's search, ArrowDown goes on to the section's first option.
      if (e.target.matches?.("input, textarea, select, [contenteditable]")) {
        if (e.key === "ArrowDown" && e.target.matches("input[type=search], input[type=text]")) {
          const option = e.target.closest(".q-fm-section")?.querySelector(".q-filter-options input")
          if (option) {
            e.preventDefault()
            option.focus()
          }
        }
        return
      }
      // A menu's items are not tab stops: Tab leaves the menu from its trigger and closes it.
      if (e.key === "Tab" && e.target !== t && e.target.closest('[role="menu"]')) {
        close(true)
        return
      }
      if ((e.key === "Enter" || e.key === " ") && e.target === t) {
        // Not the button's own click: that would open with focus still on the trigger.
        e.preventDefault()
        if (this.el.classList.contains("dropdown-open")) {
          close(true)
        } else {
          set(true)
          items()[0]?.focus()
        }
      } else if (e.key === "ArrowDown" || e.key === "ArrowUp") {
        e.preventDefault()
        const at = items().indexOf(document.activeElement)
        // Opening shows the list, so its items are read after it.
        set(true)
        const list = items()
        const step = e.key === "ArrowDown" ? 1 : -1
        const next = at < 0 ? (step > 0 ? 0 : list.length - 1) : (at + step + list.length) % list.length
        list[next]?.focus()
      } else if (e.key === "Home" || e.key === "End") {
        e.preventDefault()
        const list = items()
        list[e.key === "Home" ? 0 : list.length - 1]?.focus()
      }
    })
    this.el.addEventListener("focusout", e => {
      if (e.relatedTarget) {
        if (!this.el.contains(e.relatedTarget)) set(false)
        return
      }
      // Focus went nowhere: a control inside was hidden under it (a Filter section
      // opening hides the list of sections, then focuses the section), or the window
      // lost focus. Look again once the commands have run, and close only if focus
      // went elsewhere; if it fell to the page, give it to what the menu shows.
      clearTimeout(this.lost)
      this.lost = setTimeout(() => {
        const now = document.activeElement
        if (!this.el.classList.contains("dropdown-open") || this.el.contains(now)) return
        if (!now || now === document.body) {
          const first = this.el.querySelector(".q-fm-section:not(.hidden), .q-fm-section[style*=block]")
          const target = items().find(i => !first || first.contains(i)) || items()[0]
          target ? target.focus() : set(false)
        } else {
          set(false)
        }
      }, 120)
    })
    this.outside = e => {
      if (!this.el.contains(e.target)) set(false)
    }
    // The page closes a menu whose form it answered: `push_event("menu:close", %{id: id})`.
    this.handleEvent("menu:close", ({id}) => id === this.el.id && close(true))
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
    clearTimeout(this.lost)
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
    const trigger = this.el.querySelector(TRIGGER)
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
