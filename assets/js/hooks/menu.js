// A daisyUI dropdown with menu manners: a click toggles and leaves focus on the
// trigger (nothing jumps under the cursor); Enter, Space and ArrowDown open and
// focus the first item, ArrowUp the last; arrows wrap, Home and End go to the
// ends; Escape closes and gives focus back; focus leaving closes.
export const Menu = {
  mounted() {
    const trigger = () => this.el.querySelector("[aria-haspopup]")
    const items = () =>
      [...this.el.querySelectorAll(".dropdown-content :is(a, button):not([disabled])")]
    const set = open => {
      this.el.classList.toggle("dropdown-open", open)
      trigger()?.setAttribute("aria-expanded", String(open))
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
  },
  destroyed() {
    document.removeEventListener("pointerdown", this.outside)
  },
}
