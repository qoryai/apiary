// A choice field (`<.input type="choice">`): a button that opens a panel of radios under
// it, in place. A click on the button opens and closes the panel and leaves focus on the
// button; Enter, Space and ArrowDown open it and focus the search box, else the chosen
// radio, else the first, and ArrowUp the chosen or the last. In the panel the radios keep
// their arrow keys; Enter or Space, or a click on an option, chooses it, closes the panel
// and gives focus back to the button. Escape closes it and puts back the option chosen
// when it opened; with none chosen then, it keeps the one checked since, since a form
// without the field's value would send no key for it. Tab and a click elsewhere close it
// and keep the choice. Without a search box, a letter goes to the next option whose title
// starts with it.
//
// The search box narrows the options by title and subtitle in the browser, and keeps the
// chosen option and any marked `data-keep` in view. It has no name, and its input never
// reaches the form, so a keystroke sends no phx-change.
//
// The open panel (`hidden`), the button's `aria-expanded` and the hidden options are this
// hook's: the component ignores them in a patch (`JS.ignore_attributes`), so the patch
// after an arrow key's phx-change leaves the panel open and the options narrowed.

// The radio Escape checks again: the one chosen when the panel opened, where there was
// one and another is checked now; else none, and no change is sent.
export function putBack(before, now) {
  return before && before !== now ? before : null
}

// The words of a query, lower case, each of which a match must contain.
export function words(query) {
  return query.toLocaleLowerCase().split(/\s+/).filter(word => word !== "")
}

// Whether an option's text holds every word of the query; an empty query holds all.
export function matches(text, query) {
  const haystack = text.toLocaleLowerCase()
  return words(query).every(word => haystack.includes(word))
}

const grouped = n => n.toLocaleString(document.body.dataset.locale || "en-GB")

