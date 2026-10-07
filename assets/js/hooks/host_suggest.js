// A list's query field that suggests hosts (`CoreComponents.list_search/1` with `suggest`):
// the ARIA combobox, list autocomplete with manual selection. The form asks the server for
// the hosts of the word being typed (`phx-change`, 150 ms after the reader stops), and the
// server renders them as the options of the listbox under the field. This hook only moves
// among them and chooses: ↓ and ↑ move the active option (it wraps), Alt+↓ asks for the
// list of the word under the caret, Enter or a click puts `host:<host>` in place of the
// word being typed and sends the query, as Enter does without one. Escape closes the list
// and keeps the text (a second Escape is the search field's own), and Tab or leaving the
// field closes it without choosing. The focus never leaves the field.
//
// The server renders the field and the options without the active one, so the hook puts
// it back after each patch (`updated`), by its value.

export const HostSuggest = {
  mounted() {
    this.input = this.el.querySelector("input[role=combobox]")
    this.list = this.el.querySelector("[role=listbox]")
    this.activeValue = null

    this.input.addEventListener("keydown", e => this.onKey(e))
    this.input.addEventListener("blur", () => {
      // After LiveView sends what the field held on leaving it, so the close is the last
      // word, and an answer still on its way is dropped.
      setTimeout(() => this.close(), 0)
    })
    // A press on an option keeps the focus in the field; the click chooses.
    this.list.addEventListener("mousedown", e => e.preventDefault())
    this.list.addEventListener("click", e => {
      const option = e.target.closest("[role=option]")
      if (option) this.choose(option)
    })
  },

  updated() {
    const options = this.options()
    const index = options.findIndex(o => o.dataset.value === this.activeValue)
    this.select(index)
  },

  options() {
    return this.list.hidden ? [] : [...this.list.querySelectorAll("[role=option]")]
  },

  onKey(e) {
    const options = this.options()

    if (e.key === "ArrowDown" && e.altKey) {
      e.preventDefault()
      this.pushEvent(this.el.dataset.suggest, {q: this.input.value})
    } else if (e.key === "ArrowDown" || e.key === "ArrowUp") {
      if (options.length === 0) return
      e.preventDefault()
      const at = options.findIndex(o => o.getAttribute("aria-selected") === "true")
      const step = e.key === "ArrowDown" ? 1 : -1
      const from = at === -1 && step === -1 ? 0 : at
      this.select((from + step + options.length) % options.length)
    } else if (e.key === "Enter") {
      const option = options.find(o => o.getAttribute("aria-selected") === "true")
      if (option) {
        e.preventDefault()
        this.choose(option)
      }
    } else if (e.key === "Escape") {
      if (options.length === 0) return
      e.preventDefault()
      e.stopPropagation()
      this.close()
    }
  },

  select(index) {
    const options = this.options()
    options.forEach((o, i) => o.setAttribute("aria-selected", String(i === index)))
    if (index >= 0 && options[index]) {
      this.activeValue = options[index].dataset.value
      this.input.setAttribute("aria-activedescendant", options[index].id)
      options[index].scrollIntoView({block: "nearest"})
    } else {
      this.activeValue = null
      this.input.removeAttribute("aria-activedescendant")
    }
  },

  // The chosen host takes the place of the word being typed, the last of the field, and
  // the form sends the query as Enter does: the word becomes the `host:` filter.
  choose(option) {
    const text = this.input.value
    const at = text.search(/\S*$/)
    this.input.value = `${text.slice(0, at)}host:${option.dataset.value}`
    this.hide()
    this.el.requestSubmit()
  },

  // Tab leaves the field, which closes the list as any blur does.
  close() {
    this.hide()
    this.pushEvent(this.el.dataset.suggest, {q: ""})
  },

  // At once, before the server's answer says the same.
  hide() {
    this.select(-1)
    this.list.hidden = true
    this.input.setAttribute("aria-expanded", "false")
  },
}