export const Choice = {
  mounted() {
    this.open = false
    this.button = () => this.el.querySelector(":scope > .q-pick-btn")
    this.panel = () => this.el.querySelector(":scope > .q-pick-panel")
    this.search = () => this.el.querySelector(".q-pick-find input")
    this.radios = () => [...this.el.querySelectorAll(".q-pick-radio")]
    this.shown = () => this.radios().filter(radio => !radio.closest(".q-pick-opt").hidden)
    this.checked = () => this.radios().find(radio => radio.checked)

    this.el.addEventListener("click", e => {
      const button = this.button()
      if (button.contains(e.target)) {
        this.open ? this.close(false) : this.show()
        return
      }
      // A click on an option's words. A click on the radio itself also comes from the
      // arrow keys, which check it with no click of the pointer.
      const option = e.target.closest(".q-pick-opt")
      if (option && !e.target.matches(".q-pick-radio")) {
        e.preventDefault()
        this.choose(option.querySelector(".q-pick-radio"))
      }
    })

    this.el.addEventListener("keydown", e => this.key(e))

    this.el.addEventListener("input", e => {
      if (!e.target.matches(".q-pick-find input")) return
      e.stopPropagation()
      this.narrow()
    })
    // The search box's change bubbles too (on blur): it is no change of the form's.
    this.el.addEventListener("change", e => {
      if (e.target.matches(".q-pick-find input")) e.stopPropagation()
      else if (e.target.matches(".q-pick-radio")) this.label()
    })

    this.el.addEventListener("focusout", e => {
      if (this.open && e.relatedTarget && !this.el.contains(e.relatedTarget)) this.close(false)
    })
    this.outside = e => {
      if (this.open && !this.el.contains(e.target)) this.close(false)
    }
    document.addEventListener("pointerdown", this.outside)
  },

  // Options the server adds while a search is typed are narrowed too.
  updated() {
    if (this.open) this.narrow()
  },

  destroyed() {
    document.removeEventListener("pointerdown", this.outside)
  },

  key(e) {
    const button = this.button()
    if (e.key === "Escape" && this.open) {
      e.preventDefault()
      e.stopPropagation()
      this.restore()
      this.close(true)
      return
    }
    if (e.target === button) {
      if (e.key === "Enter" || e.key === " " || e.key === "ArrowDown" || e.key === "ArrowUp") {
        // Not the button's click: that would toggle with focus left on the button.
        e.preventDefault()
        if (this.open && (e.key === "Enter" || e.key === " ")) {
          this.close(true)
          return
        }
        this.show()
        const search = this.search()
        const list = this.shown()
        const target =
          (e.key !== "ArrowUp" && search) ||
          this.checked() ||
          (e.key === "ArrowUp" ? list[list.length - 1] : list[0])
        target?.focus()
      }
      return
    }
    if (e.target.matches(".q-pick-find input")) {
      if (e.key === "ArrowDown") {
        e.preventDefault()
        const checked = this.checked()
        ;(checked && this.shown().includes(checked) ? checked : this.shown()[0])?.focus()
      } else if (e.key === "Enter") {
        // Enter in a search box would submit the form.
        e.preventDefault()
      }
      return
    }
    if (e.target.matches(".q-pick-radio")) {
      if (e.key === "Enter" || e.key === " ") {
        e.preventDefault()
        this.choose(e.target)
      } else if (!this.search() && e.key.length === 1 && /\S/.test(e.key) && !e.metaKey && !e.ctrlKey && !e.altKey) {
        const list = this.shown()
        const at = list.indexOf(e.target)
        const letter = e.key.toLocaleLowerCase()
        const next = [...list.slice(at + 1), ...list.slice(0, at + 1)].find(radio =>
          this.title(radio).toLocaleLowerCase().startsWith(letter)
        )
        if (next) {
          e.preventDefault()
          next.focus()
          this.check(next)
        }
      }
    }
  },

  show() {
    this.open = true
    this.before = this.checked()
    this.panel().hidden = false
    this.button().setAttribute("aria-expanded", "true")
    this.narrow()
  },

  close(refocus) {
    this.open = false
    this.panel().hidden = true
    this.button().setAttribute("aria-expanded", "false")
    if (refocus) this.button().focus()
  },

  // Checks a radio as a click would: the form hears the change, as it hears an arrow key's.
  check(radio) {
    if (!radio || radio.checked) return
    radio.checked = true
    radio.dispatchEvent(new Event("input", {bubbles: true}))
    radio.dispatchEvent(new Event("change", {bubbles: true}))
  },

  choose(radio) {
    this.check(radio)
    this.close(true)
  },

  restore() {
    this.check(putBack(this.before, this.checked()))
  },

  title(radio) {
    return radio.closest(".q-pick-opt").querySelector(".q-pick-t").textContent.trim()
  },

  // The button shows the chosen option at once; the page's patch, where it has one, shows
  // the same.
  label() {
    const shown = this.button().querySelector(".q-pick-text")
    const option = this.checked()?.closest(".q-pick-opt")
    if (!shown || !option) return
    shown.replaceChildren(...[...option.querySelector(".q-pick-text").children].map(node => {
      const copy = node.cloneNode(true)
      copy.removeAttribute("id")
      return copy
    }))
    this.button().classList.remove("is-prompt")
  },

  narrow() {
    const search = this.search()
    if (!search) return
    const query = search.value
    const checked = this.checked()
    // The count is of the options the search reads: one kept in view whatever it says,
    // such as Another model, is not among them.
    const options = [...this.el.querySelectorAll(".q-pick-opt")]
    const counted = options.filter(option => option.dataset.keep !== "true")
    let found = 0
    for (const option of options) {
      const match = matches(option.textContent, query)
      if (match && option.dataset.keep !== "true") found += 1
      option.hidden = !match && option.dataset.keep !== "true" && !option.contains(checked)
    }
    const status = this.el.querySelector(".q-pick-status")
    if (!status) return
    if (words(query).length === 0) status.textContent = ""
    else if (found === 0) status.textContent = this.el.dataset.none
    else
      status.textContent = this.el.dataset.found
        .replace("%{shown}", grouped(found))
        .replace("%{total}", grouped(counted.length))
  },
}
